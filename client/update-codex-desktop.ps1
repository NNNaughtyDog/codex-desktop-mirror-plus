param(
    [string] $InstallDir = 'D:\software\Codex',
    [string] $Repo = 'Wangnov/codex-app-mirror',
    [switch] $NoLaunch,
    [switch] $KeepBackup,
    [switch] $RemoveRegisteredAppx
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param([string] $Message)
    Write-Host "[Codex updater] $Message"
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

function Get-CurlProxyArgs {
    $candidates = @()

    foreach ($name in @('HTTPS_PROXY', 'HTTP_PROXY', 'ALL_PROXY')) {
        $value = [Environment]::GetEnvironmentVariable($name)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $candidates += $value.Trim()
        }
    }

    foreach ($key in @('https.proxy', 'http.proxy')) {
        try {
            $value = (& git config --global --get $key 2>$null)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                $candidates += $value.Trim()
            }
        } catch {
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

$installFull = Resolve-CodexInstallDir -DefaultPath $InstallDir
$installParent = Split-Path -Parent $installFull
Assert-SafeDirectory -Path $installFull -ExpectedParent $installParent
$isFreshInstall = -not (Test-CodexInstallDir -Path $installFull)

$arch = if ($env:PROCESSOR_ARCHITECTURE -match 'ARM64') { 'arm64' } else { 'x64' }
$workRoot = Join-Path $installParent 'Codex-updater-work'
$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$runDir = Join-Path $workRoot $runId
$downloadDir = Join-Path $runDir 'download'
$extractDir = Join-Path $runDir 'extract'
$backupDir = Join-Path $runDir 'backup-old-codex'

Assert-SafeDirectory -Path $workRoot -ExpectedParent $installParent
New-Item -ItemType Directory -Force -Path $downloadDir, $extractDir | Out-Null

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
    Remove-TreeRobust -Path $workRoot
    return
}

$msixPath = Join-Path $downloadDir $releaseInfo.AssetName
$downloadUrls = @($releaseInfo.DownloadUrl)
if ($activeRepo -eq 'Wangnov/codex-app-mirror') {
    $mirrorUrl = if ($arch -eq 'arm64') {
        'https://codexapp-r2.agentsmirror.com/latest/win-arm64'
    } else {
        'https://codexapp-r2.agentsmirror.com/latest/win-x64'
    }
    $downloadUrls += $mirrorUrl
}

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
    Remove-TreeRobust -Path $workRoot
    return
}

if (-not $isFreshInstall) {
    Wait-ForCodexToClose -TargetDir $installFull
}

$customRelativeFiles = @()
$oldPackageFiles = if ($isFreshInstall) {
    [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
} else {
    Get-AppxBlockMapFiles -Root $installFull
}
if (-not $isFreshInstall -and $oldPackageFiles.Count -gt 0) {
    $customRelativeFiles = @(Get-ChildItem -LiteralPath $installFull -Recurse -Force -File -ErrorAction SilentlyContinue | Where-Object {
        $rel = $_.FullName.Substring($installFull.Length).TrimStart('\')
        -not $oldPackageFiles.Contains($rel)
    } | ForEach-Object {
        $_.FullName.Substring($installFull.Length).TrimStart('\')
    })
}
Write-Step "Custom install-dir files to preserve: $($customRelativeFiles.Count)"

$replaceSucceeded = $false
try {
    if ($isFreshInstall) {
        Write-Step "Installing Codex into: $installFull"
        New-Item -ItemType Directory -Force -Path $installFull | Out-Null
    } else {
        Write-Step "Moving old install to backup: $backupDir"
        Move-Item -LiteralPath $installFull -Destination $backupDir
        Write-Step 'Copying new package into install directory.'
        New-Item -ItemType Directory -Force -Path $installFull | Out-Null
    }

    Write-Step 'Copying package files.'
    Invoke-RobocopyMirror -Source $extractDir -Destination $installFull

    foreach ($rel in $customRelativeFiles) {
        $oldFile = Join-Path $backupDir $rel
        $dest = Join-Path $installFull $rel
        if ((Test-Path -LiteralPath $oldFile) -and -not (Test-Path -LiteralPath $dest)) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            Copy-Item -LiteralPath $oldFile -Destination $dest -Force
        }
    }

    $installedVersion = Get-AppxManifestVersion -Root $installFull
    if ($installedVersion -ne $newVersion) {
        throw "Post-update version check failed. Expected $newVersion, got $installedVersion"
    }
    if (-not (Test-Path -LiteralPath (Join-Path $installFull 'app\Codex.exe'))) {
        throw 'Post-update Codex.exe check failed.'
    }

    $runBat = Join-Path $installFull '运行Codex.bat'
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
    if (Test-Path -LiteralPath $installFull) {
        Remove-TreeRobust -Path $installFull
    }
    if (-not $isFreshInstall -and (Test-Path -LiteralPath $backupDir)) {
        Write-Step 'Attempting rollback.'
        Move-Item -LiteralPath $backupDir -Destination $installFull
    }
    throw
} finally {
    if ($replaceSucceeded -and -not $KeepBackup -and (Test-Path -LiteralPath $backupDir)) {
        Write-Step 'Removing backup after successful verification.'
        Remove-TreeRobust -Path $backupDir
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
Remove-TreeRobust -Path $workRoot

if (-not $NoLaunch) {
    Write-Step 'Launching Codex from the updated install directory.'
    Start-Process -FilePath (Join-Path $installFull 'app\Codex.exe') -WorkingDirectory (Join-Path $installFull 'app')
}

Write-Step 'Done.'
