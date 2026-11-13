#Requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'Template')]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]+$')][string]$Owner,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]+$')][string]$Name,
    [Parameter(Mandatory, ParameterSetName = 'Template')]
    [ValidatePattern('^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+$')][string]$Template,
    [Parameter(Mandatory, ParameterSetName = 'Seed')][string]$SeedPath,
    [Parameter(ParameterSetName = 'Seed')][switch]$IsTemplate,
    [string]$Description = 'Website project: dev via PR, production managed by owner'
)

$ErrorActionPreference = 'Stop'

function Invoke-GitHub {
    param([string]$Method, [string]$Endpoint, [object]$Body)
    $requestArgs = @('api', '--method', $Method, $Endpoint)
    $requestFile = $null
    try {
        if ($null -ne $Body) {
            $requestFile = [IO.Path]::GetTempFileName()
            [IO.File]::WriteAllText($requestFile, ($Body | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
            $requestArgs += @('--input', $requestFile)
        }
        $result = & gh @requestArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "GitHub $Method $Endpoint failed: $($result -join [Environment]::NewLine)" }
        $resultText = $result -join [Environment]::NewLine
        if ($resultText.Trim()) { return $resultText | ConvertFrom-Json }
    }
    finally {
        if ($requestFile) { Remove-Item -LiteralPath $requestFile }
    }
}

$user = Invoke-GitHub GET 'user' $null
if ($user.login -ne $Owner) { throw "Active account is $($user.login); expected $Owner. Switch gh account explicitly before running." }
if ($user.type -ne 'User') { throw 'This bootstrap targets repositories owned by a personal GitHub account.' }
$repos = @(& gh repo list $Owner --limit 1000 --json name | ConvertFrom-Json)
if ($LASTEXITCODE -ne 0) { throw 'Could not check existing repositories.' }
if ($repos.name -contains $Name) { throw "$Owner/$Name already exists; no changes made." }

Write-Host "Creating PUBLIC repository $Owner/$Name"
if ($PSCmdlet.ParameterSetName -eq 'Seed') {
    $seedRoot = (Resolve-Path -LiteralPath $SeedPath).Path
    $seedFiles = @(Get-ChildItem -LiteralPath $seedRoot -Recurse -File -Force)
    if (!$seedFiles.Count) { throw 'Seed directory is empty.' }
    # Review the complete seed directory before running: all its files will be public.
    $null = Invoke-GitHub POST 'user/repos' @{
        name = $Name; description = $Description; private = $false; auto_init = $false
        is_template = [bool]$IsTemplate
    }
    $readmePath = Join-Path $seedRoot 'README.md'
    if (!(Test-Path -LiteralPath $readmePath)) { throw 'Seed must contain README.md.' }
    $initial = Invoke-GitHub PUT "repos/$Owner/$Name/contents/README.md" @{
        message = 'Initialize repository'; branch = 'master'
        content = [Convert]::ToBase64String([IO.File]::ReadAllBytes($readmePath))
    }
    $treeEntries = @($seedFiles | ForEach-Object {
        @{ path = [IO.Path]::GetRelativePath($seedRoot, $_.FullName).Replace('\', '/'); mode = '100644'; type = 'blob'; content = [IO.File]::ReadAllText($_.FullName) }
    })
    $tree = Invoke-GitHub POST "repos/$Owner/$Name/git/trees" @{ tree = $treeEntries }
    $commit = Invoke-GitHub POST "repos/$Owner/$Name/git/commits" @{
        message = 'Initialize team workflow and repository template'; tree = $tree.sha; parents = @($initial.commit.sha)
    }
    $null = Invoke-GitHub PATCH "repos/$Owner/$Name/git/refs/heads/master" @{ sha = $commit.sha; force = $false }
    $initialBranch = 'master'
    $initialSha = $commit.sha
}
else {
    $null = Invoke-GitHub POST "repos/$Template/generate" @{
        owner = $Owner; name = $Name; description = $Description; private = $false; include_all_branches = $false
    }
    $ready = $false
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            $repo = Invoke-GitHub GET "repos/$Owner/$Name" $null
            $initialBranch = $repo.default_branch
            $ref = Invoke-GitHub GET "repos/$Owner/$Name/git/ref/heads/$initialBranch" $null
            $initialSha = $ref.object.sha
            $ready = $true
            break
        }
        catch { if ($attempt -eq 9) { throw }; Start-Sleep -Seconds 2 }
    }
    if (!$ready) { throw 'Generated repository is not ready; inspect it before retrying.' }
}

foreach ($branch in @('master', 'dev')) {
    if ($branch -ne $initialBranch) {
        $null = Invoke-GitHub POST "repos/$Owner/$Name/git/refs" @{ ref = "refs/heads/$branch"; sha = $initialSha }
    }
}

$null = Invoke-GitHub PATCH "repos/$Owner/$Name" @{
    default_branch = 'dev'; allow_merge_commit = $true; allow_squash_merge = $true
    allow_rebase_merge = $false; delete_branch_on_merge = $true; allow_auto_merge = $false
}
$null = Invoke-GitHub PUT "repos/$Owner/$Name/actions/permissions" @{ enabled = $false }

$commonRules = @(
    @{ type = 'deletion' },
    @{ type = 'non_fast_forward' },
    @{ type = 'pull_request'; parameters = @{
        required_approving_review_count = 0; dismiss_stale_reviews_on_push = $true
        require_code_owner_review = $false; require_last_push_approval = $false
        required_review_thread_resolution = $true; allowed_merge_methods = @('merge', 'squash')
    } }
)
$null = Invoke-GitHub POST "repos/$Owner/$Name/rulesets" @{
    name = 'Shared branches - PR required'; target = 'branch'; enforcement = 'active'; bypass_actors = @()
    conditions = @{ ref_name = @{ include = @('refs/heads/master', 'refs/heads/dev'); exclude = @() } }
    rules = $commonRules
}
$adminBypass = @(@{ actor_type = 'RepositoryRole'; actor_id = 5; bypass_mode = 'always' })
$null = Invoke-GitHub POST "repos/$Owner/$Name/rulesets" @{
    name = 'Production - admin updates only'; target = 'branch'; enforcement = 'active'; bypass_actors = $adminBypass
    conditions = @{ ref_name = @{ include = @('refs/heads/master'); exclude = @() } }
    rules = @(@{ type = 'update'; parameters = @{ update_allows_fetch_and_merge = $false } })
}
$null = Invoke-GitHub POST "repos/$Owner/$Name/rulesets" @{
    name = 'Release tags - admin only'; target = 'tag'; enforcement = 'active'; bypass_actors = $adminBypass
    conditions = @{ ref_name = @{ include = @('~ALL'); exclude = @() } }
    rules = @(@{ type = 'creation' }, @{ type = 'update'; parameters = @{ update_allows_fetch_and_merge = $false } }, @{ type = 'deletion' })
}

# Read back actual settings; fail rather than claim a partial setup is complete.
$final = Invoke-GitHub GET "repos/$Owner/$Name" $null
$branches = @(Invoke-GitHub GET "repos/$Owner/$Name/branches" $null)
$rulesets = @(Invoke-GitHub GET "repos/$Owner/$Name/rulesets" $null)
$actions = Invoke-GitHub GET "repos/$Owner/$Name/actions/permissions" $null
if ($final.private -or $final.default_branch -ne 'dev') { throw 'Visibility/default branch verification failed.' }
foreach ($branch in @('master', 'dev')) {
    if ($branches.name -notcontains $branch) { throw "Missing $branch branch." }
    $rules = @(Invoke-GitHub GET "repos/$Owner/$Name/rules/branches/$branch" $null)
    foreach ($expected in @('pull_request', 'deletion', 'non_fast_forward')) {
        if ($rules.type -notcontains $expected) { throw "Missing $expected rule on $branch." }
    }
    if ($branch -eq 'master' -and $rules.type -notcontains 'update') { throw 'Master is not restricted to admin updates.' }
}
if (@($rulesets | Where-Object enforcement -eq 'active').Count -ne 3) { throw 'Expected three active rulesets.' }
if ($actions.enabled) { throw 'Actions were unexpectedly enabled.' }
Write-Host "Verified: $($final.html_url) | public | default dev | PR required | master admin-only | Actions disabled"
