param(
    [string] $InstallDir = 'D:\software\Codex',
    [string] $Repo = 'NNNaughtyDog/codex-desktop-mirror-plus',
    [switch] $NoLaunch,
    [switch] $KeepBackup,
    [switch] $RemoveRegisteredAppx,
    [switch] $IncludePrerelease
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param([string] $Message)
    Write-Host "[ChatGPT/Codex updater] $Message"
}

function Get-FullPath {
    param([string] $Path)
    return [IO.Path]::GetFullPath($Path)
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

function Get-AppxManifestInfo {
    param([string] $Root)

    $manifestPath = Join-Path $Root 'AppxManifest.xml'
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        return $null
    }

    $xml = [xml](Get-Content -LiteralPath $manifestPath -Raw)
    $application = $xml.Package.Applications.Application | Select-Object -First 1
    [pscustomobject]@{
        Name = [string]$xml.Package.Identity.Name
        Version = [string]$xml.Package.Identity.Version
        Architecture = [string]$xml.Package.Identity.ProcessorArchitecture
        Publisher = [string]$xml.Package.Identity.Publisher
        Executable = ([string]$application.Executable -replace '/', '\')
    }
}

function Get-CodexExecutablePath {
    param([string] $Root)

    $info = Get-AppxManifestInfo -Root $Root
    if ($info -and $info.Executable) {
        $declared = Join-Path $Root $info.Executable
        if (Test-Path -LiteralPath $declared) {
            return $declared
        }
    }

    foreach ($fallback in @('app\ChatGPT.exe', 'app\Codex.exe')) {
        $path = Join-Path $Root $fallback
        if (Test-Path -LiteralPath $path) {
            return $path
        }
    }

    return $null
}

function Test-CodexInstallDir {
    param([string] $Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path)) {
        return $false
    }
    $info = Get-AppxManifestInfo -Root $Path
    return $info -and $info.Name -eq 'OpenAI.Codex' -and [bool](Get-CodexExecutablePath -Root $Path)
}

function Resolve-CodexInstallDir {
    param([string] $DefaultPath)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($DefaultPath)) {
        $candidates += $DefaultPath
    }

    $runningRoots = Get-Process -Name 'ChatGPT','Codex','codex' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -match '\\app\\[^\\]+\.exe$' } |
        ForEach-Object { Split-Path -Parent (Split-Path -Parent $_.Path) } |
        Select-Object -Unique
    $candidates += $runningRoots

    foreach ($candidate in ($candidates | Select-Object -Unique)) {
        if (Test-CodexInstallDir -Path $candidate) {
            return (Get-FullPath $candidate)
        }
    }

    Write-Host ''
    Write-Host "Could not find ChatGPT/Codex desktop at the default location: $DefaultPath"
    Write-Host 'Please enter the absolute path to the install folder.'
    Write-Host 'Example: D:\software\Codex'

    while ($true) {
        $inputPath = Read-RequiredInput -Prompt 'Install folder'
        if (-not [IO.Path]::IsPathRooted($inputPath)) {
            Write-Host 'Please enter an absolute path, for example D:\software\Codex.'
            continue
        }
        if (Test-CodexInstallDir -Path $inputPath) {
            return (Get-FullPath $inputPath)
        }
        Write-Host "That folder does not look like a ChatGPT/Codex desktop install: $inputPath"
        Write-Host 'It should contain AppxManifest.xml and the executable declared in that manifest.'
    }
}

function Wait-ForAppToClose {
    param([string] $TargetDir)
    $targetFull = Get-FullPath $TargetDir

    while ($true) {
        $running = @(Get-Process -Name 'ChatGPT','Codex','codex' -ErrorAction SilentlyContinue | Where-Object {
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
        Write-Step "App is still running from $TargetDir. Close it to continue. PIDs: $ids"
        Start-Sleep -Seconds 5
    }
}

function Get-LatestRelease {
    param([string] $RepoName)

    if ($IncludePrerelease) {
        $uri = "https://api.github.com/repos/$RepoName/releases?per_page=20"
        $releases = Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'chatgpt-codex-desktop-updater' }
        $release = $releases |
            Where-Object { -not $_.draft } |
            Sort-Object {[datetime]$_.published_at} -Descending |
            Select-Object -First 1
        if (-not $release) {
            throw "No releases found in $RepoName."
        }
        return $release
    }

    $uri = "https://api.github.com/repos/$RepoName/releases/latest"
    return Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'chatgpt-codex-desktop-updater' }
}

