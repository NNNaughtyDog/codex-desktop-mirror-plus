param(
    [string] $OutDir = '.\dist',
    [string] $PackageId = '9PLM9XGG6VKS',
    [string] $Source = 'msstore',
    [string] $FallbackRepo = 'Wangnov/codex-app-mirror',
    [switch] $NoFallback
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param([string] $Message)
    Write-Host "[mirror-sync] $Message"
}

function Get-Sha256 {
    param([string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-PackageManifest {
    param([string] $MsixPath)
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('codex-msix-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $temp | Out-Null
    try {
        & tar.exe -xf $MsixPath -C $temp AppxManifest.xml
        if ($LASTEXITCODE -ne 0) {
            throw "tar failed with exit code $LASTEXITCODE"
        }
        $manifestPath = Join-Path $temp 'AppxManifest.xml'
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw 'MSIX does not contain AppxManifest.xml.'
        }
        $xml = [xml](Get-Content -LiteralPath $manifestPath -Raw)
        return [pscustomobject]@{
            Name = [string]$xml.Package.Identity.Name
            Version = [string]$xml.Package.Identity.Version
            Architecture = [string]$xml.Package.Identity.ProcessorArchitecture
            Publisher = [string]$xml.Package.Identity.Publisher
            DisplayName = [string]$xml.Package.Properties.DisplayName
        }
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-WingetDownload {
    param(
        [string] $Id,
        [string] $StoreSource,
        [string] $TargetDir
    )

    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) {
        throw 'winget.exe is required for Microsoft Store downloads.'
    }

    Write-Step "Running winget download for package '$Id' from source '$StoreSource'."
    $args = @(
        'download',
        '--id', $Id,
        '--source', $StoreSource,
        '--download-directory', $TargetDir,
        '--accept-package-agreements',
        '--accept-source-agreements',
        '--disable-interactivity'
    )

    & winget.exe @args
    if ($LASTEXITCODE -ne 0) {
        throw "winget download failed with exit code $LASTEXITCODE."
    }
}

function Get-GitHubRelease {
    param([string] $RepoName)
    $uri = "https://api.github.com/repos/$RepoName/releases/latest"
    return Invoke-RestMethod -Uri $uri -Headers @{ 'User-Agent' = 'codex-desktop-mirror-plus' }
}

function Get-ReleaseChecksumMap {
    param($Release)
    $map = @{}
    $sumAsset = $Release.assets | Where-Object { $_.name -eq 'SHA256SUMS-windows.txt' } | Select-Object -First 1
    if (-not $sumAsset) {
        return $map
    }

    try {
        $resp = Invoke-WebRequest -UseBasicParsing -Uri $sumAsset.browser_download_url
        $content = if ($resp.Content -is [byte[]]) {
            [Text.Encoding]::UTF8.GetString($resp.Content)
        } else {
            [string]$resp.Content
        }
        foreach ($line in ($content -split "`r?`n")) {
            if ($line -match '^([a-fA-F0-9]{64})\s+(.+)$') {
                $map[$matches[2].Trim()] = $matches[1].ToLowerInvariant()
            }
        }
    } catch {
        Write-Step "Could not read fallback checksum file: $($_.Exception.Message)"
    }
    return $map
}

function Invoke-GitHubFallbackDownload {
    param(
        [string] $RepoName,
        [string] $TargetDir
    )

    Write-Step "Falling back to GitHub mirror repo: $RepoName"
    $release = Get-GitHubRelease -RepoName $RepoName
    $checksumMap = Get-ReleaseChecksumMap -Release $release
    $assets = @($release.assets | Where-Object { $_.name -match '^OpenAI\.Codex_.*_(x64|arm64)__.*\.Msix$' })
    if ($assets.Count -eq 0) {
        throw "Fallback repo $RepoName does not expose Windows OpenAI.Codex MSIX assets on its latest release."
    }

    foreach ($asset in $assets) {
        $dest = Join-Path $TargetDir $asset.name
        Write-Step "Downloading fallback asset: $($asset.name)"
        & curl.exe -L --fail --retry 5 --retry-delay 2 --output $dest $asset.browser_download_url
        if ($LASTEXITCODE -ne 0) {
            throw "curl failed for $($asset.name) with exit code $LASTEXITCODE"
        }

        $actual = Get-Sha256 -Path $dest
        $expected = $null
        if ($asset.PSObject.Properties.Name -contains 'digest' -and $asset.digest) {
            $expected = ([string]$asset.digest) -replace '^sha256:', ''
        }
        if (-not $expected -and $checksumMap.ContainsKey($asset.name)) {
            $expected = $checksumMap[$asset.name]
        }
        if ($expected -and $actual -ne $expected.ToLowerInvariant()) {
            throw "SHA256 mismatch for $($asset.name). Expected $expected, got $actual"
        }
        Write-Step "Verified fallback asset: $($asset.name)"
    }
}

$outFull = [IO.Path]::GetFullPath($OutDir)
$downloadDir = Join-Path $outFull 'download'
$assetsDir = Join-Path $outFull 'assets'
Remove-Item -LiteralPath $outFull -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $downloadDir, $assetsDir | Out-Null

try {
    Invoke-WingetDownload -Id $PackageId -StoreSource $Source -TargetDir $downloadDir
} catch {
    if ($NoFallback) {
        throw
    }
    Write-Step "winget download failed: $($_.Exception.Message)"
    Invoke-GitHubFallbackDownload -RepoName $FallbackRepo -TargetDir $downloadDir
}

$msixFiles = @(Get-ChildItem -LiteralPath $downloadDir -Recurse -File -Include '*.msix','*.appx' |
    Where-Object { $_.Name -match 'Codex|OpenAI' -or $_.FullName -match 'Codex|OpenAI' })

if ($msixFiles.Count -eq 0) {
    $msixFiles = @(Get-ChildItem -LiteralPath $downloadDir -Recurse -File -Include '*.msix','*.appx')
}

if ($msixFiles.Count -eq 0) {
    throw 'No MSIX/AppX files were downloaded.'
}

$items = @()
foreach ($file in $msixFiles) {
    $manifest = Read-PackageManifest -MsixPath $file.FullName
    if ($manifest.Name -ne 'OpenAI.Codex') {
        Write-Step "Skipping non-Codex package: $($file.Name) identity=$($manifest.Name)"
        continue
    }

    $ext = $file.Extension
    $normalizedName = "OpenAI.Codex_$($manifest.Version)_$($manifest.Architecture)__2p2nqsd0c76g0$ext"
    $dest = Join-Path $assetsDir $normalizedName
    Copy-Item -LiteralPath $file.FullName -Destination $dest -Force

    $sha = Get-Sha256 -Path $dest
    $item = [ordered]@{
        file = $normalizedName
        sha256 = $sha
        size = (Get-Item -LiteralPath $dest).Length
        packageIdentity = $manifest.Name
        packageVersion = $manifest.Version
        architecture = $manifest.Architecture
        publisher = $manifest.Publisher
        displayName = $manifest.DisplayName
        source = @{
            method = 'winget download'
            packageId = $PackageId
            source = $Source
        }
    }
    $items += [pscustomobject]$item
}

if ($items.Count -eq 0) {
    throw 'Downloaded files did not include OpenAI.Codex packages.'
}

$versions = @($items | Select-Object -ExpandProperty packageVersion -Unique)
if ($versions.Count -ne 1) {
    throw "Expected one package version, found: $($versions -join ', ')"
}

$releaseVersion = $versions[0]
$releaseTag = "codex-windows-$releaseVersion"

$checksumsPath = Join-Path $assetsDir 'SHA256SUMS-windows.txt'
$items |
    Sort-Object architecture |
    ForEach-Object { "$($_.sha256)  $($_.file)" } |
    Set-Content -LiteralPath $checksumsPath -Encoding utf8

$manifestObject = [ordered]@{
    schema = 1
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    releaseTag = $releaseTag
    packageVersion = $releaseVersion
    packageIdentity = 'OpenAI.Codex'
    assets = $items
}

$manifestPath = Join-Path $assetsDir 'release-manifest.json'
$manifestObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8

$releaseNotesPath = Join-Path $outFull 'RELEASE_NOTES.md'
@"
# Codex Windows Desktop $releaseVersion

This release mirrors the Windows desktop MSIX package for OpenAI Codex.

## Assets

$($items | Sort-Object architecture | ForEach-Object { "- $($_.architecture): ``$($_.file)`` ($([math]::Round($_.size / 1MB, 1)) MB)" } | Out-String)
## Verification

Use ``SHA256SUMS-windows.txt`` to verify downloaded files.

This repository mirrors installer files and does not modify or patch them.
"@ | Set-Content -LiteralPath $releaseNotesPath -Encoding utf8

$metadataPath = Join-Path $outFull 'release-metadata.json'
[ordered]@{
    releaseTag = $releaseTag
    releaseName = "Codex Windows Desktop $releaseVersion"
    releaseNotes = $releaseNotesPath
    assetsDir = $assetsDir
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metadataPath -Encoding utf8

Write-Step "Prepared release $releaseTag"
Write-Step "Assets directory: $assetsDir"
