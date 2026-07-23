import { app, net } from "electron";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { finished, pipeline } from "node:stream/promises";
import { createGunzip } from "node:zlib";
import extract from "extract-zip";
import type {
  RuntimeEnvironmentComponent,
  RuntimeEnvironmentProgressEvent,
  RuntimeEnvironmentReport,
} from "../bridgeTypes.js";
import { appendDiagnostic } from "./diagnostics.js";
import {
  defaultDownloadsDirectory,
  managedFfmpegPath,
  managedToolsDirectory,
  managedYtDlpPath,
  resolveFfmpegPath,
  resolveYtDlpPath,
} from "./paths.js";
import { runProcess } from "./processRunner.js";
import { checksumForFile } from "./releaseContract.js";

const YTDLP_URL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe";
const YTDLP_SUMS_URL = "https://github.com/yt-dlp/yt-dlp/releases/latest/download/SHA2-256SUMS";
const YTDLP_RELEASE_API = "https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest";
const FFMPEG_STATIC_RELEASE_API = "https://api.github.com/repos/eugeneware/ffmpeg-static/releases/latest";
const FFMPEG_STATIC_ASSET_NAME = "ffmpeg-win32-x64.gz";
const FFMPEG_STATIC_PINNED_URL = "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/ffmpeg-win32-x64.gz";
const FFMPEG_STATIC_PINNED_SHA256 = "8883a3dffbd0a16cf4ef95206ea05283f78908dbfb118f73c83f4951dcc06d77";
const FFMPEG_URL = "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip";
const FFMPEG_SUMS_URL = "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/checksums.sha256";
const FFMPEG_ARCHIVE_NAME = "ffmpeg-master-latest-win64-gpl.zip";
const DOWNLOAD_STALL_TIMEOUT_MS = 30_000;

type FfmpegDownloadAsset = {
  url: string;
  sha256: string;
  fileName: string;
  format: "gzip" | "zip";
};

const platformProbeURLs = [
  ["哔哩哔哩", "https://www.bilibili.com/"],
  ["抖音", "https://www.douyin.com/"],
  ["快手", "https://www.kuaishou.com/"],
  ["小红书", "https://www.xiaohongshu.com/"],
  ["今日头条", "https://www.toutiao.com/"],
  ["微信视频号", "https://weixin.qq.com/"],
] as const;

function userAgent() {
  return `EKStreamDL/${app.getVersion()} Windows`;
}

async function fetchText(url: string, timeoutMs = 30_000) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await net.fetch(url, {
      signal: controller.signal,
      redirect: "follow",
      headers: { "User-Agent": userAgent(), Accept: "application/json, text/plain, */*" },
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.text();
  } finally {
    clearTimeout(timeout);
  }
}

async function inspectTool(
  id: string,
  name: string,
  purpose: string,
  executable: string | null,
  args: string[],
): Promise<RuntimeEnvironmentComponent> {
  if (!executable) {
    return {
      id,
      name,
      purpose,
      required: true,
      installed: false,
      installable: true,
      detail: `未找到 ${name}，可一键安装应用专用副本`,
    };
  }
  try {
    const result = await runProcess(executable, args, { timeoutMs: 60_000 });
    if (result.exitCode !== 0) throw new Error(result.stderr);
    const version = (result.stdout || result.stderr).split(/\r?\n/).find(Boolean)?.trim();
    return {
      id,
      name,
      purpose,
      required: true,
      installed: true,
      installable: true,
      version,
      path: executable,
      detail: "运行组件检查通过",
    };
  } catch (error) {
    return {
      id,
      name,
      purpose,
      required: true,
      installed: false,
      installable: true,
      path: executable,
      detail: `组件无法运行：${error instanceof Error ? error.message : "未知错误"}`,
    };
  }
}

