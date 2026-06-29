# Codex Desktop Mirror Plus

Codex Desktop Mirror Plus is a complete Windows desktop installer mirror template for OpenAI Codex Desktop.

It is designed for two jobs:

1. Mirror the latest Windows MSIX package into GitHub Releases with checksums and a machine-readable manifest.
2. Give users a safe updater script that can update an unpacked Codex desktop install, clean temporary files, and preserve local history/data.

> This project is an unofficial mirror template. It is not affiliated with OpenAI or Microsoft. Before publishing mirrored installers, review the applicable license, terms, and your local compliance requirements.

## What Makes This Different

- Full GitHub Actions workflow for scheduled and manual sync.
- Windows-first sync script using `winget download` from Microsoft Store.
- SHA256 checksum generation for every mirrored asset.
- `release-manifest.json` with package identity, architecture, version, file size, hashes, and source metadata.
- User-side updater that:
  - defaults to `D:\software\Codex`;
  - asks for an absolute Codex path if it cannot find one;
  - asks for a replacement GitHub mirror repo if the default mirror disappears;
  - verifies SHA256 before installing;
  - preserves non-package custom files in the install directory;
  - does not touch user history folders such as `%APPDATA%`, `%LOCALAPPDATA%`, `%USERPROFILE%\.codex`, or `Documents\Codex`;
  - removes temporary files and backup after successful verification.

## Repository Layout

```text
.github/workflows/sync-windows.yml       GitHub Actions scheduled mirror workflow
scripts/Sync-CodexWindowsMirror.ps1      Download, inspect, checksum, and prepare release assets
scripts/Publish-GitHubRelease.ps1        Create/update GitHub Release and upload assets
client/update-codex-desktop.ps1          End-user updater
client/run-update-codex-desktop.cmd      Double-click launcher for the updater
docs/operations.md                       Operating notes and troubleshooting
```

## Quick Start For Your GitHub Mirror

1. Create a new GitHub repository.
2. Upload all files from this project.
3. In repository settings, enable Actions and allow GitHub Actions to create releases:
   - Settings -> Actions -> General -> Workflow permissions -> Read and write permissions.
4. Run the workflow manually:
   - Actions -> Sync Windows Codex Desktop Mirror -> Run workflow.
5. If it succeeds, the workflow creates or updates a release like:

```text
codex-windows-26.623.5546.0
```

## Manual Mirror Sync

Run on Windows with `winget`, PowerShell 5.1+ or PowerShell 7+, and GitHub CLI if publishing:

```powershell
.\scripts\Sync-CodexWindowsMirror.ps1 -OutDir .\dist
.\scripts\Publish-GitHubRelease.ps1 -DistDir .\dist -Repo "your-name/your-repo"
```

## One-Command Deployment

If GitHub CLI is installed and you can complete browser authentication:

```powershell
.\scripts\Deploy-ToGitHub.ps1 -RepoName "codex-desktop-mirror-plus" -Visibility public
```

Do not paste GitHub passwords or tokens into chat tools. Use browser login or your local credential manager.

## User Updater

Users can download the two files under `client/` and keep them together:

```text
update-codex-desktop.ps1
run-update-codex-desktop.cmd
```

Double-click `run-update-codex-desktop.cmd`.

The updater defaults to `D:\software\Codex`. If Codex is somewhere else, it prompts for the absolute install path.

## Release Asset Requirements

The user updater expects GitHub Releases to contain:

- `OpenAI.Codex_..._x64__....Msix` or `OpenAI.Codex_..._arm64__....Msix`
- either GitHub asset `digest` metadata or `SHA256SUMS-windows.txt`

The provided mirror workflow creates both.

## Notes

- The workflow is Windows-only because it relies on `winget download`.
- Microsoft Store availability can vary by region, policy, and runner image.
- If `winget download` cannot fetch the package on GitHub Actions, run the sync script on your own Windows machine and upload assets with `Publish-GitHubRelease.ps1`.
