import { app, BrowserWindow, dialog, ipcMain, Menu, nativeTheme, session, shell } from "electron";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { diagnosticText, appendDiagnostic } from "./services/diagnostics.js";
import {
  cancelDownload,
  downloadCover,
  downloadVideo,
  parseVideo,
  pauseDownload,
  resumeDownload,
} from "./services/videoService.js";
import { checkRuntimeEnvironment, installRuntimeEnvironment } from "./services/runtimeEnvironment.js";
import { weChatAuthorization } from "./services/wechatAuthorization.js";
import { checkForUpdates } from "./services/updater.js";
import { readSettings, type AppSettings } from "./services/settings.js";
import { registerSettingsHandlers, showSettingsWindow } from "./settingsWindow.js";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const preloadPath = path.join(__dirname, "preload.cjs");
const isDev = Boolean(process.env.VITE_DEV_SERVER_URL);
let mainWindow: BrowserWindow | null = null;

const isVersionQuery = process.argv.includes("--version-json");
if (isVersionQuery) {
  process.stdout.write(`${JSON.stringify({
    appId: "com.tang1206cc.ekstreamdl",
    productName: "EK StreamDL",
    version: app.getVersion(),
    platform: "win32",
    arch: process.arch,
  })}\n`, () => app.exit(0));
}

function broadcastSettings(settings: AppSettings) {
  nativeTheme.themeSource = settings.themeMode;
  for (const window of BrowserWindow.getAllWindows()) {
    window.webContents.send("settings:changed", settings);
  }
}

