param(
    [string] $OutDir = '.\dist',
    [string] $ProductId = '9PLM9XGG6VKS',
    [ValidateSet('Retail', 'RP', 'WIS', 'WIF')]
    [string] $Ring = 'Retail',
    [string] $Lang = 'en-US'
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

function Invoke-CurlDownload {
    param(
        [string] $Url,
        [string] $OutputPath
    )

    if (-not (Get-Command curl.exe -ErrorAction SilentlyContinue)) {
        throw 'curl.exe is required.'
    }

    Write-Step "Downloading $Url"
    & curl.exe -L --fail --retry 5 --retry-delay 2 --connect-timeout 30 --output $OutputPath $Url
    if ($LASTEXITCODE -ne 0) {
        throw "curl failed with exit code $LASTEXITCODE"
    }
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
        $application = $xml.Package.Applications.Application | Select-Object -First 1
        return [pscustomobject]@{
            Name = [string]$xml.Package.Identity.Name
            Version = [string]$xml.Package.Identity.Version
            Architecture = [string]$xml.Package.Identity.ProcessorArchitecture
            Publisher = [string]$xml.Package.Identity.Publisher
            DisplayName = [string]$xml.Package.Properties.DisplayName
            Executable = [string]$application.Executable
        }
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Get-StoreFileLinks {
    param(
        [string] $StoreProductId,
        [string] $StoreRing,
        [string] $StoreLang
    )

    $body = "type=ProductId&url=$StoreProductId&ring=$StoreRing&lang=$StoreLang"
    $headers = @{
        'User-Agent' = 'Mozilla/5.0 codex-desktop-mirror-plus'
        'Referer' = 'https://store.rg-adguard.net/'
    }

    Write-Step "Resolving Microsoft Store package links for ProductId=$StoreProductId Ring=$StoreRing."
    $response = Invoke-WebRequest `
        -UseBasicParsing `
        -Method POST `
        -Uri 'https://store.rg-adguard.net/api/GetFiles' `
        -Body $body `
        -ContentType 'application/x-www-form-urlencoded' `
        -Headers $headers `
        -TimeoutSec 90

    $content = [string]$response.Content
    if ($content -notmatch 'OpenAI\.Codex_') {
        throw 'The Store file resolver did not return OpenAI.Codex packages.'
    }

    $rows = @()
    foreach ($match in [regex]::Matches($content, '<tr.*?</tr>', 'Singleline')) {
        $row = $match.Value
        if ($row -match '<a href="([^"]+)"[^>]*>([^<]+)</a>.*?<td align="center">([^<]+)</td>.*?<td align="center">([^<]+)</td>.*?<td align="center">([^<]+)</td>') {
            $rows += [pscustomobject]@{
                Url = [System.Net.WebUtility]::HtmlDecode($matches[1])
                File = [System.Net.WebUtility]::HtmlDecode($matches[2])
                Expire = $matches[3]
                Sha1 = $matches[4].ToLowerInvariant()
                SizeText = $matches[5]
            }
        }
    }

    $packages = @($rows | Where-Object {
        $_.File -match '^OpenAI\.Codex_[0-9.]+_(x64|arm64)__2p2nqsd0c76g0\.msix$'
    } | Sort-Object File)

    if ($packages.Count -eq 0) {
        throw 'No OpenAI.Codex Windows MSIX files were found in the Store file list.'
    }

    return $packages
}

$outFull = [IO.Path]::GetFullPath($OutDir)
$downloadDir = Join-Path $outFull 'download'
$assetsDir = Join-Path $outFull 'assets'
Remove-Item -LiteralPath $outFull -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $downloadDir, $assetsDir | Out-Null

$storeFiles = @(Get-StoreFileLinks -StoreProductId $ProductId -StoreRing $Ring -StoreLang $Lang)
$items = @()

foreach ($storeFile in $storeFiles) {
    $downloadName = $storeFile.File
    $downloadPath = Join-Path $downloadDir $downloadName
    Invoke-CurlDownload -Url $storeFile.Url -OutputPath $downloadPath

    $actualSha1 = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA1).Hash.ToLowerInvariant()
    if ($actualSha1 -ne $storeFile.Sha1) {
        throw "SHA1 mismatch for $downloadName. Expected $($storeFile.Sha1), got $actualSha1"
    }

    $manifest = Read-PackageManifest -MsixPath $downloadPath
    if ($manifest.Name -ne 'OpenAI.Codex') {
        throw "Unexpected package identity in $downloadName`: $($manifest.Name)"
    }
    if ($manifest.Architecture -notin @('x64', 'arm64')) {
        throw "Unexpected package architecture in $downloadName`: $($manifest.Architecture)"
    }
    if (-not $manifest.Executable) {
        throw "Package $downloadName does not declare an application executable."
    }

    $normalizedName = "OpenAI.Codex_$($manifest.Version)_$($manifest.Architecture)__2p2nqsd0c76g0.msix"
    $dest = Join-Path $assetsDir $normalizedName
    Copy-Item -LiteralPath $downloadPath -Destination $dest -Force

    $items += [pscustomobject][ordered]@{
        file = $normalizedName
        sha256 = Get-Sha256 -Path $dest
        sha1 = $actualSha1
        size = (Get-Item -LiteralPath $dest).Length
        packageIdentity = $manifest.Name
        packageVersion = $manifest.Version
        architecture = $manifest.Architecture
        publisher = $manifest.Publisher
        displayName = $manifest.DisplayName
        executable = ($manifest.Executable -replace '/', '\')
        source = [ordered]@{
            method = 'microsoft-store-cdn'
            productId = $ProductId
            ring = $Ring
            resolver = 'store.rg-adguard.net'
            storeFile = $storeFile.File
            storeSha1 = $storeFile.Sha1
            expiresUtc = $storeFile.Expire
        }
    }
}

$versions = @($items | Select-Object -ExpandProperty packageVersion -Unique)
if ($versions.Count -ne 1) {
    throw "Expected one package version, found: $($versions -join ', ')"
}

$releaseVersion = $versions[0]
$releaseTag = "chatgpt-codex-windows-$releaseVersion"

$checksumsPath = Join-Path $assetsDir 'SHA256SUMS-windows.txt'
$items |
    Sort-Object architecture |
    ForEach-Object { "$($_.sha256)  $($_.file)" } |
    Set-Content -LiteralPath $checksumsPath -Encoding utf8

$manifestObject = [ordered]@{
    schema = 2
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    releaseTag = $releaseTag
    packageVersion = $releaseVersion
    packageIdentity = 'OpenAI.Codex'
    productName = 'ChatGPT'
    productId = $ProductId
    assets = $items
}

$manifestPath = Join-Path $assetsDir 'release-manifest.json'
$manifestObject | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8

$assetLines = $items |
    Sort-Object architecture |
    ForEach-Object {
        "- $($_.architecture): ``$($_.file)`` ($([math]::Round($_.size / 1MB, 1)) MB), executable ``$($_.executable)``"
    } |
    Out-String

$releaseNotesPath = Join-Path $outFull 'RELEASE_NOTES.md'
@"
# ChatGPT / Codex Windows Desktop $releaseVersion

This release mirrors the Windows MSIX package for the ChatGPT desktop app that carries the Codex product identity (`OpenAI.Codex`).

The upstream app was rebranded from Codex to ChatGPT in the 26.707 line. The package identity remains `OpenAI.Codex`, while the application entry point may be `app\ChatGPT.exe`.

## Assets

$assetLines
## Verification

Use `SHA256SUMS-windows.txt` to verify downloaded files.

This repository mirrors installer files and does not modify or patch them.
"@ | Set-Content -LiteralPath $releaseNotesPath -Encoding utf8

$metadataPath = Join-Path $outFull 'release-metadata.json'
[ordered]@{
    releaseTag = $releaseTag
    releaseName = "ChatGPT / Codex Windows Desktop $releaseVersion"
    releaseNotes = $releaseNotesPath
    assetsDir = $assetsDir
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $metadataPath -Encoding utf8

Write-Step "Prepared release $releaseTag"
Write-Step "Assets directory: $assetsDir"
