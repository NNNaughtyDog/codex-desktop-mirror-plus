param(
    [string] $InstallDir = 'D:\software\Codex',
    [string] $Repo = 'Wangnov/codex-app-mirror',
    [switch] $NoLaunch,
    [switch] $KeepBackup,
    [switch] $RemoveRegisteredAppx,
    [switch] $PreserveExtraInstallFiles,
    [switch] $InstallMissingDependencies,
    [switch] $SkipSelfRelocation,
    [string] $SelfTempDir = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param([string] $Message)
    Write-Host "[Codex updater] $Message"
}

$script:RunDirForFailure = ''
$script:BackupDirForFailure = ''
$script:InstallDirForFailure = ''

trap {
    Write-Host ''
    Write-Step "Fatal error: $($_.Exception.Message)"
    if ($script:InstallDirForFailure) {
        Write-Step "Install directory: $script:InstallDirForFailure"
    }
    if ($script:BackupDirForFailure) {
        Write-Step "Backup directory kept for recovery: $script:BackupDirForFailure"
    }
    if ($script:RunDirForFailure) {
        Write-Step "Updater work directory kept for diagnosis: $script:RunDirForFailure"
    }
    if ([Environment]::UserInteractive -and -not $env:GITHUB_ACTIONS) {
        try {
            Read-Host 'Press Enter to close this window'
        } catch {
        }
    }
    exit 1
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
        Write-Step "winget.exe was not found. Please install $DisplayName manually, then run this updater again if you need it."
        return $false
    }

    Write-Step "Installing $DisplayName with winget."
    & winget.exe install --id $PackageId -e --source winget --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Write-Step "winget could not install $DisplayName. Exit code: $LASTEXITCODE"
        return $false
    }

    return $true
}

function Ensure-UpdaterDependencies {
    $required = @('curl.exe', 'tar.exe', 'robocopy.exe')
    $missingRequired = @(
        foreach ($command in $required) {
            if (-not (Get-Command $command -ErrorAction SilentlyContinue)) {
                $command
            }
        }
    )

    if ($missingRequired.Count -gt 0) {
        throw "Missing required Windows tools: $($missingRequired -join ', '). Please run this updater on Windows 10/11 with built-in curl, tar, and robocopy available."
    }

    if (-not (Get-Command git.exe -ErrorAction SilentlyContinue)) {
        Write-Step 'Optional dependency Git was not found. The updater can continue, but it cannot read Git proxy settings automatically.'
        $installGit = $InstallMissingDependencies
        if (-not $installGit) {
            $installGit = Read-YesNo -Prompt 'Install Git for Windows now with winget?'
        }
        if ($installGit) {
            [void](Invoke-WingetInstall -PackageId 'Git.Git' -DisplayName 'Git for Windows')
            if (Get-Command git.exe -ErrorAction SilentlyContinue) {
                Write-Step 'Git is available.'
            } else {
                Write-Step 'Git is still not visible in this PowerShell session. Continuing without Git proxy detection.'
            }
        } else {
            Write-Step 'Continuing without Git proxy detection.'
        }
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Quote-ProcessArgument {
    param([string] $Value)
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Test-DirectoryWritable {
    param([string] $Path)

    try {
        $target = Get-FullPath $Path
        while (-not (Test-Path -LiteralPath $target)) {
            $parent = Split-Path -Parent $target
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $target) {
                return $false
            }
            $target = $parent
        }
        if (-not (Get-Item -LiteralPath $target).PSIsContainer) {
            $target = Split-Path -Parent $target
        }

        $probe = Join-Path $target ('codex-updater-write-test-' + [guid]::NewGuid().ToString('N') + '.tmp')
        [IO.File]::WriteAllText($probe, 'test')
        Remove-Item -LiteralPath $probe -Force
        return $true
    } catch {
        return $false
    }
}

function Test-InstallTargetWritable {
    param([string] $InstallPath)

    $installFull = Get-FullPath $InstallPath
    $installParent = Split-Path -Parent $installFull
    if (-not (Test-DirectoryWritable -Path $installParent)) {
        return $false
    }
    if ((Test-Path -LiteralPath $installFull) -and -not (Test-DirectoryWritable -Path $installFull)) {
        return $false
    }
    return $true
}

function Restart-AsAdministrator {
    param([string] $ResolvedInstallDir)

    if (-not $PSCommandPath) {
        throw 'Administrator permission is required, but this script is not running from a file path.'
    }

    Write-Step "Administrator permission is required to update this install folder: $ResolvedInstallDir"
    Write-Step 'Windows will ask for permission, then the updater will continue in a new window.'

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArgument $PSCommandPath),
        '-InstallDir', (Quote-ProcessArgument $ResolvedInstallDir),
        '-Repo', (Quote-ProcessArgument $Repo)
    )
    if ($NoLaunch) {
        $arguments += '-NoLaunch'
    }
    if ($KeepBackup) {
        $arguments += '-KeepBackup'
    }
    if ($RemoveRegisteredAppx) {
        $arguments += '-RemoveRegisteredAppx'
    }
    if ($PreserveExtraInstallFiles) {
        $arguments += '-PreserveExtraInstallFiles'
    }
    if ($InstallMissingDependencies) {
        $arguments += '-InstallMissingDependencies'
    }
    if ($SkipSelfRelocation) {
        $arguments += '-SkipSelfRelocation'
    }
    if ($SelfTempDir) {
        $arguments += '-SelfTempDir'
        $arguments += (Quote-ProcessArgument $SelfTempDir)
    }

    try {
        $process = Start-Process -FilePath 'powershell.exe' -ArgumentList ($arguments -join ' ') -Verb RunAs -Wait -PassThru
        exit $process.ExitCode
    } catch {
        throw "Could not start the updater as administrator. $($_.Exception.Message)"
    }
}

