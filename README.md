# ChatGPT / Codex Desktop Mirror Plus

这个项目镜像 Windows 版 ChatGPT Desktop 中的 Codex 应用包，给无法直接使用 Microsoft Store 的用户提供完整 MSIX 安装包和本地更新脚本。

2026-07 起，上游把 Codex Desktop 合并进 ChatGPT 品牌：

- Microsoft Store 页面名称是 `ChatGPT`
- Windows 包身份仍是 `OpenAI.Codex`
- 新版入口可执行文件可能是 `app\ChatGPT.exe`
- 旧版入口可执行文件是 `app\Codex.exe`

本项目以包身份 `OpenAI.Codex` 为准，不再依赖旧的 `Wangnov/codex-app-mirror` fallback。

> 非官方项目。本项目不隶属于 OpenAI 或 Microsoft，不破解、不修改、不重打包安装器，只镜像官方 Microsoft CDN 下发的 MSIX 文件并发布校验值。

## 用户怎么更新

下载 `client/` 里的两个文件，放在同一个文件夹：

- `run-update-codex-desktop.cmd`
- `update-codex-desktop.ps1`

然后：

1. 关闭所有 ChatGPT / Codex 窗口。
2. 双击 `run-update-codex-desktop.cmd`。
3. 默认安装目录是 `D:\software\Codex`；如果不在这里，脚本会提示输入绝对路径。

脚本会：

- 从本仓库 GitHub Releases 下载最新 Windows MSIX。
- 自动识别 x64 / arm64。
- 校验 `SHA256SUMS-windows.txt`。
- 解包 MSIX 并确认包身份是 `OpenAI.Codex`。
- 从 `AppxManifest.xml` 读取真实入口，兼容 `ChatGPT.exe` 和 `Codex.exe`。
- 更新前备份旧安装目录，失败时尝试回滚。
- 默认更新成功后启动新版应用。

指定其他镜像仓库：

```powershell
.\client\update-codex-desktop.ps1 -Repo "owner/repo"
```

## 维护者怎么同步完整包

手动生成 release 资产：

```powershell
.\scripts\Sync-CodexWindowsMirror.ps1 -OutDir .\dist
.\scripts\Publish-GitHubRelease.ps1 -DistDir .\dist -Repo "NNNaughtyDog/codex-desktop-mirror-plus"
```

同步脚本会查询 Microsoft Store 产品 `9PLM9XGG6VKS` 的文件清单，下载：

```text
OpenAI.Codex_<version>_x64__2p2nqsd0c76g0.msix
OpenAI.Codex_<version>_arm64__2p2nqsd0c76g0.msix
```

并生成：

```text
SHA256SUMS-windows.txt
release-manifest.json
RELEASE_NOTES.md
release-metadata.json
```

Release tag 形如：

```text
chatgpt-codex-windows-26.707.3748.0
```

## GitHub Actions

工作流：

```text
Sync ChatGPT Codex Windows Mirror
```

默认每 6 小时运行一次，也可以在 Actions 页面手动触发。工作流需要仓库开启 release 写权限：

```text
Settings -> Actions -> General -> Workflow permissions -> Read and write permissions
```

## 安全校验

下载后可手动校验：

```powershell
Get-FileHash .\OpenAI.Codex_26.707.3748.0_x64__2p2nqsd0c76g0.msix -Algorithm SHA256
```

和 release 里的 `SHA256SUMS-windows.txt` 对比。

## 已废弃的旧方案

这些路径已经不再作为默认方案：

- `winget download`
- `Wangnov/codex-app-mirror` fallback
- `https://codexapp-r2.agentsmirror.com/latest/win-x64`
- 固定假设入口是 `app\Codex.exe`

原因是上游已经改名为 ChatGPT，旧镜像管道在 26.623 后停止同步 Windows 新包。