function Get-ReleaseChecksumMap {
    param($Release)

    $map = @{}
    $sumAsset = $Release.assets | Where-Object { $_.name -eq 'SHA256SUMS-windows.txt' } | Select-Object -First 1
    if (-not $sumAsset) {
        return $map
    }

    $response = Invoke-WebRequest -UseBasicParsing -Uri $sumAsset.browser_download_url
    $content = if ($response.Content -is [byte[]]) {
        [Text.Encoding]::UTF8.GetString($response.Content)
    } else {
        [string]$response.Content
    }
    foreach ($line in ($content -split "`r?`n")) {
        if ($line -match '^([a-fA-F0-9]{64})\s+(.+)$') {
            $map[$matches[2].Trim()] = $matches[1].ToLowerInvariant()
        }
    }
    return $map
}

function Get-LatestReleaseAsset {
    param(
        [string] $RepoName,
        [string] $Arch
    )

    Write-Step "Checking GitHub release: https://github.com/$RepoName/releases"
    $release = Get-LatestRelease -RepoName $RepoName
    $asset = $release.assets |
        Where-Object { $_.name -match "^OpenAI\.Codex_[0-9.]+_${Arch}__2p2nqsd0c76g0\.(M|m)six$" } |
        Select-Object -First 1

    if (-not $asset) {
        throw "No Windows $Arch MSIX asset found in release $($release.tag_name)."
    }

    $expectedSha = $null
    if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest) {
        $expectedSha = ([string]$asset.digest) -replace '^sha256:', ''
    }
    if (-not $expectedSha) {
        $checksumMap = Get-ReleaseChecksumMap -Release $release
        if ($checksumMap.ContainsKey($asset.name)) {
            $expectedSha = $checksumMap[$asset.name]
        }
    }
    if (-not $expectedSha) {
        throw "Could not find SHA256 for $($asset.name)."
    }

    [pscustomobject]@{
        Tag = $release.tag_name
        Name = $release.name
        AssetName = $asset.name
        DownloadUrl = $asset.browser_download_url
        ExpectedSha256 = $expectedSha.ToLowerInvariant()
    }
}

function Download-File {
    param(
        [string] $Url,
        [string] $OutputPath
    )

    Write-Step "Downloading: $Url"
    & curl.exe -L --fail --retry 5 --retry-delay 2 --connect-timeout 30 --continue-at - --output $OutputPath $Url
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutputPath)) {
        throw "Download failed with exit code $LASTEXITCODE"
    }
}

$repoName = Normalize-GitHubRepo -Value $Repo
$installFull = Resolve-CodexInstallDir -DefaultPath $InstallDir
$installParent = Split-Path -Parent $installFull
Assert-SafeDirectory -Path $installFull -ExpectedParent $installParent

$currentInfo = Get-AppxManifestInfo -Root $installFull
$arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'x64' }
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$workRoot = Join-Path ([IO.Path]::GetTempPath()) 'ChatGPTCodexDesktopUpdater'
$runDir = Join-Path $workRoot $runId
$downloadDir = Join-Path $runDir 'download'
$extractDir = Join-Path $runDir 'extract'
$backupRoot = Join-Path $installParent 'Codex-updater-backup'
$backupDir = Join-Path $backupRoot $runId
$stageDir = Join-Path $installParent ('Codex-updater-new-' + $runId)
$oldDir = Join-Path $installParent ('Codex-updater-old-' + $runId)

New-Item -ItemType Directory -Force -Path $downloadDir, $extractDir | Out-Null
Write-Step "Current install: $installFull"
Write-Step "Current package version: $($currentInfo.Version)"
Write-Step "Current executable: $($currentInfo.Executable)"
Write-Step "Detected architecture: $arch"

$releaseInfo = Get-LatestReleaseAsset -RepoName $repoName -Arch $arch
Write-Step "Latest release: $($releaseInfo.Tag)"
Write-Step "Latest asset: $($releaseInfo.AssetName)"

$assetPackageVersion = $null
if ($releaseInfo.AssetName -match '^OpenAI\.Codex_([0-9.]+)_') {
    $assetPackageVersion = $matches[1]
}
if ($assetPackageVersion -and $currentInfo.Version -eq $assetPackageVersion) {
    Write-Step "Already on the latest package version ($($currentInfo.Version))."
    Remove-TreeRobust -Path $runDir
    return
}