function Read-RequiredInput {
    param([string] $Prompt)
    while ($true) {
        $value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim().Trim('"')
        }
        Write-Host 'Input cannot be empty.'
    }
}

function Get-FullPath {
    param([string] $Path)
    return [IO.Path]::GetFullPath($Path)
}

function Test-CodexInstallDir {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $false
    }
    if (-not [IO.Path]::IsPathRooted($Path)) {
        return $false
    }
    return (Test-Path -LiteralPath (Join-Path $Path 'app\Codex.exe')) -and
        (Test-Path -LiteralPath (Join-Path $Path 'AppxManifest.xml'))
}

function Test-EmptyOrMissingDirectory {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }
    if (-not (Get-Item -LiteralPath $Path).PSIsContainer) {
        return $false
    }
    return -not [bool](Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
}

function Resolve-CodexInstallDir {
    param([string] $DefaultPath)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($DefaultPath)) {
        $candidates += $DefaultPath
    }

    $runningRoots = Get-Process -Name 'Codex' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path.EndsWith('\app\Codex.exe', [StringComparison]::OrdinalIgnoreCase) } |
        ForEach-Object { Split-Path -Parent (Split-Path -Parent $_.Path) } |
        Select-Object -Unique
    $candidates += $runningRoots

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-CodexInstallDir -Path $candidate) {
            return (Get-FullPath $candidate)
        }
    }

    Write-Host ''
    Write-Host "Could not find Codex desktop at the default location: $DefaultPath"
    Write-Host 'Please enter the absolute path to the Codex install folder.'
    Write-Host 'If Codex is not installed yet, enter an empty or new folder and the latest version will be installed there.'
    Write-Host 'Example: D:\software\Codex'

    while ($true) {
        $inputPath = Read-Host "Codex install folder [$DefaultPath]"
        if ([string]::IsNullOrWhiteSpace($inputPath)) {
            $inputPath = $DefaultPath
        }
        $inputPath = $inputPath.Trim().Trim('"')
        if (-not [IO.Path]::IsPathRooted($inputPath)) {
            Write-Host 'Please enter an absolute path, for example D:\software\Codex.'
            continue
        }
        if (Test-CodexInstallDir -Path $inputPath) {
            return (Get-FullPath $inputPath)
        }
        if (Test-EmptyOrMissingDirectory -Path $inputPath) {
            return (Get-FullPath $inputPath)
        }
        Write-Host "That folder does not look like a Codex desktop install: $inputPath"
        Write-Host 'For update, it should contain app\Codex.exe and AppxManifest.xml.'
        Write-Host 'For first install, choose a new or empty folder.'
    }
}

