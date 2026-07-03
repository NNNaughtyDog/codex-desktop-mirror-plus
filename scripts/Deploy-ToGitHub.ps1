param(
    [string] $RepoName = 'codex-desktop-mirror-plus',
    [string] $Owner = '',
    [ValidateSet('public', 'private')]
    [string] $Visibility = 'public',
    [string] $GitHubCliPath = '',
    [switch] $InstallMissingDependencies
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string] $Message)
    Write-Host "[deploy] $Message"
}

function Read-YesNo {
    param(
        [string] $Prompt,
        [bool] $DefaultYes = $false
    )

    $suffix = if ($DefaultYes) { ' [Y/n]' } else { ' [y/N]' }
    while ($true) {
        $answer = Read-Host ($Prompt + $suffix)
        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultYes
        }
        switch -Regex ($answer.Trim()) {
            '^(y|yes)$' { return $true }
            '^(n|no)$' { return $false }
            default { Write-Host 'Please answer y or n.' }
        }
    }
}

function Invoke-WingetInstall {
    param(
        [string] $PackageId,
        [string] $DisplayName
    )

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw "$DisplayName is required, but winget.exe was not found. Install it manually and re-run this script."
    }

    Write-Step "Installing $DisplayName with winget."
    & winget.exe install --id $PackageId -e --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        throw "winget could not install $DisplayName. Exit code: $LASTEXITCODE"
    }
}

function Ensure-Command {
    param(
        [string] $CommandName,
        [string] $DisplayName,
        [string] $WingetPackageId,
        [string] $ManualUrl,
        [string] $PreferredPath = ''
    )

    if ($PreferredPath -and (Test-Path -LiteralPath $PreferredPath)) {
        return (Resolve-Path -LiteralPath $PreferredPath).Path
    }

    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($cmd) {
        return $cmd.Source
    }

    Write-Step "$DisplayName was not found."
    Write-Host "Manual install: $ManualUrl"
    $install = $InstallMissingDependencies
    if (-not $install) {
        $install = Read-YesNo -Prompt "Install $DisplayName now with winget?"
    }

    if (-not $install) {
        throw "$DisplayName is required. Install it and re-run this script."
    }

    Invoke-WingetInstall -PackageId $WingetPackageId -DisplayName $DisplayName
    $cmd = Get-Command $CommandName -ErrorAction SilentlyContinue
    if (-not $cmd) {
        throw "$DisplayName was installed, but it is not visible in this PowerShell session. Open a new PowerShell window and re-run this script."
    }
    return $cmd.Source
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

$git = Ensure-Command -CommandName 'git.exe' -DisplayName 'Git for Windows' -WingetPackageId 'Git.Git' -ManualUrl 'https://git-scm.com/download/win'
Write-Step "Using Git: $git"

$gh = Ensure-Command -CommandName 'gh.exe' -DisplayName 'GitHub CLI' -WingetPackageId 'GitHub.cli' -ManualUrl 'https://cli.github.com/' -PreferredPath $GitHubCliPath
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