$msixPath = Join-Path $downloadDir $releaseInfo.AssetName
Download-File -Url $releaseInfo.DownloadUrl -OutputPath $msixPath

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

$newInfo = Get-AppxManifestInfo -Root $extractDir
if (-not $newInfo) {
    throw 'Extracted package does not contain a readable AppxManifest.xml.'
}
if ($newInfo.Name -ne 'OpenAI.Codex') {
    throw "Unexpected package identity: $($newInfo.Name)"
}
if ($newInfo.Architecture -ne $arch) {
    throw "Unexpected package architecture: $($newInfo.Architecture)"
}
if (-not (Get-CodexExecutablePath -Root $extractDir)) {
    throw "Extracted package does not contain its declared executable: $($newInfo.Executable)"
}

Write-Step "New package version: $($newInfo.Version)"
Write-Step "New executable: $($newInfo.Executable)"
if ($currentInfo.Version -eq $newInfo.Version) {
    Write-Step 'Already on the latest package version. Cleaning temporary files.'
    Remove-TreeRobust -Path $runDir
    return
}

Wait-ForAppToClose -TargetDir $installFull

$replaceSucceeded = $false
try {
    Write-Step "Creating verified backup: $backupDir"
    New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
    Invoke-RobocopyMirror -Source $installFull -Destination $backupDir
    if (-not (Test-CodexInstallDir -Path $backupDir)) {
        throw "Backup is not a valid OpenAI.Codex install: $backupDir"
    }

    Write-Step "Building staged install: $stageDir"
    New-Item -ItemType Directory -Force -Path $stageDir | Out-Null
    Invoke-RobocopyMirror -Source $extractDir -Destination $stageDir
    if (-not (Test-CodexInstallDir -Path $stageDir)) {
        throw "Staged install is not valid: $stageDir"
    }

    Write-Step "Moving current install aside: $oldDir"
    Move-Item -LiteralPath $installFull -Destination $oldDir

    Write-Step 'Promoting staged install.'
    Move-Item -LiteralPath $stageDir -Destination $installFull

    $installedInfo = Get-AppxManifestInfo -Root $installFull
    if ($installedInfo.Version -ne $newInfo.Version) {
        throw "Post-update version check failed. Expected $($newInfo.Version), got $($installedInfo.Version)"
    }
    if (-not (Get-CodexExecutablePath -Root $installFull)) {
        throw 'Post-update executable check failed.'
    }

    $replaceSucceeded = $true
    Write-Step "Updated successfully to $($installedInfo.Version)."
} catch {
    Write-Step "Update failed: $($_.Exception.Message)"
    Write-Step 'Attempting rollback.'
    if ((Test-Path -LiteralPath $installFull) -and -not (Test-CodexInstallDir -Path $installFull)) {
        Remove-TreeRobust -Path $installFull
    }
    if (-not (Test-Path -LiteralPath $installFull)) {
        if ((Test-Path -LiteralPath $oldDir) -and (Test-CodexInstallDir -Path $oldDir)) {
            Move-Item -LiteralPath $oldDir -Destination $installFull
        } elseif ((Test-Path -LiteralPath $backupDir) -and (Test-CodexInstallDir -Path $backupDir)) {
            New-Item -ItemType Directory -Force -Path $installFull | Out-Null
            Invoke-RobocopyMirror -Source $backupDir -Destination $installFull
        }
    }
    throw
} finally {
    if ($replaceSucceeded -and (Test-Path -LiteralPath $oldDir)) {
        try { Remove-TreeRobust -Path $oldDir } catch { Write-Step "Warning: could not remove old install: $($_.Exception.Message)" }
    }
    if ($replaceSucceeded -and (Test-Path -LiteralPath $stageDir)) {
        try { Remove-TreeRobust -Path $stageDir } catch { Write-Step "Warning: could not remove staged install: $($_.Exception.Message)" }
    }
    if ($replaceSucceeded -and -not $KeepBackup -and (Test-Path -LiteralPath $backupDir)) {
        try { Remove-TreeRobust -Path $backupDir } catch { Write-Step "Warning: could not remove backup: $($_.Exception.Message)" }
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
try { Remove-TreeRobust -Path $runDir } catch { Write-Step "Warning: could not remove work directory: $($_.Exception.Message)" }

if (-not $NoLaunch) {
    $exe = Get-CodexExecutablePath -Root $installFull
    Write-Step "Launching: $exe"
    Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
}

Write-Step 'Done.'