function Normalize-GitHubRepo {
    param([string] $Value)
    $value = $Value.Trim().Trim('"')
    if ($value -match '^https://github\.com/([^/\s]+)/([^/\s#?]+)') {
        return "$($matches[1])/$($matches[2] -replace '\.git$', '')"
    }
    if ($value -match '^([^/\s]+)/([^/\s]+)$') {
        return "$($matches[1])/$($matches[2] -replace '\.git$', '')"
    }
    throw 'Please enter a GitHub repo as owner/repo or https://github.com/owner/repo.'
}

function Assert-SafeDirectory {
    param(
        [string] $Path,
        [string] $ExpectedParent
    )
    $full = Get-FullPath $Path
    $parent = Get-FullPath $ExpectedParent
    if (-not $full.StartsWith($parent, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to operate outside expected parent. Path=$full Parent=$parent"
    }
    if ($full -match '^[A-Za-z]:\\?$') {
        throw "Refusing to operate on a drive root: $full"
    }
}

function Remove-TreeRobust {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $parent = Split-Path -Parent (Get-FullPath $Path)
    $empty = Join-Path $parent ('empty-delete-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $empty | Out-Null
    try {
        & robocopy $empty $Path /MIR /R:1 /W:1 /NFL /NDL /NP | Out-Null
        $code = $LASTEXITCODE
        if ($code -gt 7) {
            throw "robocopy cleanup failed for $Path with exit code $code"
        }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Path) {
            cmd.exe /c rmdir /s /q "$Path" 2>$null
        }
    } finally {
        Remove-Item -LiteralPath $empty -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $empty) {
            cmd.exe /c rmdir /s /q "$empty" 2>$null
        }
    }
}

function Get-AppxManifestVersion {
    param([string] $Root)
    $manifestPath = Join-Path $Root 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return $null
    }
    $xml = [xml](Get-Content -LiteralPath $manifestPath -Raw)
    return [string]$xml.Package.Identity.Version
}