function inspectWindows(): RuntimeEnvironmentComponent {
  const [major = 0, , build = 0] = os.release().split(".").map(Number);
  const supported = process.platform === "win32" && (major > 10 || (major === 10 && build >= 19045));
  return {
    id: "windows",
    name: "Windows 10 22H2 或更高版本",
    purpose: "提供应用界面、网络访问与本地文件处理能力",
    required: true,
    installed: supported,
    installable: false,
    version: process.platform === "win32" ? `${os.type()} ${os.release()}` : `${os.type()} ${os.release()}（仅开发构建检查）`,
    detail: supported ? "Windows x64 系统版本符合要求" : "正式运行需要 Windows 10 22H2 或更高版本的 x64 系统",
  };
}

function inspectDownloads(): RuntimeEnvironmentComponent {
  const directory = defaultDownloadsDirectory();
  const probe = path.join(directory, `.ek-streamdl-write-test-${crypto.randomUUID()}`);
  let writable = false;
  try {
    fs.mkdirSync(directory, { recursive: true });
    fs.writeFileSync(probe, "EK StreamDL", "utf8");
    fs.unlinkSync(probe);
    writable = true;
  } catch {
    if (fs.existsSync(probe)) fs.unlinkSync(probe);
  }
  return {
    id: "downloads",
    name: "下载目录",
    purpose: "验证系统默认下载目录可写，确保文件能正常保存",
    required: true,
    installed: writable,
    installable: false,
    path: directory,
    detail: writable ? "默认下载目录写入测试通过" : "默认下载目录不可写，请检查文件权限",
  };
}

async function inspectNetwork(): Promise<RuntimeEnvironmentComponent> {
  const results = await Promise.all(
    platformProbeURLs.map(async ([name, url]) => {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 8_000);
      try {
        const response = await net.fetch(url, {
          method: "HEAD",
          redirect: "follow",
          signal: controller.signal,
          headers: { "User-Agent": userAgent() },
        });
        return [name, response.status > 0] as const;
      } catch {
        return [name, false] as const;
      } finally {
        clearTimeout(timeout);
      }
    }),
  );
  const failed = results.filter(([, ok]) => !ok).map(([name]) => name);
  return {
    id: "network",
    name: "平台网络",
    purpose: "验证所有已支持平台的 DNS 与 HTTPS 连通性",
    required: true,
    installed: failed.length === 0,
    installable: false,
    detail: failed.length === 0 ? "六个已支持平台的 DNS/TLS 连通性均正常" : `未通过：${failed.join("、")}`,
  };
}

async function latestYtDlpVersion() {
  try {
    const release = JSON.parse(await fetchText(YTDLP_RELEASE_API, 15_000)) as { tag_name?: string };
    return release.tag_name?.replace(/^v/i, "") ?? null;
  } catch {
    return null;
  }
}

export async function checkRuntimeEnvironment(): Promise<RuntimeEnvironmentReport> {
  appendDiagnostic("环境检查", "开始执行 Windows 运行环境检查");
  const [network, ytDlp, ffmpeg, latestVersion] = await Promise.all([
    inspectNetwork(),
    inspectTool("yt-dlp", "yt-dlp", "解析视频页面信息并获取可下载的视频、音频资源", resolveYtDlpPath(), ["--version"]),
    inspectTool("ffmpeg", "FFmpeg", "合并音视频、提取音频并完成下载后的媒体处理", resolveFfmpegPath(), ["-version"]),
    latestYtDlpVersion(),
  ]);
  if (ytDlp.installed && latestVersion) {
    ytDlp.latestVersion = latestVersion;
    ytDlp.updateAvailable = Boolean(ytDlp.version && ytDlp.version !== latestVersion);
    if (ytDlp.updateAvailable) ytDlp.detail += `；可更新至 ${latestVersion}`;
  }
  const components = [inspectWindows(), inspectDownloads(), network, ytDlp, ffmpeg];
  const missingComponentIds = components.filter((item) => item.required && !item.installed).map((item) => item.id);
  const recommendedComponentIds = components.filter((item) => item.updateAvailable).map((item) => item.id);
  const ready = missingComponentIds.length === 0;
  const message = !ready
    ? "检测到运行条件未满足，请根据结果处理"
    : recommendedComponentIds.length
      ? "✅当前环境可用，建议更新 yt-dlp 以保持平台兼容性"
      : "✅当前设备环境齐全，功能自检通过";
  appendDiagnostic("环境检查", message);
  return {
    ready,
    components,
    missingComponentIds,
    recommendedComponentIds,
    message,
    managedToolsDirectory: managedToolsDirectory(),
    checkedAt: new Date().toISOString(),
    diagnostics: components.map((item) => `${item.name}：${item.installed ? "通过" : "未通过"}；${item.version ?? item.detail}`),
  };
}

