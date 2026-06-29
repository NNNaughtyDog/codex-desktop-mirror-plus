# Operations

## First-Time Setup

1. Create a GitHub repository.
2. Push this project to it.
3. Enable GitHub Actions with read/write release permission:
   - Settings -> Actions -> General -> Workflow permissions -> Read and write permissions.
4. Run the workflow manually once.

## Local Publishing

Install GitHub CLI:

```powershell
winget install --id GitHub.cli -e
```

Authenticate with browser/device flow:

```powershell
gh auth login
```

Then publish:

```powershell
.\scripts\Sync-CodexWindowsMirror.ps1 -OutDir .\dist
.\scripts\Publish-GitHubRelease.ps1 -DistDir .\dist -Repo "your-name/your-repo"
```

## User Updater

Give users both files from `client/`:

```text
update-codex-desktop.ps1
run-update-codex-desktop.cmd
```

They should keep the files together and double-click the `.cmd`.

The updater:

- finds `D:\software\Codex` by default;
- prompts for an absolute path if Codex is elsewhere;
- prompts for a new GitHub mirror repo if the default disappears;
- verifies SHA256 before updating;
- keeps custom install-directory files that are not part of the old MSIX package;
- deletes temporary files and backup after a successful update.

## If The Mirror Repo Changes

Run the updater with a different repo:

```powershell
.\client\update-codex-desktop.ps1 -Repo "owner/repo"
```

or enter the replacement repo when prompted.

## Troubleshooting

### `winget download` fails

Microsoft Store downloads can be blocked by runner policy, region, or Store service changes.

Fallback:

1. Run `Sync-CodexWindowsMirror.ps1` on your own Windows machine.
2. Publish the generated `dist/assets` using `Publish-GitHubRelease.ps1`.

### GitHub Release asset is missing SHA256

The sync script writes `SHA256SUMS-windows.txt`; the user updater can use that even when GitHub asset digest metadata is unavailable.

### User updater says Codex is still running

Close all Codex windows. The updater waits instead of killing Codex to avoid interrupting active work.
