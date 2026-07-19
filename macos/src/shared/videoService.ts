import { macosAdapters } from "../platforms/macos/adapters";
import type {
  DownloadMode,
  DownloadProgressEvent,
  RuntimeEnvironmentProgressEvent,
  RuntimeEnvironmentReport,
  ToolWindowId,
  VideoMetadata,
} from "./types";
import { getNativeBridge } from "./nativeBridge";
import { detectPlatform, extractUrlFromText, normalizeUrl } from "./url";

export async function openPreferences(): Promise<void> {
  const nativeBridge = getNativeBridge();
  if (!nativeBridge) {
    throw new Error("偏好设置仅可在 EK StreamDL macOS 应用中打开");
  }
  await nativeBridge.openPreferences();
}

export async function openToolWindow(toolId: ToolWindowId): Promise<void> {
  const nativeBridge = getNativeBridge();
  if (nativeBridge) {
    await nativeBridge.openToolWindow(toolId);
    return;
  }

  const toolUrl = new URL(window.location.href);
  toolUrl.hash = toolId;
  const openedWindow = window.open(toolUrl.toString(), "_blank", "popup,width=1120,height=760");
  if (!openedWindow) {
    throw new Error("无法打开功能窗口");
  }
}

export async function parseVideo(inputText: string): Promise<VideoMetadata> {
  if (!inputText.trim()) {
    throw new Error("请输入链接");
  }

  const extractedUrl = extractUrlFromText(inputText);

  if (!extractedUrl) {
    throw new Error("未识别到链接");
  }

  let normalizedUrl: string;
  try {
    normalizedUrl = normalizeUrl(extractedUrl);
  } catch {
    throw new Error("链接格式不正确");
  }

  const platform = detectPlatform(normalizedUrl);
  if (!platform) {
    throw new Error("暂不支持的平台");
  }

  const nativeBridge = getNativeBridge();
  if (nativeBridge) {
    return nativeBridge.parseVideo(inputText);
  }

  const adapter = macosAdapters.find((candidate) => candidate.match(normalizedUrl));
  if (!adapter) {
    throw new Error("解析失败");
  }

  return adapter.parse(normalizedUrl);
}

export async function downloadVideo(
  metadata: VideoMetadata,
  downloadMode: DownloadMode,
  onProgress: (event: DownloadProgressEvent) => void,
  downloadDirectoryPath?: string,
  taskIdentifier?: string,
): Promise<{ savedPath?: string }> {
  const nativeBridge = getNativeBridge();
  if (nativeBridge) {
    return nativeBridge.downloadVideo(
      metadata,
      downloadDirectoryPath,
      downloadMode,
      onProgress,
      taskIdentifier ?? metadata.id,
    );
  }

  const adapter = macosAdapters.find((candidate) => candidate.match(metadata.normalizedUrl));

  if (!adapter) {
    throw new Error("下载失败");
  }

  await adapter.download(metadata, onProgress);
  return {};
}

export async function cancelDownload(taskIdentifier: string, deletePartialFiles = true): Promise<void> {
  const nativeBridge = getNativeBridge();
  if (!nativeBridge) {
    return;
  }

  await nativeBridge.cancelDownload(taskIdentifier, deletePartialFiles);
}

export async function pauseDownload(taskIdentifier: string): Promise<void> {
  const nativeBridge = getNativeBridge();
  if (!nativeBridge) {
    throw new Error("当前运行环境不支持暂停下载");
  }
  const result = await nativeBridge.pauseDownload(taskIdentifier);
  if (!result.paused) {
    throw new Error("下载任务已结束或暂时无法暂停");
  }
}

export async function resumeDownload(taskIdentifier: string): Promise<void> {
  const nativeBridge = getNativeBridge();
  if (!nativeBridge) {
    throw new Error("当前运行环境不支持继续下载");
  }
  const result = await nativeBridge.resumeDownload(taskIdentifier);
  if (!result.resumed) {
    throw new Error("下载任务已结束或暂时无法继续");
  }
}

export async function downloadCover(
  metadata: VideoMetadata,
  downloadDirectoryPath?: string,
): Promise<{ savedPath?: string }> {
  const nativeBridge = getNativeBridge();
  if (nativeBridge) {
    return nativeBridge.downloadCover(metadata, downloadDirectoryPath);
  }

  throw new Error("当前运行环境不支持下载封面");
}

export async function playCompletionSound(): Promise<void> {
  const nativeBridge = getNativeBridge();
  if (!nativeBridge) {
    return;
  }

  await nativeBridge.playCompletionSound();
}

export async function checkRuntimeEnvironment(): Promise<RuntimeEnvironmentReport> {
  const nativeBridge = getNativeBridge();
  if (!nativeBridge) {
    throw new Error("当前运行环境不支持设备环境检查");
  }
  return nativeBridge.checkRuntimeEnvironment();
}

export async function installRuntimeEnvironment(
  onProgress: (event: RuntimeEnvironmentProgressEvent) => void,
): Promise<RuntimeEnvironmentReport> {
  const nativeBridge = getNativeBridge();
  if (!nativeBridge) {
    throw new Error("当前运行环境不支持自动配置");
  }
  return nativeBridge.installRuntimeEnvironment(onProgress);
}

export async function clearWeChatAuthorization(): Promise<void> {
  const nativeBridge = getNativeBridge();
  if (!nativeBridge) {
    throw new Error("当前运行环境不支持清理微信授权");
  }
  await nativeBridge.clearWeChatAuthorization();
}

export async function getWeChatAuthorizationStatus(): Promise<boolean> {
  const nativeBridge = getNativeBridge();
  if (!nativeBridge) {
    return false;
  }
  const result = await nativeBridge.getWeChatAuthorizationStatus();
  return result.authorized;
}

export async function exportDiagnosticReport(
  report?: RuntimeEnvironmentReport,
): Promise<{ savedPath?: string }> {
  const nativeBridge = getNativeBridge();
  if (!nativeBridge) {
    throw new Error("当前运行环境不支持导出诊断报告");
  }
  return nativeBridge.exportDiagnosticReport(report);
}

export async function selectDownloadDirectory(): Promise<string | null> {
  const nativeBridge = getNativeBridge();
  if (!nativeBridge) {
    throw new Error("当前运行环境不支持选择本地下载目录");
  }

  const result = await nativeBridge.selectDownloadDirectory();
  return result.directoryPath?.trim() || null;
}
