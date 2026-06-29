param(
    [string] $RepoName = 'codex-desktop-mirror-plus',
    [string] $Owner = '',
    [ValidateSet('public', 'private')]
    [string] $Visibility = 'public',
    [string] $GitHubCliPath = ''
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string] $Message)
    Write-Host "[deploy] $Message"
}

function Get-GhPath {
    param([string] $PreferredPath)
    if ($PreferredPath -and (Test-Path -LiteralPath $PreferredPath)) {
        return (Resolve-Path -LiteralPath $PreferredPath).Path
    }
    $cmd = Get-Command gh.exe -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }
    throw 'GitHub CLI gh.exe was not found. Install it from https://cli.github.com/ and re-run this script.'
}

function Invoke-Gh {
    param(
        [string] $Gh,
        [string[]] $Arguments,
        [switch] $AllowFailure
    )
    & $Gh @Arguments
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "gh $($Arguments -join ' ') failed with exit code $code"
    }
    return $code
}

$repoRoot = Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')
Set-Location -LiteralPath $repoRoot

$gh = Get-GhPath -PreferredPath $GitHubCliPath
Write-Step "Using GitHub CLI: $gh"

Write-Step 'Checking GitHub authentication.'
$authCode = Invoke-Gh -Gh $gh -Arguments @('auth', 'status', '--hostname', 'github.com') -AllowFailure
if ($authCode -ne 0) {
    Write-Step 'Not logged in. Starting browser-based GitHub login. Do not paste passwords or tokens into chat.'
    Invoke-Gh -Gh $gh -Arguments @('auth', 'login', '--hostname', 'github.com', '--git-protocol', 'https', '--web')
}

if (-not $Owner) {
    $Owner = (& $gh api user --jq '.login').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $Owner) {
        throw 'Could not determine GitHub account login.'
    }
}

$fullRepo = "$Owner/$RepoName"
Write-Step "Target repo: $fullRepo"

Invoke-Gh -Gh $gh -Arguments @('repo', 'view', $fullRepo) -AllowFailure | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Step "Creating $Visibility repository."
    Invoke-Gh -Gh $gh -Arguments @(
        'repo', 'create', $fullRepo,
        "--$Visibility",
        '--source', $repoRoot,
        '--remote', 'origin',
        '--description', 'Complete Codex Desktop Windows mirror and updater project'
    )
} else {
    Write-Step 'Repository already exists.'
    $remoteUrl = "https://github.com/$fullRepo.git"
    $existingRemote = git remote get-url origin 2>$null
    if ($LASTEXITCODE -ne 0) {
        git remote add origin $remoteUrl
    } elseif ($existingRemote -ne $remoteUrl) {
        git remote set-url origin $remoteUrl
    }
}

$branch = (git branch --show-current).Trim()
if (-not $branch) {
    $branch = 'main'
    git checkout -B $branch
}
if ($branch -ne 'main') {
    git branch -M main
    $branch = 'main'
}

Write-Step 'Pushing project.'
git push -u origin $branch
if ($LASTEXITCODE -ne 0) {
    throw "git push failed with exit code $LASTEXITCODE"
}

Write-Step "Done: https://github.com/$fullRepo"