async function sha256(filePath: string) {
  return await new Promise<string>((resolve, reject) => {
    const hash = crypto.createHash("sha256");
    const stream = fs.createReadStream(filePath);
    stream.on("data", (chunk) => hash.update(chunk));
    stream.on("error", reject);
    stream.on("end", () => resolve(hash.digest("hex")));
  });
}

async function downloadWithResume(
  url: string,
  destination: string,
  expectedHash: string,
  onProgress: (value: number) => void,
  maxAttempts = 3,
) {
  fs.mkdirSync(path.dirname(destination), { recursive: true });
  if (fs.existsSync(destination) && await sha256(destination) === expectedHash) {
    onProgress(100);
    return;
  }
  const partial = `${destination}.part`;
  let lastError: unknown;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    const controller = new AbortController();
    let stallTimer: NodeJS.Timeout | undefined;
    let stream: fs.WriteStream | undefined;
    const resetStallTimer = () => {
      if (stallTimer) clearTimeout(stallTimer);
      stallTimer = setTimeout(() => controller.abort(), DOWNLOAD_STALL_TIMEOUT_MS);
    };
    try {
      const offset = fs.existsSync(partial) ? fs.statSync(partial).size : 0;
      resetStallTimer();
      const response = await net.fetch(url, {
        signal: controller.signal,
        redirect: "follow",
        headers: {
          "User-Agent": userAgent(),
          ...(offset > 0 ? { Range: `bytes=${offset}-` } : {}),
        },
      });
      if (!response.ok && response.status !== 206) throw new Error(`HTTP ${response.status}`);
      const append = offset > 0 && response.status === 206;
      const total = Number(response.headers.get("content-length") ?? 0) + (append ? offset : 0);
      stream = fs.createWriteStream(partial, { flags: append ? "a" : "w" });
      const activeStream = stream;
      let received = append ? offset : 0;
      if (!response.body) throw new Error("下载响应为空");
      for await (const chunk of response.body) {
        resetStallTimer();
        const buffer = Buffer.from(chunk);
        if (!activeStream.write(buffer)) {
          await new Promise<void>((resolve, reject) => {
            const onDrain = () => { cleanup(); resolve(); };
            const onError = (error: Error) => { cleanup(); reject(error); };
            const cleanup = () => {
              activeStream.removeListener("drain", onDrain);
              activeStream.removeListener("error", onError);
            };
            activeStream.once("drain", onDrain);
            activeStream.once("error", onError);
          });
        }
        received += buffer.length;
        if (total > 0) onProgress(Math.min(99, Math.round((received / total) * 100)));
      }
      activeStream.end();
      await finished(activeStream);
      stream = undefined;
      const actualHash = await sha256(partial);
      if (actualHash !== expectedHash) throw new Error("SHA-256 完整性校验失败");
      const previous = `${destination}.previous`;
      if (fs.existsSync(previous)) fs.unlinkSync(previous);
      if (fs.existsSync(destination)) fs.renameSync(destination, previous);
      fs.renameSync(partial, destination);
      if (fs.existsSync(previous)) fs.unlinkSync(previous);
      return;
    } catch (error) {
      stream?.destroy();
      stream = undefined;
      lastError = controller.signal.aborted
        ? new Error(`下载连续 ${DOWNLOAD_STALL_TIMEOUT_MS / 1_000} 秒未收到数据`)
        : error;
      if (error instanceof Error && error.message.includes("SHA-256") && fs.existsSync(partial)) {
        fs.unlinkSync(partial);
      }
      if (attempt < maxAttempts) await new Promise((resolve) => setTimeout(resolve, attempt * 1_000));
    } finally {
      if (stallTimer) clearTimeout(stallTimer);
    }
  }
  throw lastError instanceof Error ? lastError : new Error("下载失败");
}

