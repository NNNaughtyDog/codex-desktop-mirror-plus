param(
    [string] $DistDir = '.\dist',
    [string] $Repo,
    [switch] $Prerelease
)

$ErrorActionPreference = 'Stop'

function Write-Step {
    param([string] $Message)
    Write-Host "[release-publish] $Message"
}

if (-not $Repo) {
    $remote = git config --get remote.origin.url 2>$null
    if ($remote -match 'github\.com[:/]([^/]+)/([^/.]+)(\.git)?$') {
        $Repo = "$($matches[1])/$($matches[2])"
    }
}

if (-not $Repo) {
    throw 'Pass -Repo owner/repo or run inside a GitHub repository with origin configured.'
}

if (-not (Get-Command gh.exe -ErrorAction SilentlyContinue)) {
    throw 'GitHub CLI gh.exe is required to publish releases.'
}

$distFull = [IO.Path]::GetFullPath($DistDir)
$metadataPath = Join-Path $distFull 'release-metadata.json'
if (-not (Test-Path -LiteralPath $metadataPath)) {
    throw "Missing release metadata: $metadataPath"
}

$metadata = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$assetsDir = [string]$metadata.assetsDir
$tag = [string]$metadata.releaseTag
$name = [string]$metadata.releaseName
$notes = [string]$metadata.releaseNotes

if (-not (Test-Path -LiteralPath $assetsDir)) {
    throw "Missing assets directory: $assetsDir"
}

$existing = $false
& gh release view $tag --repo $Repo *> $null
if ($LASTEXITCODE -eq 0) {
    $existing = $true
}

if (-not $existing) {
    Write-Step "Creating release $tag in $Repo"
    $args = @('release', 'create', $tag, '--repo', $Repo, '--title', $name, '--notes-file', $notes)
    if ($Prerelease) {
        $args += '--prerelease'
    }
    & gh @args
    if ($LASTEXITCODE -ne 0) {
        throw "gh release create failed with exit code $LASTEXITCODE"
    }
} else {
    Write-Step "Release $tag already exists; uploading/replacing assets."
}

$assets = @(Get-ChildItem -LiteralPath $assetsDir -File)
foreach ($asset in $assets) {
    Write-Step "Uploading $($asset.Name)"
    & gh release upload $tag $asset.FullName --repo $Repo --clobber
    if ($LASTEXITCODE -ne 0) {
        throw "gh release upload failed for $($asset.Name) with exit code $LASTEXITCODE"
    }
}

Write-Step 'Done.'