function createMainWindow() {
  if (mainWindow && !mainWindow.isDestroyed()) return mainWindow;
  const window = new BrowserWindow({
    width: 1120,
    height: 760,
    minWidth: 920,
    minHeight: 700,
    show: false,
    title: "EK StreamDL",
    backgroundColor: "#f5f7fb",
    autoHideMenuBar: true,
    titleBarStyle: "hidden",
    titleBarOverlay: { color: "#f5f7fb", symbolColor: "#31415f", height: 32 },
    icon: path.join(__dirname, "../dist/app-icon.png"),
    webPreferences: {
      preload: preloadPath,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  window.webContents.setWindowOpenHandler(({ url }) => {
    if (/^https?:\/\//i.test(url)) void shell.openExternal(url);
    return { action: "deny" };
  });
  window.webContents.on("will-navigate", (event, url) => {
    const current = window.webContents.getURL();
    if (url !== current && /^https?:\/\//i.test(url)) {
      event.preventDefault();
      void shell.openExternal(url);
    }
  });
  window.webContents.on("before-input-event", (event, input) => {
    if (input.type === "keyDown" && input.key === "Escape" && readSettings().escToQuit) {
      event.preventDefault();
      app.quit();
    }
  });
  window.once("ready-to-show", () => window.show());
  window.on("closed", () => { mainWindow = null; });
  if (isDev) void window.loadURL(process.env.VITE_DEV_SERVER_URL as string);
  else void window.loadFile(path.join(__dirname, "../dist/index.html"));
  mainWindow = window;
  return window;
}

function registerBridgeHandlers() {
  ipcMain.on("settings:bootstrap", (event) => { event.returnValue = readSettings(); });
  ipcMain.on("app:version", (event) => { event.returnValue = app.getVersion(); });
  ipcMain.handle("bridge:open-preferences", () => {
    showSettingsWindow(preloadPath);
    return { opened: true };
  });
  ipcMain.handle("bridge:open-tool-window", () => {
    const window = createMainWindow();
    window.show();
    window.focus();
    return { opened: true };
  });
  ipcMain.handle("bridge:parse-video", (_event, inputText: string) => parseVideo(inputText));
  ipcMain.handle("bridge:select-download-directory", async () => {
    const options: Electron.OpenDialogOptions = {
      title: "选择视频下载保存目录",
      properties: ["openDirectory", "createDirectory"],
      defaultPath: app.getPath("downloads"),
      buttonLabel: "选择",
    };
    const result = mainWindow
      ? await dialog.showOpenDialog(mainWindow, options)
      : await dialog.showOpenDialog(options);
    return { directoryPath: result.canceled ? "" : result.filePaths[0] ?? "" };
  });
  ipcMain.handle("bridge:download-video", async (event, payload: {
    metadata: Parameters<typeof downloadVideo>[0];
    downloadDirectoryPath?: string;
    downloadMode: Parameters<typeof downloadVideo>[2];
    taskIdentifier: string;
  }) => downloadVideo(
    payload.metadata,
    payload.downloadDirectoryPath,
    payload.downloadMode,
    payload.taskIdentifier,
    (progress) => event.sender.send(`bridge:download-progress:${payload.taskIdentifier}`, progress),
  ));
  ipcMain.handle("bridge:cancel-download", async (_event, payload: { taskIdentifier: string; deletePartialFiles: boolean }) => ({
    cancelled: await cancelDownload(payload.taskIdentifier, payload.deletePartialFiles),
  }));
  ipcMain.handle("bridge:pause-download", async (_event, taskIdentifier: string) => ({ paused: await pauseDownload(taskIdentifier) }));
  ipcMain.handle("bridge:resume-download", async (_event, taskIdentifier: string) => ({ resumed: await resumeDownload(taskIdentifier) }));
  ipcMain.handle("bridge:download-cover", (_event, payload: { metadata: Parameters<typeof downloadCover>[0]; downloadDirectoryPath?: string }) => downloadCover(payload.metadata, payload.downloadDirectoryPath));
  ipcMain.handle("bridge:play-completion-sound", () => {
    shell.beep();
    return { played: true };
  });
  ipcMain.handle("bridge:check-runtime-environment", () => checkRuntimeEnvironment());
  ipcMain.handle("bridge:install-runtime-environment", (event, requestId: string) => installRuntimeEnvironment((progress) => {
    event.sender.send(`bridge:environment-progress:${requestId}`, progress);
  }));
  ipcMain.handle("bridge:wechat-status", async () => ({ authorized: await weChatAuthorization.status() }));
  ipcMain.handle("bridge:wechat-clear", async () => {
    await weChatAuthorization.clearAuthorization();
    return { cleared: true };
  });
  ipcMain.handle("bridge:export-diagnostics", async (_event, report: unknown) => {
    const options: Electron.SaveDialogOptions = {
      title: "导出运行环境与最近操作诊断信息",
      defaultPath: path.join(app.getPath("downloads"), "EK StreamDL诊断报告.txt"),
      filters: [{ name: "Text", extensions: ["txt"] }],
      buttonLabel: "导出",
    };
    const result = mainWindow
      ? await dialog.showSaveDialog(mainWindow, options)
      : await dialog.showSaveDialog(options);
    if (result.canceled || !result.filePath) return { savedPath: "" };
    const content = [
      "EK StreamDL诊断报告",
      `生成时间：${new Date().toISOString()}`,
      `应用版本：${app.getVersion()}`,
      `系统：${process.platform} ${process.getSystemVersion()}`,
      `处理器：${process.arch}`,
      "",
      "--- 环境检查 ---",
      report ? JSON.stringify(report, null, 2) : "未提供环境检查结果",
      "",
      "--- 最近诊断记录 ---",
      diagnosticText() || "暂无记录",
    ].join("\n");
    fs.writeFileSync(result.filePath, content, "utf8");
    appendDiagnostic("诊断", `诊断报告已导出：${result.filePath}`);
    return { savedPath: result.filePath };
  });
}

function installMenu() {
  const settings = readSettings();
  const isEnglish = settings.language === "en";
  Menu.setApplicationMenu(Menu.buildFromTemplate([
    {
      label: isEnglish ? "File" : "文件",
      submenu: [
        { label: isEnglish ? "Preferences…" : "偏好设置…", accelerator: "Ctrl+,", click: () => showSettingsWindow(preloadPath) },
        { type: "separator" },
        { label: isEnglish ? "Exit" : "退出", accelerator: "Alt+F4", click: () => app.quit() },
      ],
    },
    {
      label: isEnglish ? "Help" : "帮助",
      submenu: [
        { label: isEnglish ? "Check for Updates" : "检查更新", click: () => void checkForUpdates(true, readSettings().language) },
        { label: "GitHub", click: () => void shell.openExternal("https://github.com/Tang1206cc/EK-Streaming-Video-Downloader") },
      ],
    },
  ]));
}

async function applySystemProxyToCommandLineTools() {
  if (process.env.HTTPS_PROXY || process.env.https_proxy) return;
  try {
    const proxyRules = await session.defaultSession.resolveProxy("https://www.bilibili.com/");
    const candidate = proxyRules
      .split(";")
      .map((rule) => rule.trim())
      .find((rule) => /^(PROXY|HTTPS|SOCKS5?)\s+/i.test(rule));
    if (!candidate) return;
    const match = candidate.match(/^(PROXY|HTTPS|SOCKS5?)\s+(.+)$/i);
    if (!match) return;
    const scheme = /^SOCKS/i.test(match[1]) ? "socks5" : "http";
    const proxyURL = `${scheme}://${match[2]}`;
    process.env.HTTPS_PROXY = proxyURL;
    process.env.HTTP_PROXY = proxyURL;
    process.env.https_proxy = proxyURL;
    process.env.http_proxy = proxyURL;
    appendDiagnostic("网络", `已将 Windows 系统代理同步给命令行运行组件：${match[1].toUpperCase()}`);
  } catch (error) {
    appendDiagnostic("网络", `读取 Windows 系统代理失败：${error instanceof Error ? error.message : "未知错误"}`);
  }
}

if (!isVersionQuery) {
  const hasLock = app.requestSingleInstanceLock();
  if (!hasLock) {
    app.quit();
  } else {
    app.on("second-instance", () => {
      const window = createMainWindow();
      if (window.isMinimized()) window.restore();
      window.show();
      window.focus();
    });
    app.whenReady().then(async () => {
      app.setAppUserModelId("com.tang1206cc.ekstreamdl");
      const initialSettings = readSettings();
      nativeTheme.themeSource = initialSettings.themeMode;
      app.setLoginItemSettings({ openAtLogin: initialSettings.launchAtLogin, path: process.execPath });
      await applySystemProxyToCommandLineTools();
      registerBridgeHandlers();
      registerSettingsHandlers((next) => {
        broadcastSettings(next);
        installMenu();
      });
      installMenu();
      createMainWindow();
      if (initialSettings.autoCheckForUpdates) {
        setTimeout(() => void checkForUpdates(false, readSettings().language), 2_000);
      }
    });
  }

  app.on("activate", () => createMainWindow());
  app.on("window-all-closed", () => {
    if (readSettings().quitWhenLastWindowClosed) app.quit();
  });
}