function pinnedStaticFfmpegAsset(): FfmpegDownloadAsset {
  return {
    url: FFMPEG_STATIC_PINNED_URL,
    sha256: FFMPEG_STATIC_PINNED_SHA256,
    fileName: FFMPEG_STATIC_ASSET_NAME,
    format: "gzip",
  };
}

async function latestStaticFfmpegAsset(): Promise<FfmpegDownloadAsset> {
  try {
    const release = JSON.parse(await fetchText(FFMPEG_STATIC_RELEASE_API, 15_000)) as {
      assets?: Array<{ name?: string; browser_download_url?: string; digest?: string }>;
    };
    const asset = release.assets?.find((candidate) => candidate.name === FFMPEG_STATIC_ASSET_NAME);
    const digest = asset?.digest?.replace(/^sha256:/i, "").toLowerCase();
    if (!asset?.browser_download_url || !digest || !/^[a-f0-9]{64}$/.test(digest)) return pinnedStaticFfmpegAsset();
    return {
      url: asset.browser_download_url,
      sha256: digest,
      fileName: FFMPEG_STATIC_ASSET_NAME,
      format: "gzip",
    };
  } catch {
    return pinnedStaticFfmpegAsset();
  }
}

async function verifyExecutableWithRetry(executable: string, arguments_: string[]) {
  const retryDelays = [0, 1_000, 2_000, 4_000, 8_000, 15_000, 30_000];
  let lastError: unknown;
  for (let attempt = 0; attempt < retryDelays.length; attempt += 1) {
    if (retryDelays[attempt] > 0) {
      await new Promise((resolve) => setTimeout(resolve, retryDelays[attempt]));
    }
    try {
      const verification = await runProcess(executable, arguments_, { timeoutMs: 60_000 });
      if (verification.exitCode !== 0) throw new Error("FFmpeg 安装文件无法运行");
      return;
    } catch (error) {
      lastError = error;
      const code = (error as NodeJS.ErrnoException).code;
      const mayBeTemporarilyLocked = code === "EACCES" || code === "EPERM" || code === "EBUSY";
      if (!mayBeTemporarilyLocked || attempt === retryDelays.length - 1) throw error;
    }
  }
  throw lastError instanceof Error ? lastError : new Error("FFmpeg 安装文件无法运行");
}

async function installFfmpegAsset(asset: FfmpegDownloadAsset, onProgress: (value: number) => void, maxAttempts: number) {
  const cacheDirectory = path.join(managedToolsDirectory(), "DownloadCache");
  const archive = path.join(cacheDirectory, `${asset.sha256}-${asset.fileName}`);
  await downloadWithResume(asset.url, archive, asset.sha256, onProgress, maxAttempts);

  const stagingId = crypto.randomUUID();
  const stagedPayload = path.join(managedToolsDirectory(), `ffmpeg-${stagingId}.payload`);
  const stagedExecutable = path.join(managedToolsDirectory(), `ffmpeg-${stagingId}.exe`);
  try {
    if (asset.format === "gzip") {
      await pipeline(fs.createReadStream(archive), createGunzip(), fs.createWriteStream(stagedPayload));
    } else {
      const staging = path.join(app.getPath("temp"), `ek-streamdl-ffmpeg-${crypto.randomUUID()}`);
      fs.mkdirSync(staging, { recursive: true });
      await extract(archive, { dir: staging });
      const executable = findFile(staging, "ffmpeg.exe");
      if (!executable) throw new Error("FFmpeg 安装包中未找到 ffmpeg.exe");
      fs.copyFileSync(executable, stagedPayload);
    }

    fs.copyFileSync(stagedPayload, stagedExecutable);
    fs.unlinkSync(stagedPayload);
    await verifyExecutableWithRetry(stagedExecutable, ["-version"]);
    const destination = managedFfmpegPath();
    const previous = `${destination}.previous`;
    if (fs.existsSync(previous)) fs.unlinkSync(previous);
    if (fs.existsSync(destination)) fs.renameSync(destination, previous);
    fs.renameSync(stagedExecutable, destination);
    if (fs.existsSync(previous)) fs.unlinkSync(previous);
  } catch (error) {
    if (fs.existsSync(stagedPayload)) fs.unlinkSync(stagedPayload);
    if (fs.existsSync(stagedExecutable)) fs.unlinkSync(stagedExecutable);
    throw error;
  }
}

