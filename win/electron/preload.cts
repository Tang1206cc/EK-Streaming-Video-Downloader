import { contextBridge, ipcRenderer } from "electron";
import type {
  DownloadMode,
  DownloadProgressEvent,
  RuntimeEnvironmentProgressEvent,
  RuntimeEnvironmentReport,
  VideoMetadata,
} from "./bridgeTypes.js";
import type { AppLanguage, AppSettings } from "./services/settings.js";

const bootstrap = ipcRenderer.sendSync("settings:bootstrap") as AppSettings;
let currentThemeMode = bootstrap.themeMode;

function applyTheme(mode: AppSettings["themeMode"]) {
  currentThemeMode = mode;
  const dark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  const resolved = mode === "system" ? (dark ? "dark" : "light") : mode;
  document.documentElement.dataset.ekStreamdlTheme = mode;
  document.documentElement.dataset.ekStreamdlResolvedTheme = resolved;
  document.documentElement.style.colorScheme = resolved;
}

function applyLanguage(language: AppLanguage) {
  document.documentElement.lang = language;
  window.dispatchEvent(new CustomEvent("ek-streamdl-language-change", { detail: language }));
}

contextBridge.exposeInMainWorld("__ekStreamDLLanguage", bootstrap.language);
contextBridge.exposeInMainWorld("ekStreamDLDesktop", {
  platform: "win32",
  nativeBridge: {
    openPreferences: () => ipcRenderer.invoke("bridge:open-preferences"),
    openToolWindow: (toolId: string) => ipcRenderer.invoke("bridge:open-tool-window", toolId),
    parseVideo: (inputText: string) => ipcRenderer.invoke("bridge:parse-video", inputText),
    selectDownloadDirectory: () => ipcRenderer.invoke("bridge:select-download-directory"),
    downloadVideo: (
      metadata: VideoMetadata,
      downloadDirectoryPath: string | undefined,
      downloadMode: DownloadMode,
      onProgress: (event: DownloadProgressEvent) => void,
      taskIdentifier: string,
    ) => {
      const channel = `bridge:download-progress:${taskIdentifier}`;
      const listener = (_event: Electron.IpcRendererEvent, value: DownloadProgressEvent) => onProgress(value);
      ipcRenderer.on(channel, listener);
      return ipcRenderer.invoke("bridge:download-video", { metadata, downloadDirectoryPath, downloadMode, taskIdentifier })
        .finally(() => ipcRenderer.removeListener(channel, listener));
    },
    cancelDownload: (taskIdentifier: string, deletePartialFiles: boolean) => ipcRenderer.invoke("bridge:cancel-download", { taskIdentifier, deletePartialFiles }),
    pauseDownload: (taskIdentifier: string) => ipcRenderer.invoke("bridge:pause-download", taskIdentifier),
    resumeDownload: (taskIdentifier: string) => ipcRenderer.invoke("bridge:resume-download", taskIdentifier),
    downloadCover: (metadata: VideoMetadata, downloadDirectoryPath?: string) => ipcRenderer.invoke("bridge:download-cover", { metadata, downloadDirectoryPath }),
    playCompletionSound: () => ipcRenderer.invoke("bridge:play-completion-sound"),
    checkRuntimeEnvironment: () => ipcRenderer.invoke("bridge:check-runtime-environment"),
    installRuntimeEnvironment: (onProgress: (event: RuntimeEnvironmentProgressEvent) => void) => {
      const requestId = `${Date.now()}-${Math.random()}`;
      const channel = `bridge:environment-progress:${requestId}`;
      const listener = (_event: Electron.IpcRendererEvent, value: RuntimeEnvironmentProgressEvent) => onProgress(value);
      ipcRenderer.on(channel, listener);
      return ipcRenderer.invoke("bridge:install-runtime-environment", requestId)
        .finally(() => ipcRenderer.removeListener(channel, listener)) as Promise<RuntimeEnvironmentReport>;
    },
    getWeChatAuthorizationStatus: () => ipcRenderer.invoke("bridge:wechat-status"),
    clearWeChatAuthorization: () => ipcRenderer.invoke("bridge:wechat-clear"),
    exportDiagnosticReport: (report?: RuntimeEnvironmentReport) => ipcRenderer.invoke("bridge:export-diagnostics", report),
  },
});

contextBridge.exposeInMainWorld("ekSettings", {
  version: ipcRenderer.sendSync("app:version"),
  get: () => ipcRenderer.invoke("settings:get"),
  save: (settings: AppSettings) => ipcRenderer.invoke("settings:save", settings),
  reset: (language: AppLanguage) => ipcRenderer.invoke("settings:reset", language),
  checkUpdate: (language: AppLanguage) => ipcRenderer.invoke("settings:check-update", language),
});

ipcRenderer.on("settings:changed", (_event, settings: AppSettings) => {
  applyTheme(settings.themeMode);
  applyLanguage(settings.language);
});

window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", () => applyTheme(currentThemeMode));
applyTheme(bootstrap.themeMode);
