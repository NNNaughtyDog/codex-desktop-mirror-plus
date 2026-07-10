# ChatGPT / Codex Desktop Mirror Plus

这个项目镜像 Windows 版 ChatGPT Desktop 中的 Codex 桌面包，给无法直接使用 Microsoft Store 的用户提供完整 MSIX 安装包、临时 Microsoft Store CDN 直链和本地更新脚本。

2026-07 起，上游把 Codex Desktop 合并进 ChatGPT 品牌：

- Microsoft Store 页面名称是 `ChatGPT`
- Windows 包身份仍是 `OpenAI.Codex`
- 新版入口可执行文件通常是 `app\ChatGPT.exe`
- 旧版入口可执行文件是 `app\Codex.exe`

本项目以包身份 `OpenAI.Codex` 为准，不再依赖旧的 `Wangnov/codex-app-mirror` fallback。

> 非官方项目。本项目不隶属于 OpenAI 或 Microsoft，不破解、不修改、不重打包安装器，只镜像官方 Microsoft CDN 下发的 MSIX 文件并发布校验信息。

## 为什么 Releases 没有立刻更新

代码推送到 GitHub 不等于 Release 已经生成。Release 需要 GitHub Actions 跑完同步流程后才会出现。

现在工作流会在这些情况下运行：

- 推送到 `main` 后自动完整同步一次。
- 每 3 小时自动刷新一次最新版本的临时直链。
- 在 Actions 页面手动运行 `Sync ChatGPT Codex Windows Mirror`。

定时刷新会先解析 Microsoft Store 最新包。如果同版本 Release 已存在，就只刷新 Release notes、`LATEST_TEMP_LINKS.md` 和 `store-temp-links.json` 里的临时直链，避免每 3 小时重复下载和上传 1GB 以上的 MSIX。发现新版本且 Release 还不存在时，会下载完整 x64/arm64 MSIX 并发布。

## 下载哪个文件

打开 [Releases](https://github.com/NNNaughtyDog/codex-desktop-mirror-plus/releases)，优先下载与你机器架构匹配的 GitHub Release 资产：

```text
OpenAI.Codex_<version>_x64__2p2nqsd0c76g0.msix
OpenAI.Codex_<version>_arm64__2p2nqsd0c76g0.msix
SHA256SUMS-windows.txt
```

如果 GitHub 资产还没上传，或者下载 GitHub 资产很慢，可以看同一个 Release 页面里的 `Temporary Direct Download Links`，也可以下载资产 `LATEST_TEMP_LINKS.md` 或 `store-temp-links.json`。这些直链来自 Microsoft Store CDN，可能会过期；过期后等下一次 3 小时刷新，或手动运行 workflow。

大多数 Intel/AMD Windows 电脑用 `x64`。Windows on ARM 设备用 `arm64`。

## 推荐更新方式

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
- 等你关闭正在运行的 app，不强杀进程。
- 更新前备份旧安装目录，失败时尝试回滚。
- 默认更新成功后启动新版应用。

指定其他镜像仓库：

```powershell
.\client\update-codex-desktop.ps1 -Repo "owner/repo"
```

## 手动覆盖更新

手动覆盖只替换程序目录，不要删除你的用户数据目录。聊天、项目和本地配置通常不在 `D:\software\Codex` 程序目录里，而是在你的账号、AppData 或工作区目录中。

不要删除这些目录：

```text
%LOCALAPPDATA%\Packages\OpenAI.Codex_2p2nqsd0c76g0
%APPDATA%\OpenAI
%USERPROFILE%\.codex
你的项目工作区目录
```

如果你当前是解包安装在 `D:\software\Codex`，可以这样手动覆盖：

```powershell
$msix = "C:\Users\你的用户名\Downloads\OpenAI.Codex_26.707.3748.0_x64__2p2nqsd0c76g0.msix"
$install = "D:\software\Codex"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$parent = Split-Path -Parent $install
$backup = Join-Path $parent "Codex-backup-$stamp"
$stage = Join-Path $parent "Codex-new-$stamp"

$running = Get-Process -Name "ChatGPT","Codex","codex" -ErrorAction SilentlyContinue
if ($running) {
  throw "请先正常关闭所有 ChatGPT / Codex 窗口，再重新执行。"
}

New-Item -ItemType Directory -Force -Path $stage | Out-Null
tar.exe -xf $msix -C $stage

Rename-Item -LiteralPath $install -NewName (Split-Path -Leaf $backup)
Rename-Item -LiteralPath $stage -NewName (Split-Path -Leaf $install)

$exe = Join-Path $install "app\ChatGPT.exe"
if (-not (Test-Path -LiteralPath $exe)) {
  $exe = Join-Path $install "app\Codex.exe"
}
Start-Process -FilePath $exe -WorkingDirectory (Split-Path -Parent $exe)
```

确认新版正常后，可以保留备份几天。确认没问题再删除类似下面的备份目录：

```text
D:\software\Codex-backup-20260710-120000
```

如果更新后打不开，把当前 `D:\software\Codex` 改名为临时目录，再把备份目录改回 `D:\software\Codex` 即可回滚。

## 校验下载文件

GitHub Release 资产使用 SHA256：

```powershell
Get-FileHash .\OpenAI.Codex_26.707.3748.0_x64__2p2nqsd0c76g0.msix -Algorithm SHA256
```

和 release 里的 `SHA256SUMS-windows.txt` 对比。

临时 Microsoft Store CDN 直链使用 Store 返回的 SHA1：

```powershell
Get-FileHash .\OpenAI.Codex_26.707.3748.0_x64__2p2nqsd0c76g0.msix -Algorithm SHA1
```

和 Release 页面 `Temporary Direct Download Links` 里的 SHA1 对比。

## 维护者怎么同步完整包

手动生成 release 资产：

```powershell
.\scripts\Sync-CodexWindowsMirror.ps1 -OutDir .\dist
.\scripts\Publish-GitHubRelease.ps1 -DistDir .\dist -Repo "NNNaughtyDog/codex-desktop-mirror-plus"
```

只刷新临时直链，不下载 MSIX：

```powershell
.\scripts\Sync-CodexWindowsMirror.ps1 -OutDir .\dist -LinksOnly
.\scripts\Publish-GitHubRelease.ps1 -DistDir .\dist -Repo "NNNaughtyDog/codex-desktop-mirror-plus"
```

同步脚本会查询 Microsoft Store 产品 `9PLM9XGG6VKS` 的文件清单：

```text
OpenAI.Codex_<version>_x64__2p2nqsd0c76g0.msix
OpenAI.Codex_<version>_arm64__2p2nqsd0c76g0.msix
```

并生成：

```text
SHA256SUMS-windows.txt
release-manifest.json
LATEST_TEMP_LINKS.md
store-temp-links.json
RELEASE_NOTES.md
release-metadata.json
```

Release tag 形如：

```text
chatgpt-codex-windows-26.707.3748.0
```

## GitHub Actions 权限

工作流需要仓库开启 release 写权限：

```text
Settings -> Actions -> General -> Workflow permissions -> Read and write permissions
```

工作流名称：

```text
Sync ChatGPT Codex Windows Mirror
```

## 已废弃的旧方案

这些路径已经不再作为默认方案：

- `winget download`
- `Wangnov/codex-app-mirror` fallback
- `https://codexapp-r2.agentsmirror.com/latest/win-x64`
- 固定假设入口是 `app\Codex.exe`

原因是上游已经改名为 ChatGPT，旧镜像管道在 26.623 后停止同步 Windows 新包。
