param(
    [string] $OutDir = '.\dist',
    [string] $PackageId = '9PLM9XGG6VKS',
    [string] $Source = 'msstore'
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

$outFull = [IO.Path]::GetFullPath($OutDir)
$downloadDir = Join-Path $outFull 'download'
$assetsDir = Join-Path $outFull 'assets'
Remove-Item -LiteralPath $outFull -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $downloadDir, $assetsDir | Out-Null

Invoke-WingetDownload -Id $PackageId -StoreSource $Source -TargetDir $downloadDir

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