function findFile(directory: string, fileName: string): string | null {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const candidate = path.join(directory, entry.name);
    if (entry.isFile() && entry.name.toLowerCase() === fileName.toLowerCase()) return candidate;
    if (entry.isDirectory()) {
      const nested = findFile(candidate, fileName);
      if (nested) return nested;
    }
  }
  return null;
}

export async function installRuntimeEnvironment(
  onProgress: (event: RuntimeEnvironmentProgressEvent) => void,
): Promise<RuntimeEnvironmentReport> {
  const initial = await checkRuntimeEnvironment();
  const unsupported = initial.components.find((item) => item.required && !item.installed && !item.installable);
  if (unsupported && unsupported.id !== "network") {
    throw new Error(`当前设备不满足 ${unsupported.name} 要求，无法自动配置`);
  }
  const actionable = initial.components.filter((item) => item.installable && (!item.installed || item.updateAvailable));
  if (!actionable.length) {
    onProgress({ progress: 100, message: "环境已经齐全" });
    return initial;
  }
  fs.mkdirSync(managedToolsDirectory(), { recursive: true });
  for (let index = 0; index < actionable.length; index += 1) {
    const component = actionable[index];
    const base = 5 + Math.round((index / actionable.length) * 88);
    const span = Math.round(88 / actionable.length);
    if (component.id === "yt-dlp") {
      onProgress({ progress: base, message: "正在读取 yt-dlp 校验清单", componentId: component.id });
      const expected = checksumForFile(await fetchText(YTDLP_SUMS_URL), "yt-dlp.exe");
      await downloadWithResume(YTDLP_URL, managedYtDlpPath(), expected, (value) => {
        onProgress({ progress: base + Math.round((value / 100) * span), message: "正在安装 yt-dlp", componentId: component.id });
      });
    }
    if (component.id === "ffmpeg") {
      onProgress({ progress: base, message: "正在读取 FFmpeg 下载信息", componentId: component.id });
      const preferred = await latestStaticFfmpegAsset();
      let lastError: unknown;
      let installed = false;
      const installSource = async (asset: FfmpegDownloadAsset, sourceIndex: number) => {
        await installFfmpegAsset(asset, (value) => {
          onProgress({
            progress: base + Math.round((value / 100) * (span * 0.75)),
            message: sourceIndex === 0 ? "正在下载 FFmpeg" : "正在从备用源下载 FFmpeg",
            componentId: component.id,
          });
        }, 1);
      };
      try {
        await installSource(preferred, 0);
        installed = true;
      } catch (error) {
        lastError = error;
        appendDiagnostic("环境安装", `FFmpeg 下载源 1 失败：${error instanceof Error ? error.message : "未知错误"}`);
      }
      if (!installed) {
        try {
          const fallbackExpected = checksumForFile(await fetchText(FFMPEG_SUMS_URL), FFMPEG_ARCHIVE_NAME);
          await installSource(
            { url: FFMPEG_URL, sha256: fallbackExpected, fileName: FFMPEG_ARCHIVE_NAME, format: "zip" },
            1,
          );
          installed = true;
        } catch (error) {
          lastError = error;
          appendDiagnostic("环境安装", `FFmpeg 下载源 2 失败：${error instanceof Error ? error.message : "未知错误"}`);
        }
      }
      if (!installed) throw lastError instanceof Error ? lastError : new Error("无法取得 FFmpeg 安装文件");
      onProgress({ progress: base + span, message: "FFmpeg 安装完成", componentId: component.id });
    }
  }
  onProgress({ progress: 97, message: "正在进行最终验证" });
  const finalReport = await checkRuntimeEnvironment();
  if (!finalReport.ready) {
    const missing = finalReport.components.filter((item) => item.required && !item.installed).map((item) => item.name);
    throw new Error(`配置完成后验证未通过：${missing.join("、")}`);
  }
  onProgress({ progress: 100, message: "环境配置完成" });
  return finalReport;
}
