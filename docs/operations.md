# Operations

## First-Time Setup

1. Push this repository to GitHub.
2. Enable GitHub Actions release publishing:
   `Settings -> Actions -> General -> Workflow permissions -> Read and write permissions`.
3. Run `Sync ChatGPT Codex Windows Mirror` manually once, or push to `main` and let the workflow run.

## Product Identity

The Microsoft Store product ID is:

```text
9PLM9XGG6VKS
```

The upstream product is branded as ChatGPT, but the Windows package identity remains:

```text
OpenAI.Codex
```

New packages may declare this executable in `AppxManifest.xml`:

```text
app\ChatGPT.exe
```

Older packages may declare or use:

```text
app\Codex.exe
```

Scripts must trust `AppxManifest.xml`, not a hard-coded executable name.

## Workflow Behavior

`.github/workflows/sync-windows.yml` runs in three cases:

- push to `main`;
- manual `workflow_dispatch`;
- scheduled cron every 3 hours.

The default `auto` mode works like this:

- Push/manual runs perform a full sync and upload MSIX assets.
- Scheduled runs first resolve current Microsoft Store links.
- If the release tag already exists, scheduled runs refresh release notes and temporary link assets only.
- If a new package version is found and no release exists, scheduled runs perform a full sync and create the release.

This keeps `Temporary Direct Download Links` fresh without re-uploading 1GB+ packages every 3 hours.

## Local Publishing

Full sync:

```powershell
.\scripts\Sync-CodexWindowsMirror.ps1 -OutDir .\dist
.\scripts\Publish-GitHubRelease.ps1 -DistDir .\dist -Repo "NNNaughtyDog/codex-desktop-mirror-plus"
```

Temporary-link refresh only:

```powershell
.\scripts\Sync-CodexWindowsMirror.ps1 -OutDir .\dist -LinksOnly
.\scripts\Publish-GitHubRelease.ps1 -DistDir .\dist -Repo "NNNaughtyDog/codex-desktop-mirror-plus"
```

`Publish-GitHubRelease.ps1` edits an existing release title/notes before uploading assets, so refreshed temporary links appear on the GitHub Releases page.

## Generated Assets

Full sync generates:

```text
OpenAI.Codex_<version>_x64__2p2nqsd0c76g0.msix
OpenAI.Codex_<version>_arm64__2p2nqsd0c76g0.msix
SHA256SUMS-windows.txt
release-manifest.json
LATEST_TEMP_LINKS.md
store-temp-links.json
```

Links-only sync generates:

```text
release-manifest.json
LATEST_TEMP_LINKS.md
store-temp-links.json
```

Release tags use the package version:

```text
chatgpt-codex-windows-26.707.3748.0
```

## User Data Safety

Manual updates should replace only the unpacked app directory, for example:

```text
D:\software\Codex
```

Do not delete likely user-data locations:

```text
%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0
%APPDATA%\OpenAI
%USERPROFILE%\.codex
user project workspaces
```

The updater waits for the app to close, creates a verified backup of the install directory, switches directories, and attempts rollback on failure.

## Troubleshooting

### Releases did not update after pushing code

Check the `Sync ChatGPT Codex Windows Mirror` workflow run. A Git commit only changes the scripts; the release is updated after the workflow completes.

### GitHub Release exists but temporary links are stale

Run the workflow manually with `mode=links-only`. The release notes and `LATEST_TEMP_LINKS.md` should be edited in place.

### The updater says no MSIX asset exists

Make sure the latest release contains an asset matching:

```text
OpenAI.Codex_*_x64__2p2nqsd0c76g0.msix
OpenAI.Codex_*_arm64__2p2nqsd0c76g0.msix
```

If only temporary links exist, run a full sync.
