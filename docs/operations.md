# Operations

## First-Time Setup

1. Push this repository to GitHub.
2. Enable GitHub Actions release publishing:
   `Settings -> Actions -> General -> Workflow permissions -> Read and write permissions`.
3. Run `Sync ChatGPT Codex Windows Mirror` manually once.

## What The Sync Job Does

`scripts/Sync-CodexWindowsMirror.ps1` resolves Microsoft Store product `9PLM9XGG6VKS` and downloads the current `OpenAI.Codex` MSIX files from Microsoft CDN.

The upstream product is branded as ChatGPT, but the Windows package identity remains:

```text
OpenAI.Codex
```

The 26.707 line may declare this executable in `AppxManifest.xml`:

```text
app\ChatGPT.exe
```

Older packages may declare or use:

```text
app\Codex.exe
```

The scripts must always trust `AppxManifest.xml`, not a hard-coded executable name.

## Local Publishing

```powershell
.\scripts\Sync-CodexWindowsMirror.ps1 -OutDir .\dist
.\scripts\Publish-GitHubRelease.ps1 -DistDir .\dist -Repo "NNNaughtyDog/codex-desktop-mirror-plus"
```

The Store CDN links returned by the resolver are temporary. Run sync and publish in the same job/session.

## Generated Assets

```text
OpenAI.Codex_<version>_x64__2p2nqsd0c76g0.msix
OpenAI.Codex_<version>_arm64__2p2nqsd0c76g0.msix
SHA256SUMS-windows.txt
release-manifest.json
```

Release tags use the package version:

```text
chatgpt-codex-windows-26.707.3748.0
```

## User Updater

Give users both files from `client/`:

```text
update-codex-desktop.ps1
run-update-codex-desktop.cmd
```

They should keep both files together and double-click the `.cmd`.

The updater:

- reads latest release assets from this repository by default;
- verifies SHA256 before extracting;
- validates `OpenAI.Codex` in `AppxManifest.xml`;
- supports `ChatGPT.exe` and `Codex.exe`;
- waits for the app to close instead of killing it;
- creates a verified backup before switching directories;
- attempts rollback on failure.

## Troubleshooting

### The sync job cannot resolve Store files

The resolver endpoint or Microsoft Store metadata may be temporarily unavailable. Re-run the workflow later, or run the sync script locally from a network that can reach Microsoft CDN.

### The updater says no MSIX asset exists

Make sure the latest GitHub release contains an asset matching:

```text
OpenAI.Codex_*_x64__2p2nqsd0c76g0.msix
OpenAI.Codex_*_arm64__2p2nqsd0c76g0.msix
```

### The app is still running

Close ChatGPT / Codex windows. The updater filters by executable path under the install root, so it should not confuse unrelated ChatGPT Classic installs with this package.

### The app name changed after update

That is expected. The Store listing is now ChatGPT, but this project continues tracking the Codex product identity `OpenAI.Codex`.
