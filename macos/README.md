# macOS 版 EK StreamDL

当前 macOS 版采用原生 SwiftUI + WKWebView 承载 Vite/React UI，专用于流媒体网站视频解析与下载，并通过 Swift 命令层调用 `yt-dlp` 处理公开视频。

## Xcode 运行

1. 先准备完整 Xcode，并在系统中选择 Xcode Developer Directory。
2. 打开 `EK StreamDL.xcodeproj`。
3. 选择 `EK StreamDL` scheme。
4. 点击 Run。

App 启动后会加载本目录 `dist/` 中的当前 UI。Xcode 工程会优先直接使用已有 `dist/index.html`，避免 Xcode 的非交互脚本环境触发 `pnpm` 的安装确认。

如果前端 UI 有改动，请先在命令行执行：

```sh
pnpm run build:web
```

然后再回到 Xcode Run。

## 运行组件

真实解析与下载需要以下运行组件：

- `yt-dlp`：必需，用于解析元数据和下载。
- `ffmpeg`：必需，用于合并音视频、处理 m3u8 或后处理。

普通用户可在 App 内点击“⚠️配置所需环境”，检查并按需安装应用专用组件。安装位置为当前用户的 `Application Support/EK StreamDL/Tools`，不需要管理员权限，也不要求预先安装 Homebrew。

开发者也可以通过 Homebrew 自行安装：

```sh
brew install yt-dlp ffmpeg
```

如果工具不在常见路径，可以分别设置 `EK_STREAMDL_YTDLP_PATH` 和 `EK_STREAMDL_FFMPEG_PATH` 指向可执行文件。App 会依次复用应用内置、环境变量、应用专用目录以及 Homebrew 常见路径中的可用组件。

## 打包说明

环境配置功能解决运行组件缺失问题。正式对外分发时仍需完成 Release 构建、Developer ID 签名、公证以及第三方组件许可说明。
