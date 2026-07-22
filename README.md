# EK StreamDL

EK StreamDL 是独立的流媒体网站视频下载工具，按平台分别维护工程：

- `macos/`：macOS 原生工程，当前优先开发与发布。
- `win/`：Windows 工程预留目录，待 macOS 版完成后再进行适配迁移。

## Release 附件命名

更新系统依赖以下精确文件名。大小写、空格或点号、连字符、平台/架构标识、软件名及版本号顺序均不可改变：

- macOS arm64：`macOS-arm64-EK.StreamDL-<版本号>.zip`
- Windows x64：`windows-x64-EK StreamDL-<版本号>.zip`

既有 `macOS-universal-...` 附件仅由更新器继续兼容识别，不再用于完成命名过渡后的 macOS arm64 新版本。首次携带 arm64 资产名适配的过渡版本，仍须提供旧版更新器可识别的、二进制内容确为 Universal 的标准 `macOS-universal-EK StreamDL-<版本号>.zip`；后续版本再只发布新的 arm64 标准名称。

示例：

- `macOS-arm64-EK.StreamDL-0.9.0.zip`
- `windows-x64-EK StreamDL-0.2.0.zip`