function Get-AppxBlockMapFiles {
    param([string] $Root)
    $blockMap = Join-Path $Root 'AppxBlockMap.xml'
    $set = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if (-not (Test-Path -LiteralPath $blockMap)) {
        return $set
    }

    $xml = [xml](Get-Content -LiteralPath $blockMap -Raw)
    foreach ($fileNode in $xml.BlockMap.File) {
        $name = [string]$fileNode.Name
        if ($name) {
            [void]$set.Add(($name -replace '/', '\'))
        }
    }
    return $set
}

function Get-PreservedInstallFiles {
    param(
        [string] $InstallRoot,
        [Collections.Generic.HashSet[string]] $PackageFiles,
        [switch] $PreserveExtra
    )

    $preserve = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    Get-ChildItem -LiteralPath $InstallRoot -Force -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like '*.bat' -or $_.Name -like '*.cmd' } |
        ForEach-Object {
            [void]$preserve.Add($_.FullName.Substring($InstallRoot.Length).TrimStart('\'))
        }

    $scriptDir = Join-Path $InstallRoot '更新codex脚本'
    if (Test-Path -LiteralPath $scriptDir) {
        Get-ChildItem -LiteralPath $scriptDir -Recurse -Force -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                [void]$preserve.Add($_.FullName.Substring($InstallRoot.Length).TrimStart('\'))
            }
    }

    if ($PreserveExtra -and $PackageFiles.Count -gt 0) {
        Get-ChildItem -LiteralPath $InstallRoot -Recurse -Force -File -ErrorAction SilentlyContinue |
            Where-Object {
                $rel = $_.FullName.Substring($InstallRoot.Length).TrimStart('\')
                -not $PackageFiles.Contains($rel)
            } |
            ForEach-Object {
                [void]$preserve.Add($_.FullName.Substring($InstallRoot.Length).TrimStart('\'))
            }
    }

    $result = @()
    foreach ($item in $preserve) {
        $result += $item
    }
    return $result
}

function Wait-ForCodexToClose {
    param([string] $TargetDir)
    $targetFull = Get-FullPath $TargetDir
    while ($true) {
        $running = @(Get-Process -Name 'Codex','codex' -ErrorAction SilentlyContinue | Where-Object {
            try {
                $_.Path -and (Get-FullPath $_.Path).StartsWith($targetFull, [StringComparison]::OrdinalIgnoreCase)
            } catch {
                $false
            }
        })

        if ($running.Count -eq 0) {
            return
        }

        $ids = ($running | Select-Object -ExpandProperty Id) -join ', '
        Write-Step "Codex is still running from $TargetDir. Close it to continue. PIDs: $ids"
        Start-Sleep -Seconds 5
    }
}

function Invoke-RobocopyMirror {
    param(
        [string] $Source,
        [string] $Destination
    )
    & robocopy $Source $Destination /MIR /R:3 /W:2 /NFL /NDL /NP
    $code = $LASTEXITCODE
    if ($code -gt 7) {
        throw "robocopy failed from $Source to $Destination with exit code $code"
    }
}

function Test-PathInsideDirectory {
    param(
        [string] $Path,
        [string] $Directory
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Directory)) {
        return $false
    }

    $pathFull = Get-FullPath $Path
    $dirFull = Get-FullPath $Directory
    if (-not $dirFull.EndsWith('\')) {
        $dirFull += '\'
    }
    return $pathFull.StartsWith($dirFull, [StringComparison]::OrdinalIgnoreCase)
}

function Restart-FromTempIfNeeded {
    param([string] $ResolvedInstallDir)

    if ($SkipSelfRelocation -or -not $PSCommandPath) {
        return
    }

    if (-not (Test-PathInsideDirectory -Path $PSCommandPath -Directory $ResolvedInstallDir)) {
        return
    }

    $tempSelfDir = Join-Path ([IO.Path]::GetTempPath()) ('CodexDesktopUpdaterSelf-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tempSelfDir | Out-Null
    $tempScript = Join-Path $tempSelfDir 'update-codex-desktop.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $tempScript -Force

    Write-Step "Updater script is inside the install directory. Relaunching from a temporary copy: $tempScript"

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', (Quote-ProcessArgument $tempScript),
        '-InstallDir', (Quote-ProcessArgument $ResolvedInstallDir),
        '-Repo', (Quote-ProcessArgument $Repo),
        '-SkipSelfRelocation',
        '-SelfTempDir', (Quote-ProcessArgument $tempSelfDir)
    )
    if ($NoLaunch) {
        $arguments += '-NoLaunch'
    }
    if ($KeepBackup) {
        $arguments += '-KeepBackup'
    }
    if ($RemoveRegisteredAppx) {
        $arguments += '-RemoveRegisteredAppx'
    }
    if ($PreserveExtraInstallFiles) {
        $arguments += '-PreserveExtraInstallFiles'
    }
    if ($InstallMissingDependencies) {
        $arguments += '-InstallMissingDependencies'
    }

    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList ($arguments -join ' ') -Wait -PassThru
    exit $process.ExitCode
}

function Remove-SelfTempDir {
    if (-not [string]::IsNullOrWhiteSpace($SelfTempDir) -and (Test-Path -LiteralPath $SelfTempDir)) {
        Remove-Item -LiteralPath $SelfTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Assert-ValidCodexInstallCopy {
    param(
        [string] $Path,
        [string] $Label
    )

    if (-not (Test-CodexInstallDir -Path $Path)) {
        throw "$Label is not a valid Codex desktop install copy: $Path"
    }
    $exe = Get-Item -LiteralPath (Join-Path $Path 'app\Codex.exe')
    if ($exe.Length -le 0) {
        throw "$Label contains an empty Codex.exe: $Path"
    }
    $version = Get-AppxManifestVersion -Root $Path
    if (-not $version) {
        throw "$Label does not contain a readable AppxManifest.xml: $Path"
    }
    return $version
}

function Restore-InstallFromSafetyCopies {
    param(
        [string] $InstallPath,
        [string] $OldInstallPath,
        [string] $BackupPath
    )

    if (Test-Path -LiteralPath $InstallPath) {
        Write-Step "Removing incomplete install directory before rollback: $InstallPath"
        Remove-TreeRobust -Path $InstallPath
    }

    if ((Test-Path -LiteralPath $OldInstallPath) -and (Test-CodexInstallDir -Path $OldInstallPath)) {
        Write-Step "Rolling back by moving old install back: $OldInstallPath"
        Move-Item -LiteralPath $OldInstallPath -Destination $InstallPath
        return
    }

    if ((Test-Path -LiteralPath $BackupPath) -and (Test-CodexInstallDir -Path $BackupPath)) {
        Write-Step "Rolling back by copying verified backup: $BackupPath"
        New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
        Invoke-RobocopyMirror -Source $BackupPath -Destination $InstallPath
        return
    }

    throw "Rollback failed because no valid old install or backup was found. Old=$OldInstallPath Backup=$BackupPath"
}

function Get-CurlProxyArgs {
    $candidates = @()

    foreach ($name in @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $candidates += $value.Trim()
        }
    }

    if (Get-Command git.exe -ErrorAction SilentlyContinue) {
        foreach ($key in @('https.proxy', 'http.proxy')) {
            try {
                $value = (& git config --global --get $key 2>$null)
                if (-not [string]::IsNullOrWhiteSpace($value)) {
                    $candidates += $value.Trim()
                }
            } catch {
            }
        }
    }

    try {
        $local7890 = Get-NetTCPConnection -LocalAddress '127.0.0.1' -LocalPort 7890 -State Listen -ErrorAction SilentlyContinue
        if ($local7890) {
            $candidates += 'http://127.0.0.1:7890'
        }
    } catch {
    }

    $proxy = $candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique -First 1
    if ($proxy) {
        return @('--proxy', $proxy)
    }
    return @()
}

function Download-FileWithFallback {
    param(
        [string[]] $Urls,
        [string] $OutputPath
    )

    $proxyArgs = @(Get-CurlProxyArgs)
    if ($proxyArgs.Count -gt 0) {
        Write-Step "Using curl proxy: $($proxyArgs[1])"
    }

    foreach ($url in $Urls) {
        Write-Step "Downloading: $url"
        try {
            & curl.exe @proxyArgs -L --fail --retry 5 --retry-delay 2 --connect-timeout 30 --continue-at - --output $OutputPath $url
            if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $OutputPath)) {
                return $url
            }
            Write-Step "Download command failed with exit code $LASTEXITCODE"
        } catch {
            Write-Step "Download failed: $($_.Exception.Message)"
        }
    }

    throw 'All download URLs failed.'
}

function Get-LatestReleaseAsset {
    param(
        [string] $RepoName,
        [string] $Arch
    )

    $apiUrl = "https://api.github.com/repos/$RepoName/releases/latest"
    Write-Step "Checking latest release: $apiUrl"
    $release = Invoke-RestMethod -Uri $apiUrl -Headers @{ 'User-Agent' = 'codex-desktop-updater' }
    $asset = $release.assets |
        Where-Object { $_.name -match "OpenAI\.Codex_.*_${Arch}__.*\.Msix$" } |
        Select-Object -First 1

    if (-not $asset) {
        throw "No Windows $Arch MSIX asset found in release $($release.tag_name)."
    }

    $expectedSha = $null
    if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest) {
        $expectedSha = ([string]$asset.digest) -replace '^sha256:', ''
    }

    if (-not $expectedSha) {
        $sumAsset = $release.assets | Where-Object { $_.name -eq 'SHA256SUMS-windows.txt' } | Select-Object -First 1
        if ($sumAsset) {
            $sums = Invoke-WebRequest -UseBasicParsing -Uri $sumAsset.browser_download_url
            $content = if ($sums.Content -is [byte[]]) {
                [Text.Encoding]::UTF8.GetString($sums.Content)
            } else {
                [string]$sums.Content
            }
            foreach ($line in ($content -split "`r?`n")) {
                if ($line -match ('^([a-fA-F0-9]{64})\s+' + [regex]::Escape($asset.name) + '$')) {
                    $expectedSha = $matches[1].ToLowerInvariant()
                    break
                }
            }
        }
    }

    if (-not $expectedSha) {
        throw 'Could not find a SHA256 digest for the latest MSIX asset.'
    }

    [pscustomobject]@{
        Tag = $release.tag_name
        Name = $release.name
        AssetName = $asset.name
        DownloadUrl = $asset.browser_download_url
        ExpectedSha256 = $expectedSha.ToLowerInvariant()
    }
}

function Cleanup-StaleUpdaterWork {
    param(
        [string] $InstallParent,
        [string] $CurrentWorkRoot
    )

    foreach ($path in @(
        (Join-Path $InstallParent 'Codex-updater-work'),
        (Join-Path $InstallParent 'Codex-update-26.623.5546.0'),
        (Join-Path $InstallParent 'Codex-backups')
    )) {
        if ((Test-Path -LiteralPath $path) -and ([IO.Path]::GetFullPath($path) -ne [IO.Path]::GetFullPath($CurrentWorkRoot))) {
            Write-Step "Removing stale updater directory: $path"
            Remove-TreeRobust -Path $path
        }
    }

    Get-ChildItem -LiteralPath $InstallParent -Directory -Force -ErrorAction SilentlyContinue -Filter 'empty-delete-*' |
        ForEach-Object {
            Write-Step "Removing stale cleanup directory: $($_.FullName)"
            Remove-TreeRobust -Path $_.FullName
        }
}

Ensure-UpdaterDependencies

$installFull = Resolve-CodexInstallDir -DefaultPath $InstallDir
$installParent = Split-Path -Parent $installFull
Assert-SafeDirectory -Path $installFull -ExpectedParent $installParent
$isFreshInstall = -not (Test-CodexInstallDir -Path $installFull)

if (-not (Test-InstallTargetWritable -InstallPath $installFull)) {
    if (-not (Test-IsAdministrator)) {
        Restart-AsAdministrator -ResolvedInstallDir $installFull
    }
    Write-Step "Running as administrator for protected install folder: $installFull"
}

$arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'x64' }
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$tempRoot = Get-FullPath ([IO.Path]::GetTempPath())
$workRoot = Join-Path $tempRoot 'CodexDesktopUpdater'
$runDir = Join-Path $workRoot $runId
$downloadDir = Join-Path $runDir 'download'
$extractDir = Join-Path $runDir 'extract'
$backupRoot = Join-Path $installParent 'Codex-updater-backup'
$backupDir = Join-Path $backupRoot $runId
$stageInstallDir = Join-Path $installParent ('Codex-updater-new-' + $runId)
$oldInstallDir = Join-Path $installParent ('Codex-updater-old-' + $runId)

Assert-SafeDirectory -Path $workRoot -ExpectedParent $tempRoot
Assert-SafeDirectory -Path $runDir -ExpectedParent $workRoot
Assert-SafeDirectory -Path $backupRoot -ExpectedParent $installParent
Assert-SafeDirectory -Path $stageInstallDir -ExpectedParent $installParent
Assert-SafeDirectory -Path $oldInstallDir -ExpectedParent $installParent

Restart-FromTempIfNeeded -ResolvedInstallDir $installFull

Cleanup-StaleUpdaterWork -InstallParent $installParent -CurrentWorkRoot $workRoot
New-Item -ItemType Directory -Force -Path $downloadDir, $extractDir | Out-Null
$script:RunDirForFailure = $runDir
$script:BackupDirForFailure = $backupDir
$script:InstallDirForFailure = $installFull

$currentVersion = Get-AppxManifestVersion -Root $installFull
Write-Step "Current install: $installFull"
if ($isFreshInstall) {
    Write-Step 'Current version: not installed; first install mode enabled.'
} else {
    Write-Step "Current version: $currentVersion"
}
Write-Step "Detected architecture: $arch"

$activeRepo = Normalize-GitHubRepo -Value $Repo
while ($true) {
    try {
        $releaseInfo = Get-LatestReleaseAsset -RepoName $activeRepo -Arch $arch
        break
    } catch {
        Write-Host ''
        Write-Step "Could not use GitHub mirror repo '$activeRepo': $($_.Exception.Message)"
        Write-Host 'Please enter a replacement GitHub mirror repo.'
        Write-Host 'Accepted formats: owner/repo or https://github.com/owner/repo'
        while ($true) {
            try {
                $activeRepo = Normalize-GitHubRepo -Value (Read-RequiredInput -Prompt 'New mirror repo')
                break
            } catch {
                Write-Host $_.Exception.Message
            }
        }
    }
}
Write-Step "Latest release: $($releaseInfo.Tag)"
Write-Step "Latest asset: $($releaseInfo.AssetName)"

$assetPackageVersion = $null
if ($releaseInfo.AssetName -match '^OpenAI\.Codex_([0-9.]+)_') {
    $assetPackageVersion = $matches[1]
}
if ($assetPackageVersion -and $currentVersion -eq $assetPackageVersion) {
    Write-Step "Already on the latest package version ($currentVersion). No download needed."
    Remove-TreeRobust -Path $runDir
    Remove-SelfTempDir
    return
}

$msixPath = Join-Path $downloadDir $releaseInfo.AssetName
$downloadUrls = @()
if ($activeRepo -eq 'Wangnov/codex-app-mirror') {
    $mirrorUrl = if ($arch -eq 'arm64') {
        'https://codexapp-r2.agentsmirror.com/latest/win-arm64'
    } else {
        'https://codexapp-r2.agentsmirror.com/latest/win-x64'
    }
    $downloadUrls += $mirrorUrl
}
$downloadUrls += $releaseInfo.DownloadUrl

$downloadedFrom = Download-FileWithFallback -Urls $downloadUrls -OutputPath $msixPath
Write-Step "Downloaded from: $downloadedFrom"

$actualSha = (Get-FileHash -LiteralPath $msixPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actualSha -ne $releaseInfo.ExpectedSha256) {
    throw "SHA256 mismatch. Expected $($releaseInfo.ExpectedSha256), got $actualSha"
}
Write-Step 'SHA256 verified.'

Write-Step 'Extracting MSIX.'
& tar.exe -xf $msixPath -C $extractDir
if ($LASTEXITCODE -ne 0) {
    throw "tar extraction failed with exit code $LASTEXITCODE"
}

$newVersion = Get-AppxManifestVersion -Root $extractDir
if (-not $newVersion) {
    throw 'Extracted package does not contain a readable AppxManifest.xml.'
}

$newManifest = [xml](Get-Content -LiteralPath (Join-Path $extractDir 'AppxManifest.xml') -Raw)
if ([string]$newManifest.Package.Identity.Name -ne 'OpenAI.Codex') {
    throw "Unexpected package identity: $($newManifest.Package.Identity.Name)"
}
if ([string]$newManifest.Package.Identity.ProcessorArchitecture -ne $arch) {
    throw "Unexpected package architecture: $($newManifest.Package.Identity.ProcessorArchitecture)"
}

Write-Step "New package version: $newVersion"
if ($currentVersion -eq $newVersion) {
    Write-Step 'Already on the latest package version. Cleaning temporary files.'
    Remove-TreeRobust -Path $runDir
    Remove-SelfTempDir
    return
}

if (-not $isFreshInstall) {
    Wait-ForCodexToClose -TargetDir $installFull
}

$oldPackageFiles = if ($isFreshInstall) {
    [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
} else {
    Get-AppxBlockMapFiles -Root $installFull
}
$customRelativeFiles = @()
if (-not $isFreshInstall) {
    $customRelativeFiles = @(Get-PreservedInstallFiles -InstallRoot $installFull -PackageFiles $oldPackageFiles -PreserveExtra:$PreserveExtraInstallFiles)
}
Write-Step "Whitelisted install-dir files to preserve: $($customRelativeFiles.Count)"

$replaceSucceeded = $false
try {
    if (-not $isFreshInstall) {
        Write-Step "Creating verified backup before touching install directory: $backupDir"
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        Invoke-RobocopyMirror -Source $installFull -Destination $backupDir
        $backupVersion = Assert-ValidCodexInstallCopy -Path $backupDir -Label 'Backup'
        Write-Step "Backup verified: $backupVersion"
    }

    Write-Step "Building staged install directory: $stageInstallDir"
    New-Item -ItemType Directory -Force -Path $stageInstallDir | Out-Null
    Invoke-RobocopyMirror -Source $extractDir -Destination $stageInstallDir

    foreach ($rel in $customRelativeFiles) {
        $oldFile = Join-Path $backupDir $rel
        $dest = Join-Path $stageInstallDir $rel
        if ((Test-Path -LiteralPath $oldFile) -and -not (Test-Path -LiteralPath $dest)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath $oldFile -Destination $dest -Force
        }
    }

    $stagedVersion = Assert-ValidCodexInstallCopy -Path $stageInstallDir -Label 'Staged install'
    if ($stagedVersion -ne $newVersion) {
        throw "Staged version check failed. Expected $newVersion, got $stagedVersion"
    }

    if ($isFreshInstall) {
        Write-Step "Installing Codex into: $installFull"
        if (Test-Path -LiteralPath $installFull) {
            if (-not (Test-EmptyOrMissingDirectory -Path $installFull)) {
                throw "Fresh install target is not empty: $installFull"
            }
            Remove-TreeRobust -Path $installFull
        }
        Move-Item -LiteralPath $stageInstallDir -Destination $installFull
    } else {
        Write-Step "Moving current install aside: $oldInstallDir"
        Move-Item -LiteralPath $installFull -Destination $oldInstallDir
        try {
            Write-Step 'Promoting staged install into final directory.'
            Move-Item -LiteralPath $stageInstallDir -Destination $installFull
        } catch {
            Write-Step "Promote failed: $($_.Exception.Message)"
            Restore-InstallFromSafetyCopies -InstallPath $installFull -OldInstallPath $oldInstallDir -BackupPath $backupDir
            throw
        }
    }

    $installedVersion = Assert-ValidCodexInstallCopy -Path $installFull -Label 'Installed Codex'
    if ($installedVersion -ne $newVersion) {
        throw "Post-update version check failed. Expected $newVersion, got $installedVersion"
    }

    $runBat = Join-Path $installFull 'Run-Codex.cmd'
    if (-not (Test-Path -LiteralPath $runBat)) {
        "@echo off`r`ncd /d ""%~dp0app""`r`nstart """" ""%~dp0app\Codex.exe""`r`n" |
            Set-Content -LiteralPath $runBat -Encoding ascii
    }

    $replaceSucceeded = $true
    if ($isFreshInstall) {
        Write-Step "Installed successfully: $installedVersion."
    } else {
        Write-Step "Updated successfully to $installedVersion."
    }
} catch {
    Write-Step "Update failed: $($_.Exception.Message)"
    if (-not $isFreshInstall) {
        Write-Step 'Attempting rollback.'
        Restore-InstallFromSafetyCopies -InstallPath $installFull -OldInstallPath $oldInstallDir -BackupPath $backupDir
    }
    throw
} finally {
    if ($replaceSucceeded -and (Test-Path -LiteralPath $oldInstallDir)) {
        Write-Step 'Removing old install directory after successful verification.'
        Remove-TreeRobust -Path $oldInstallDir
    }
    if ($replaceSucceeded -and (Test-Path -LiteralPath $stageInstallDir)) {
        Write-Step 'Removing unused staged install directory.'
        Remove-TreeRobust -Path $stageInstallDir
    }
    if ($replaceSucceeded -and -not $KeepBackup -and (Test-Path -LiteralPath $backupDir)) {
        Write-Step 'Removing backup after successful verification.'
        Remove-TreeRobust -Path $backupDir
        Remove-Item -LiteralPath $backupRoot -Force -ErrorAction SilentlyContinue
    }
}

if ($RemoveRegisteredAppx) {
    $registered = Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue
    if ($registered) {
        Write-Step 'Removing registered AppX package because -RemoveRegisteredAppx was supplied.'
        Remove-AppxPackage -Package $registered.PackageFullName
    }
}

Write-Step 'Cleaning updater work directory.'
Remove-TreeRobust -Path $runDir
Remove-Item -LiteralPath $workRoot -Force -ErrorAction SilentlyContinue
Remove-SelfTempDir

if (-not $NoLaunch) {
    Write-Step 'Launching Codex from the updated install directory.'
    Start-Process -FilePath (Join-Path $installFull 'app\Codex.exe') -WorkingDirectory (Join-Path $installFull 'app')
}

Write-Step 'Done.'
