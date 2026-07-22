# EK StreamDL for Windows x64

本目录是 EK StreamDL 的 Windows 原生桌面工程。它以 macOS 正式版为功能与视觉基准，复用同一套 React/Vite 界面和状态模型，并由 Electron 主进程提供 Windows 文件系统、子进程、开机启动、运行组件配置、微信授权和应用更新能力。

Windows 版与 macOS 版保持相同的主要用户流程：粘贴分享文本或链接、解析作品信息、选择合集条目和下载模式、管理最多两个并行任务、下载封面、选择目录、配置运行环境、管理微信视频号授权、导出诊断报告及应用内更新。

## 系统与开发要求

- 运行系统：Windows 10 22H2 或更高版本，x64。
- 开发环境：Node.js 22、pnpm 10；可直接用 Visual Studio Code 或其他支持 Node.js/TypeScript 的 Windows IDE 打开本目录。
- 普通用户不需要安装 Node.js、Python、Chocolatey、Winget 或管理员级工具。
- 下载能力依赖 `yt-dlp.exe` 与 `ffmpeg.exe`。应用会优先复用通过环境变量或常见用户路径找到的现有工具，也可以在“配置所需环境”中安装应用专用副本。

应用专用工具默认位于：

```text
%LOCALAPPDATA%\EK StreamDL\Tools
```

可通过以下环境变量指定其他位置：

```text
EK_STREAMDL_YTDLP_PATH=C:\path\to\yt-dlp.exe
EK_STREAMDL_FFMPEG_PATH=C:\path\to\ffmpeg.exe
```

## 工程结构

```text
win/
├── electron/
│   ├── main.ts                       # 应用生命周期、窗口、菜单与 IPC 桥
│   ├── preload.ts                    # 隔离渲染层与主进程的安全接口
│   ├── settingsWindow.ts             # Windows 偏好设置窗口
│   └── services/
│       ├── videoService.ts           # 真实解析、下载、合集与任务控制
│       ├── runtimeEnvironment.ts      # Windows 环境检查与一键配置
│       ├── wechatAuthorization.ts    # 腾讯元宝独立授权窗口与授权状态
│       ├── updater.ts                 # GitHub Release 检查、验证、替换与重启
│       ├── processRunner.ts           # Windows 子进程、暂停、继续与终止
│       ├── settings.ts               # 用户偏好与开机启动
│       ├── paths.ts                  # Windows 路径、工具发现与安全文件名
│       └── diagnostics.ts            # 最近操作诊断记录
├── src/                               # 与 macOS 版同源的 React UI、国际化和队列状态
├── public/                            # 品牌、作者信息与应用图标
├── package.json                       # 开发、测试、构建和 Windows 打包配置
├── pnpm-lock.yaml                     # 锁定依赖版本
└── README.md
```

## 开发与验证

在 Windows PowerShell 中执行：

```powershell
cd win
pnpm install
pnpm test
pnpm run build
pnpm run dev
```

`pnpm run dev` 会同时启动 Vite 与 Electron；`pnpm run start` 会先生成生产 Web/主进程文件，再以生产资源启动桌面应用。

只生成 Windows 解包目录：

```powershell
pnpm run dist:win:dir
```

生成 Windows x64 ZIP 与 NSIS 安装程序：

```powershell
pnpm run dist:win
```

打包结果位于 `win/build-output/`。NSIS 默认按当前用户安装，不要求管理员权限，并创建开始菜单与桌面快捷方式。

## 一键运行环境配置

环境窗口检查以下项目：

1. Windows 10 22H2+ x64。
2. 系统下载目录写入权限。
3. 六个支持平台的 DNS/TLS 连通性。
4. `yt-dlp.exe` 可执行状态和最新版本。
5. `ffmpeg.exe` 可执行状态。

自动配置使用：

- [yt-dlp 官方 Windows x64 独立程序](https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe)及官方 `SHA2-256SUMS`。
- [BtbN FFmpeg Windows x64 GPL 自动构建](https://github.com/BtbN/FFmpeg-Builds/releases)及 `checksums.sha256`。

组件下载支持断点续传、最多三次重试和 SHA-256 校验。安装只写入当前用户的 EK StreamDL 数据目录，不修改系统 PATH，也不覆盖用户自行安装的工具。

## 微信视频号

微信视频号沿用 macOS 版既定链路：先使用官方预览接口读取公开信息；下载时如无有效授权，会打开独立的“微信视频号授权 · 腾讯元宝”窗口。登录状态保存在 Electron 的独立持久会话中，可从主界面清理。授权窗口不向 EK StreamDL 自有服务器提交账号信息。

## 更新器与 Release 契约

Windows 更新器只接受发布、非草稿、非预发布的 GitHub Release，并严格寻找：

```text
windows-x64-EK StreamDL-<版本号>.zip
```

大小写、连字符、`x64`、产品名中的空格、版本位置和 `.zip` 扩展名均是更新协议的一部分。`package.json` 已将 ZIP 构建产物固定为该名称。

更新流程会：

1. 比较当前应用版本与最新 Release 标签。
2. 下载名称完全匹配的 Windows x64 ZIP，并记录 SHA-256。
3. 解压后运行包内 `EK StreamDL.exe --version-json`。
4. 校验应用 ID、产品名与 Release 版本号。
5. 启动独立 PowerShell 更新辅助流程，等待当前进程退出，替换当前用户安装目录并重新启动。

发版时必须同步 `win/package.json` 的 `version` 与 `buildVersion`，并确保 Release 标签、ZIP 内应用版本和附件名中的版本完全一致。不得覆盖或删除既有 Release 附件。

## PD 虚拟机联调重点

首次进入 Windows 环境后建议按顺序检查：

1. `pnpm install`、`pnpm test`、`pnpm run build` 和 `pnpm run dist:win:dir`。
2. 主窗口尺寸、缩放、深浅主题、简中/繁中/英文及 Windows 标题栏拖动。
3. 六个平台各至少一个公开链接的解析和四种下载模式。
4. 合集选择、两个并行任务、单项/全部暂停继续、失败重试与删除。
5. 一键安装全新 `yt-dlp.exe`、`ffmpeg.exe`，再检查版本、路径和 SHA-256 失败提示。
6. 自定义下载目录、重名文件、封面、完成提示音及重启后的任务恢复。
7. 微信首次授权、授权复用、取消、清理和再次授权。
8. 开机启动、Esc 退出、关闭末尾窗口行为及恢复默认设置。
9. 使用测试 Release 验证精确 ZIP 命名、包身份校验、替换和重启。
10. NSIS 当前用户安装、桌面/开始菜单快捷方式、卸载与 ZIP 便携运行。
