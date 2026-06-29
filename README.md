# Codex Desktop Mirror Plus

一个面向 Windows 的 **Codex 桌面版安装包镜像 + 安全更新脚本** 项目。

这个项目的目标很简单：让无法通过 Microsoft Store 正常下载/更新 Codex Desktop 的用户，也能从 GitHub Releases 下载完整 Windows 安装包，并用脚本安全更新自己的本地 Codex。

> 非官方项目。此项目不隶属于 OpenAI 或 Microsoft。镜像安装包前请自行确认相关条款、许可证和合规要求。本项目不会破解、修改或重打包官方安装器。

## 普通用户怎么用

如果你只是想更新本机的 Codex 桌面版，下载这两个文件，放在同一个文件夹里：

- [run-update-codex-desktop.cmd](https://raw.githubusercontent.com/NNNaughtyDog/codex-desktop-mirror-plus/main/client/run-update-codex-desktop.cmd)
- [update-codex-desktop.ps1](https://raw.githubusercontent.com/NNNaughtyDog/codex-desktop-mirror-plus/main/client/update-codex-desktop.ps1)

然后：

1. 关闭所有 Codex 窗口。
2. 双击 `run-update-codex-desktop.cmd`。
3. 如果脚本找不到 Codex，会提示你输入安装目录的绝对路径，例如：

```text
D:\software\Codex
```

4. 如果默认镜像仓库失效，会提示你输入新的 GitHub 镜像仓库，例如：

```text
owner/repo
https://github.com/owner/repo
```

脚本默认更新位置是：

```text
D:\software\Codex
```

如果你的 Codex 不在这里，脚本会主动询问，不会瞎删目录。

## 脚本会保护什么

用户端更新脚本会做这些检查：

- 自动识别 x64 / ARM64。
- 自动读取 GitHub Release 最新 Windows MSIX。
- 下载后做 SHA256 校验。
- 解包后确认包名是 `OpenAI.Codex`。
- 覆盖前临时备份旧安装目录。
- 成功验证后删除临时文件和备份，不留几 GB 垃圾。
- 失败时尝试回滚旧版本。
- 保留安装目录里不属于官方 MSIX 包的自定义文件，例如你自己放的 `.bat`。
- 不碰用户历史、聊天、配置和工作目录。

不会主动删除这些位置：

```text
%APPDATA%
%LOCALAPPDATA%
%USERPROFILE%\.codex
Documents\Codex
```

## 镜像维护者怎么用

这个仓库不仅有用户更新脚本，也包含镜像维护脚本。

目录结构：

```text
.github/workflows/sync-windows.yml       GitHub Actions 自动同步 Windows 安装包
scripts/Sync-CodexWindowsMirror.ps1      下载、解包检查、生成 SHA256 和 manifest
scripts/Publish-GitHubRelease.ps1        发布 GitHub Release
scripts/Deploy-ToGitHub.ps1              一键创建/推送项目到 GitHub
client/update-codex-desktop.ps1          普通用户更新脚本
client/run-update-codex-desktop.cmd      普通用户双击启动器
docs/operations.md                       运维说明
```

### 自动镜像

GitHub Actions 会定时运行：

```text
Sync Windows Codex Desktop Mirror
```

它会尝试从 Microsoft Store 源下载 Codex Windows MSIX，并发布类似这样的 Release：

```text
codex-windows-26.623.5546.0
```

Release 里应该包含：

```text
OpenAI.Codex_..._x64__....Msix
OpenAI.Codex_..._arm64__....Msix
SHA256SUMS-windows.txt
release-manifest.json
```

### 手动镜像

在 Windows 上运行：

```powershell
.\scripts\Sync-CodexWindowsMirror.ps1 -OutDir .\dist
.\scripts\Publish-GitHubRelease.ps1 -DistDir .\dist -Repo "NNNaughtyDog/codex-desktop-mirror-plus"
```

如果 GitHub Actions 上的 `winget download` 被限制，可以在自己的 Windows 电脑上手动运行上面的命令。

## 下载地址在哪里

当前有两类下载：

### 1. 用户更新脚本

直接下载：

- [run-update-codex-desktop.cmd](https://raw.githubusercontent.com/NNNaughtyDog/codex-desktop-mirror-plus/main/client/run-update-codex-desktop.cmd)
- [update-codex-desktop.ps1](https://raw.githubusercontent.com/NNNaughtyDog/codex-desktop-mirror-plus/main/client/update-codex-desktop.ps1)

### 2. Codex Windows 完整安装包

完整安装包会出现在本仓库的 Releases：

- [Releases 页面](https://github.com/NNNaughtyDog/codex-desktop-mirror-plus/releases)

如果 Releases 里暂时还没有 `codex-windows-...`，说明自动同步还没有成功跑完。可以到 Actions 页面手动运行同步：

- [Actions 页面](https://github.com/NNNaughtyDog/codex-desktop-mirror-plus/actions)

## 安全说明

- 不建议从来历不明的仓库下载 MSIX。
- 下载后优先核对 `SHA256SUMS-windows.txt`。
- 本项目脚本会自动核验 SHA256，不匹配会拒绝安装。
- 不要在聊天工具、issue、commit 里粘贴 GitHub 密码或 token。

## 一键部署同类项目

如果你 fork 或复制这个项目，可以用：

```powershell
.\scripts\Deploy-ToGitHub.ps1 -RepoName "codex-desktop-mirror-plus" -Visibility public
```

它会使用 GitHub CLI/本机登录状态完成部署。
