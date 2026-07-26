import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { net } from "electron";
import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import type {
  DownloadMode,
  DownloadProgressEvent,
  QualityOption,
  SupportedPlatform,
  VideoCollection,
  VideoCollectionItem,
  VideoMetadata,
} from "../bridgeTypes.js";
import { appendDiagnostic } from "./diagnostics.js";
import {
  BROWSER_USER_AGENT,
  weChatAuthorization,
} from "./wechatAuthorization.js";
import {
  defaultDownloadsDirectory,
  resolveFfmpegPath,
  resolveYtDlpPath,
  safeFilename,
  uniqueBasePath,
} from "./paths.js";
import { runProcess, setProcessPaused, terminateProcessTree } from "./processRunner.js";
import {
  type DirectShareProfile,
  parseDouyinSharePage,
  parseKuaishouSharePage,
  parseToutiaoSharePage,
  parseToutiaoVodProfile,
} from "./platformShareParsers.js";

const MOBILE_USER_AGENT = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1";
const KUAISHOU_USER_AGENT = "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Mobile Safari/537.36 Kwai/12.0.40";

const platformNames: Record<SupportedPlatform, string> = {
  bilibili: "哔哩哔哩",
  douyin: "抖音",
  kuaishou: "快手",
  xiaohongshu: "小红书",
  toutiao: "今日头条",
  wechatChannels: "微信视频号",
};

type YtDlpInfo = {
  id?: string;
  webpage_url?: string;
  original_url?: string;
  title?: string;
  uploader?: string;
  channel?: string;
  timestamp?: number;
  release_timestamp?: number;
  upload_date?: string;
  release_date?: string;
  duration?: number;
  thumbnail?: string;
  thumbnails?: Array<{ url?: string }>;
  formats?: Array<{
    format_id?: string;
    format_note?: string;
    resolution?: string;
    height?: number;
    ext?: string;
    acodec?: string;
    vcodec?: string;
    filesize?: number;
    filesize_approx?: number;
    tbr?: number;
  }>;
  entries?: YtDlpInfo[];
  filesize?: number;
  filesize_approx?: number;
  tbr?: number;
  url?: string;
};

type TaskState = {
  child?: ChildProcessWithoutNullStreams;
  abortController: AbortController;
  cancelled: boolean;
  paused: boolean;
  trackedPrefixes: Set<string>;
};

type DirectVideoMetadata = VideoMetadata;

const tasks = new Map<string, TaskState>();

function text(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function extractUrl(input: string) {
  const candidate = input.match(/https?:\/\/[^\s<>"'，。；、]+/i)?.[0];
  return candidate?.replace(/[)\]}>，。；、！？]+$/g, "") ?? null;
}

function normalizedUrl(value: string) {
  const url = new URL(value);
  if (url.protocol !== "http:" && url.protocol !== "https:") throw new Error("链接格式不正确");
  url.hash = "";
  return url.toString();
}

function detectPlatform(value: string): SupportedPlatform | null {
  const host = new URL(value).hostname.toLowerCase();
  if (host === "b23.tv" || host === "bilibili.com" || host.endsWith(".bilibili.com")) return "bilibili";
  if (host === "douyin.com" || host.endsWith(".douyin.com") || host.endsWith("iesdouyin.com")) return "douyin";
  if (host === "kuaishou.com" || host.endsWith(".kuaishou.com") || host === "kwai.com" || host.endsWith(".kwai.com")) return "kuaishou";
  if (
    host === "xiaohongshu.com"
    || host.endsWith(".xiaohongshu.com")
    || host === "xhslink.com"
    || host.endsWith(".xhslink.com")
    || host === "xhslink.cn"
    || host.endsWith(".xhslink.cn")
  ) return "xiaohongshu";
  if (host === "toutiao.com" || host.endsWith(".toutiao.com")) return "toutiao";
  if (host === "weixin.qq.com" || host === "channels.weixin.qq.com") return "wechatChannels";
  return null;
}

function formatDate(info: YtDlpInfo) {
  const raw = text(info.upload_date) ?? text(info.release_date);
  if (raw && /^\d{8}$/.test(raw)) return `${raw.slice(0, 4)}-${raw.slice(4, 6)}-${raw.slice(6, 8)}`;
  const timestamp = info.timestamp ?? info.release_timestamp;
  if (timestamp) return new Date(timestamp * 1000).toISOString().slice(0, 10);
  return "未知日期";
}

function formatDuration(seconds: number | undefined) {
  if (!seconds || !Number.isFinite(seconds)) return "未知时长";
  const total = Math.round(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const remaining = total % 60;
  return hours > 0
    ? `${hours}:${String(minutes).padStart(2, "0")}:${String(remaining).padStart(2, "0")}`
    : `${minutes}:${String(remaining).padStart(2, "0")}`;
}

function estimateSizeMb(info: YtDlpInfo) {
  const direct = info.filesize ?? info.filesize_approx;
  if (direct && direct > 0) return direct / 1_048_576;
  const formats = info.formats ?? [];
  const video = formats
    .filter((item) => item.vcodec && item.vcodec !== "none")
    .sort((a, b) => (b.height ?? 0) - (a.height ?? 0))[0];
  const audio = formats
    .filter((item) => item.acodec && item.acodec !== "none" && (!item.vcodec || item.vcodec === "none"))
    .sort((a, b) => (b.tbr ?? 0) - (a.tbr ?? 0))[0];
  const bytes = [video, audio].reduce((sum, item) => sum + (item?.filesize ?? item?.filesize_approx ?? 0), 0);
  if (bytes > 0) return bytes / 1_048_576;
  if (info.duration && info.tbr) return (info.duration * info.tbr * 1000) / 8 / 1_048_576;
  return undefined;
}

function buildQualities(info: YtDlpInfo): QualityOption[] {
  const seen = new Set<string>();
  const values = (info.formats ?? [])
    .filter((item) => item.vcodec && item.vcodec !== "none")
    .sort((a, b) => (b.height ?? 0) - (a.height ?? 0))
    .flatMap((item) => {
      const label = item.height ? `${item.height}P` : text(item.format_note) ?? text(item.resolution) ?? "可用画质";
      if (seen.has(label)) return [];
      seen.add(label);
      return [{
        id: text(item.format_id) ?? label,
        label,
        description: [item.ext?.toUpperCase(), item.vcodec].filter(Boolean).join(" · ") || "平台可用格式",
        available: true,
      }];
    });
  return values.length ? values.slice(0, 8) : [{ id: "best", label: "最佳可用画质", description: "由平台与 yt-dlp 自动选择", available: true }];
}

function collectionFromInfo(info: YtDlpInfo, platform: SupportedPlatform): VideoCollection | undefined {
  const entries = (info.entries ?? []).filter((item) => text(item.webpage_url) ?? text(item.url));
  if (entries.length <= 1) return undefined;
  const items: VideoCollectionItem[] = entries.map((entry, index) => ({
    id: text(entry.id) ?? `${info.id ?? "collection"}-${index + 1}`,
    title: text(entry.title) ?? `第 ${index + 1} 集`,
    url: text(entry.webpage_url) ?? text(entry.url) ?? "",
    platform,
    duration: entry.duration ? formatDuration(entry.duration) : undefined,
    coverUrl: text(entry.thumbnail) ?? undefined,
    index: index + 1,
  }));
  return { id: text(info.id) ?? crypto.randomUUID(), title: text(info.title) ?? "视频合集", items };
}

function parseJson(stdout: string): YtDlpInfo {
  const trimmed = stdout.trim();
  try {
    return JSON.parse(trimmed) as YtDlpInfo;
  } catch {
    const lines = trimmed.split(/\r?\n/).reverse();
    for (const line of lines) {
      try {
        return JSON.parse(line) as YtDlpInfo;
      } catch {
        continue;
      }
    }
    throw new Error("解析失败：yt-dlp 返回了无法识别的数据");
  }
}

function ytDlpHeaders(platform: SupportedPlatform) {
  const values = ["--user-agent", BROWSER_USER_AGENT];
  if (platform === "bilibili") values.push("--add-header", "Referer:https://www.bilibili.com/");
  if (platform === "douyin") values.push("--add-header", "Referer:https://www.douyin.com/");
  if (platform === "kuaishou") values.push("--add-header", "Referer:https://www.kuaishou.com/");
  if (platform === "xiaohongshu") values.push("--add-header", "Referer:https://www.xiaohongshu.com/");
  if (platform === "toutiao") values.push("--add-header", "Referer:https://www.toutiao.com/");
  return values;
}

async function embeddedCoverIfNeeded(source: string, platform: SupportedPlatform, referer: string) {
  if (!source || platform !== "xiaohongshu" || source.startsWith("data:")) return source;
  try {
    const response = await net.fetch(source, {
      redirect: "follow",
      headers: { "User-Agent": BROWSER_USER_AGENT, Referer: referer },
    });
    if (!response.ok) return source;
    const data = Buffer.from(await response.arrayBuffer());
    if (data.length === 0 || data.length > 8 * 1_048_576) return source;
    const mimeType = response.headers.get("content-type")?.split(";")[0] || "image/jpeg";
    return `data:${mimeType};base64,${data.toString("base64")}`;
  } catch {
    return source;
  }
}

async function fetchSharePage(
  url: string,
  userAgent: string,
  referer: string,
  timeoutMs = 35_000,
) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await net.fetch(url, {
      redirect: "follow",
      signal: controller.signal,
      headers: {
        "User-Agent": userAgent,
        Referer: referer,
        Accept: "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
      },
    });
    if (!response.ok) return null;
    return { html: await response.text(), resolvedUrl: response.url || url };
  } finally {
    clearTimeout(timeout);
  }
}

async function directShareProfile(
  platform: SupportedPlatform,
  originalUrl: string,
  normalizedPageUrl: string,
): Promise<DirectShareProfile | null> {
  const candidates = [...new Set([originalUrl, normalizedPageUrl].filter(Boolean))];
  if (platform === "douyin") {
    for (const candidate of candidates) {
      const page = await fetchSharePage(candidate, MOBILE_USER_AGENT, "https://www.douyin.com/").catch(() => null);
      const profile = page ? parseDouyinSharePage(page.html, page.resolvedUrl) : null;
      if (profile) return profile;
    }
  }
  if (platform === "kuaishou") {
    for (const candidate of candidates) {
      const page = await fetchSharePage(candidate, KUAISHOU_USER_AGENT, "https://v.kuaishou.com/").catch(() => null);
      const profile = page ? parseKuaishouSharePage(page.html, page.resolvedUrl) : null;
      if (profile) return profile;
    }
  }
  if (platform === "toutiao") {
    for (const candidate of candidates) {
      const page = await fetchSharePage(candidate, MOBILE_USER_AGENT, "https://m.toutiao.com/").catch(() => null);
      const pageProfile = page ? parseToutiaoSharePage(page.html) : null;
      if (!page || !pageProfile) continue;
      const endpoint = `https://vod.bytedanceapi.com/?${pageProfile.playQuery}`;
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 35_000);
      try {
        const response = await net.fetch(endpoint, {
          signal: controller.signal,
          headers: {
            "User-Agent": MOBILE_USER_AGENT,
            Referer: page.resolvedUrl,
            Accept: "application/json, text/plain, */*",
          },
        });
        if (!response.ok) continue;
        const profile = parseToutiaoVodProfile(
          await response.json() as Record<string, unknown>,
          pageProfile,
          page.resolvedUrl,
        );
        if (profile) return profile;
      } catch {
        continue;
      } finally {
        clearTimeout(timeout);
      }
    }
  }
  return null;
}

function metadataFromDirectProfile(
  originalUrl: string,
  platform: SupportedPlatform,
  profile: DirectShareProfile,
): DirectVideoMetadata {
  const platformNote = platform === "douyin"
    ? profile.kind === "image-post"
      ? "已通过抖音分享页解析图文作品；下载时会用公开图片和原声音频在本机合成视频。"
      : "已通过抖音分享页解析公开视频信息；下载时会使用无水印实际播放流。"
    : platform === "kuaishou"
      ? "已通过快手分享页解析公开视频信息；下载时会使用分享页返回的公开视频地址。"
      : "已通过今日头条移动分享页解析公开视频信息；下载时会使用分享页返回的实际播放内容。";
  return {
    id: profile.id,
    originalUrl,
    normalizedUrl: profile.resolvedUrl,
    platform,
    platformName: platformNames[platform],
    title: profile.title,
    author: profile.author,
    publishedAt: profile.publishedAt,
    duration: formatDuration(profile.durationSeconds),
    coverUrl: profile.coverUrl,
    qualities: profile.qualities,
    estimatedSizeMb: profile.sizeBytes ? profile.sizeBytes / 1_048_576 : undefined,
    parseMode: "real",
    note: platformNote,
    suggestedFilename: safeFilename(profile.title),
    directMediaUrl: profile.mediaUrl,
    directMediaKind: profile.kind,
    directImageUrls: profile.imageUrls,
    directAudioUrl: profile.audioUrl,
  };
}

async function parseWeChatPublic(originalUrl: string, url: string): Promise<VideoMetadata> {
  const parsed = new URL(url);
  const shortUri = parsed.hostname === "weixin.qq.com"
    ? parsed.pathname.split("/").filter(Boolean)[1]
    : parsed.searchParams.get("id");
  if (!shortUri) throw new Error("解析失败：未识别到微信视频号分享标识");
  const canonical = `https://channels.weixin.qq.com/finder-preview/pages/sph?id=${encodeURIComponent(shortUri)}`;
  const response = await net.fetch("https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info", {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Accept: "application/json, text/plain, */*",
      "User-Agent": BROWSER_USER_AGENT,
      Origin: "https://channels.weixin.qq.com",
      Referer: canonical,
    },
    body: JSON.stringify({ baseReq: { generalToken: "" }, shortUri }),
  });
  if (!response.ok) throw new Error("解析失败：微信视频号公开接口暂时不可用");
  const value = await response.json() as any;
  if (value.errCode && value.errCode !== 0) throw new Error(`解析失败：${value.errMsg || "微信视频号未返回公开内容"}`);
  const feed = value.data?.feedInfo;
  if (!feed) throw new Error("解析失败：该微信视频号内容已失效或不可公开访问");
  const title = text(feed.description) ?? "未命名视频";
  return {
    id: text(value.data?.sceneInfo?.dynamicExportId) ?? shortUri,
    originalUrl,
    normalizedUrl: canonical,
    platform: "wechatChannels",
    platformName: platformNames.wechatChannels,
    title,
    author: text(value.data?.authorInfo?.nickname) ?? "未知作者",
    publishedAt: feed.createtime ? new Date(Number(feed.createtime) * 1000).toISOString().slice(0, 10) : "未知日期",
    duration: "登录后获取",
    coverUrl: text(feed.coverUrl) ?? "",
    qualities: [{ id: "source", label: "原始画质", description: "微信视频号实际播放内容", available: true }],
    parseMode: "real",
    note: "已通过微信视频号官方预览接口解析；首次下载时需在独立的腾讯元宝窗口完成授权。",
    suggestedFilename: safeFilename(title),
  };
}

export async function parseVideo(inputText: string): Promise<VideoMetadata> {
  if (!inputText.trim()) throw new Error("请输入链接");
  const extracted = extractUrl(inputText);
  if (!extracted) throw new Error("未识别到链接");
  const url = normalizedUrl(extracted);
  const platform = detectPlatform(url);
  if (!platform) throw new Error("暂不支持的平台");
  appendDiagnostic("解析", `开始解析 ${platformNames[platform]} 链接`);
  if (platform === "wechatChannels") return await parseWeChatPublic(extracted, url);
  if (platform === "douyin" || platform === "kuaishou" || platform === "toutiao") {
    const profile = await directShareProfile(platform, extracted, url).catch(() => null);
    if (profile) {
      const metadata = metadataFromDirectProfile(extracted, platform, profile);
      appendDiagnostic("解析", `分享页直解析成功：${metadata.title}`);
      return metadata;
    }
  }

  const executable = resolveYtDlpPath();
  if (!executable) throw new Error("未找到 yt-dlp，请先点击“配置所需环境”完成安装");
  const baseArgs = ["--encoding", "utf-8", "--dump-single-json", "--skip-download", "--no-warnings", "--no-playlist", "--force-ipv4", ...ytDlpHeaders(platform), url];
  const result = await runProcess(executable, baseArgs, { timeoutMs: 120_000 });
  if (result.exitCode !== 0) throw standardizeYtDlpError(result.stderr || result.stdout);
  const info = parseJson(result.stdout);

  let collection: VideoCollection | undefined;
  if (platform === "bilibili" || platform === "douyin") {
    const collectionResult = await runProcess(
      executable,
      ["--encoding", "utf-8", "--dump-single-json", "--flat-playlist", "--skip-download", "--no-warnings", "--force-ipv4", ...ytDlpHeaders(platform), url],
      { timeoutMs: 90_000 },
    ).catch(() => null);
    if (collectionResult?.exitCode === 0) collection = collectionFromInfo(parseJson(collectionResult.stdout), platform);
  }
  const title = text(info.title) ?? "未命名视频";
  const resolvedPageURL = text(info.webpage_url) ?? url;
  const rawCover = text(info.thumbnail) ?? info.thumbnails?.map((item) => text(item.url)).find(Boolean) ?? "";
  const metadata: VideoMetadata = {
    id: text(info.id) ?? crypto.randomUUID(),
    originalUrl: extracted,
    normalizedUrl: resolvedPageURL,
    platform,
    platformName: platformNames[platform],
    title,
    author: text(info.uploader) ?? text(info.channel) ?? "未知作者",
    publishedAt: formatDate(info),
    duration: formatDuration(info.duration),
    coverUrl: await embeddedCoverIfNeeded(rawCover, platform, resolvedPageURL),
    qualities: buildQualities(info),
    estimatedSizeMb: estimateSizeMb(info),
    parseMode: "real",
    note: "已通过 Windows 本地解析服务读取真实内容信息。",
    suggestedFilename: safeFilename(title),
    collection,
    directMediaUrl: text(info.url) ?? undefined,
  };
  appendDiagnostic("解析", `解析成功：${metadata.title}`);
  return metadata;
}

function standardizeYtDlpError(raw: string) {
  const message = raw.trim().split(/\r?\n/).filter(Boolean).slice(-3).join(" ");
  if (/Unsupported URL/i.test(message)) return new Error("解析失败：当前链接类型暂不受平台解析器支持");
  if (/HTTP Error 403|Forbidden/i.test(message)) return new Error("解析失败：平台拒绝访问，请稍后重试或更新 yt-dlp");
  if (/not available|private|login/i.test(message)) return new Error("解析失败：内容不可公开访问、已失效或需要登录");
  return new Error(message ? `解析/下载失败：${message}` : "解析/下载失败");
}

function formatSelector(mode: DownloadMode) {
  switch (mode) {
    case "audio": return ["-x", "--audio-format", "m4a"];
    case "video": return ["-f", "bv*", "--remux-video", "mp4"];
    case "separate": return ["-f", "bv,ba"];
    default: return ["-f", "bv*+ba/b", "--merge-output-format", "mp4"];
  }
}

function suffixForMode(mode: DownloadMode) {
  if (mode === "audio") return " - 仅音频";
  if (mode === "video") return " - 仅视频";
  if (mode === "separate") return " - 音视频分开";
  return "";
}

async function runYtDlpDownload(
  metadata: VideoMetadata,
  itemUrl: string,
  directory: string,
  mode: DownloadMode,
  taskId: string,
  progress: (event: DownloadProgressEvent) => void,
  baseProgress = 0,
  span = 100,
) {
  const executable = resolveYtDlpPath();
  if (!executable) throw new Error("未找到 yt-dlp，请先配置所需环境");
  const ffmpeg = resolveFfmpegPath();
  if (!ffmpeg) throw new Error("未找到 FFmpeg，请先配置所需环境");
  const extensions = ["mp4", "mkv", "webm", "m4a", "mp3", "opus"];
  const base = uniqueBasePath(directory, `${metadata.suggestedFilename ?? metadata.title}${suffixForMode(mode)}`, extensions);
  const state = tasks.get(taskId);
  state?.trackedPrefixes.add(base);
  const outputTemplate = mode === "separate" ? `${base}.%(format_id)s.%(ext)s` : `${base}.%(ext)s`;
  const args = [
    "--encoding", "utf-8",
    "--newline",
    "--continue",
    "--no-overwrites",
    "--windows-filenames",
    "--force-ipv4",
    "--progress-template", "download:__EK_PROGRESS__:%(progress._percent_str)s",
    "--print", "after_move:__EK_FILE__:%(filepath)s",
    "-o", outputTemplate,
    ...formatSelector(mode),
    ...(ffmpeg ? ["--ffmpeg-location", ffmpeg] : []),
    ...ytDlpHeaders(metadata.platform),
    itemUrl,
  ];
  const savedPaths: string[] = [];
  const result = await runProcess(executable, args, {
    timeoutMs: 2 * 60 * 60_000,
    stallTimeoutMs: 90_000,
    isPaused: () => tasks.get(taskId)?.paused === true,
    onSpawn: (child) => {
      const current = tasks.get(taskId);
      if (current) current.child = child;
    },
    onLine: (line) => {
      const file = line.match(/^__EK_FILE__:(.+)$/)?.[1]?.trim();
      if (file) savedPaths.push(file);
      const percentage = Number(line.match(/__EK_PROGRESS__:\s*([0-9.]+)%/)?.[1]);
      if (Number.isFinite(percentage)) {
        progress({
          status: "downloading",
          progress: Math.min(99, Math.round(baseProgress + (percentage / 100) * span)),
          message: mode === "audio" ? "正在下载并提取音频" : mode === "video" ? "正在下载视频" : "正在下载媒体",
        });
      }
    },
  });
  if (tasks.get(taskId)?.cancelled) throw new Error("下载已取消");
  if (result.exitCode !== 0) throw standardizeYtDlpError(result.stderr || result.stdout);
  return savedPaths.at(-1) ?? `${base}.${mode === "audio" ? "m4a" : "mp4"}`;
}

function durationFromDisplay(value: string) {
  const parts = value.split(":").map(Number);
  if (!parts.length || parts.some((part) => !Number.isFinite(part))) return undefined;
  if (parts.length === 3) return parts[0] * 3600 + parts[1] * 60 + parts[2];
  if (parts.length === 2) return parts[0] * 60 + parts[1];
  return parts[0] > 0 ? parts[0] : undefined;
}

function directRequestProfile(platform: SupportedPlatform, pageUrl: string) {
  if (platform === "kuaishou") {
    return { userAgent: KUAISHOU_USER_AGENT, referer: "https://m.kuaishou.com/" };
  }
  if (platform === "toutiao") {
    return { userAgent: MOBILE_USER_AGENT, referer: pageUrl };
  }
  return { userAgent: MOBILE_USER_AGENT, referer: "https://www.douyin.com/" };
}

async function runFfmpegCommand(
  executable: string,
  args: string[],
  taskId: string,
  duration: number | undefined,
  progress: (event: DownloadProgressEvent) => void,
  progressStart: number,
  progressEnd: number,
  message: string,
) {
  let lastProgress = progressStart;
  progress({ status: "downloading", progress: progressStart, message });
  const result = await runProcess(
    executable,
    [
      "-y",
      "-nostdin",
      "-hide_banner",
      "-loglevel", "warning",
      "-progress", "pipe:1",
      "-nostats",
      ...args,
    ],
    {
      onSpawn: (child) => {
        const current = tasks.get(taskId);
        if (current) current.child = child;
      },
      onLine: (line) => {
        const raw = Number(line.match(/^out_time_(?:us|ms)=(\d+)/)?.[1]);
        if (duration && Number.isFinite(raw)) {
          const percentage = Math.min(1, raw / 1_000_000 / duration);
          const current = Math.round(progressStart + percentage * (progressEnd - progressStart));
          if (current > lastProgress) {
            lastProgress = current;
            progress({ status: "downloading", progress: current, message });
          }
        }
      },
      timeoutMs: 30 * 60_000,
      stallTimeoutMs: 90_000,
      isPaused: () => tasks.get(taskId)?.paused === true,
    },
  );
  if (tasks.get(taskId)?.cancelled) throw new Error("下载已取消");
  if (result.exitCode !== 0) {
    const detail = (result.stderr || result.stdout).split(/\r?\n/).filter(Boolean).at(-1);
    throw new Error(`下载失败：${detail ?? "FFmpeg 处理失败"}`);
  }
}

async function downloadDirectVideo(
  metadata: DirectVideoMetadata,
  profile: DirectShareProfile,
  directory: string,
  mode: DownloadMode,
  taskId: string,
  progress: (event: DownloadProgressEvent) => void,
) {
  const mediaUrl = profile.mediaUrl ?? metadata.directMediaUrl;
  if (!mediaUrl) throw new Error(`下载失败：${metadata.platformName}未返回可下载的视频地址`);
  const ffmpeg = resolveFfmpegPath();
  if (!ffmpeg) throw new Error("未找到 FFmpeg，请先配置所需环境");
  const duration = profile.durationSeconds ?? durationFromDisplay(metadata.duration);
  const base = uniqueBasePath(
    directory,
    `${metadata.suggestedFilename ?? metadata.title}${suffixForMode(mode)}`,
    ["mp4", "m4a"],
  );
  tasks.get(taskId)?.trackedPrefixes.add(base);
  const request = directRequestProfile(metadata.platform, profile.resolvedUrl);
  const input = [
    "-user_agent", request.userAgent,
    "-headers", `User-Agent: ${request.userAgent}\r\nReferer: ${request.referer}\r\n`,
    "-i", mediaUrl,
  ];
  if (mode === "audio") {
    const output = `${base}.m4a`;
    await runFfmpegCommand(
      ffmpeg,
      [...input, "-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "192k", output],
      taskId, duration, progress, 3, 99, "正在下载并提取音频",
    );
    return output;
  }
  if (mode === "video") {
    const output = `${base}.mp4`;
    await runFfmpegCommand(
      ffmpeg,
      [...input, "-map", "0:v:0", "-an", "-c:v", "copy", "-movflags", "+faststart", output],
      taskId, duration, progress, 3, 99, "正在下载视频",
    );
    return output;
  }
  if (mode === "separate") {
    const videoOutput = `${base}.mp4`;
    const audioOutput = `${base}.m4a`;
    await runFfmpegCommand(
      ffmpeg,
      [...input, "-map", "0:v:0", "-an", "-c:v", "copy", "-movflags", "+faststart", videoOutput],
      taskId, duration, progress, 3, 50, "正在下载视频",
    );
    await runFfmpegCommand(
      ffmpeg,
      [...input, "-map", "0:a:0", "-vn", "-c:a", "aac", "-b:a", "192k", audioOutput],
      taskId, duration, progress, 51, 99, "正在提取音频",
    );
    return `视频 ${videoOutput}；音频 ${audioOutput}`;
  }
  const output = `${base}.mp4`;
  await runFfmpegCommand(
    ffmpeg,
    [
      ...input,
      "-map", "0:v:0?",
      "-map", "0:a:0?",
      "-c", "copy",
      "-movflags", "+faststart",
      output,
    ],
    taskId, duration, progress, 3, 99, "正在下载媒体",
  );
  return output;
}

async function fetchDirectAsset(
  url: string,
  outputPath: string,
  userAgent: string,
  referer: string,
  taskId: string,
) {
  const task = tasks.get(taskId);
  if (!task || task.cancelled) throw new Error("下载已取消");
  const controller = new AbortController();
  let timedOut = false;
  let idleTimer: ReturnType<typeof setTimeout> | undefined;
  const abortForTask = () => controller.abort();
  const resetIdleTimer = () => {
    if (idleTimer) clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      timedOut = true;
      controller.abort();
    }, 60_000);
  };
  task.abortController.signal.addEventListener("abort", abortForTask, { once: true });
  resetIdleTimer();
  try {
    const response = await net.fetch(url, {
      redirect: "follow",
      headers: { "User-Agent": userAgent, Referer: referer },
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`下载失败：远程素材返回 HTTP ${response.status}`);
    if (!response.body) throw new Error("下载失败：远程素材内容为空");
    const chunks: Buffer[] = [];
    const reader = response.body.getReader();
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (tasks.get(taskId)?.cancelled) throw new Error("下载已取消");
      if (value?.byteLength) {
        chunks.push(Buffer.from(value));
        resetIdleTimer();
      }
    }
    const data = Buffer.concat(chunks);
    if (!data.length) throw new Error("下载失败：远程素材内容为空");
    fs.writeFileSync(outputPath, data);
  } catch (error) {
    if (tasks.get(taskId)?.cancelled) throw new Error("下载已取消");
    if (timedOut) throw new Error("下载失败：远程素材超过 60 秒没有收到新数据");
    throw error;
  } finally {
    if (idleTimer) clearTimeout(idleTimer);
    task.abortController.signal.removeEventListener("abort", abortForTask);
  }
}

async function downloadDouyinImagePost(
  metadata: DirectVideoMetadata,
  profile: DirectShareProfile,
  directory: string,
  mode: DownloadMode,
  taskId: string,
  progress: (event: DownloadProgressEvent) => void,
) {
  const imageUrls = profile.imageUrls ?? metadata.directImageUrls ?? [];
  const audioUrl = profile.audioUrl ?? metadata.directAudioUrl;
  if (!imageUrls.length && mode !== "audio") {
    throw new Error("下载失败：抖音图文作品未返回图片地址");
  }
  if (!audioUrl && mode === "audio") {
    throw new Error("下载失败：抖音图文作品未返回音频地址");
  }
  const ffmpeg = resolveFfmpegPath();
  if (!ffmpeg) throw new Error("未找到 FFmpeg，请先配置所需环境");
  const temporaryDirectory = fs.mkdtempSync(path.join(os.tmpdir(), "ek-streamdl-douyin-"));
  const temporaryFiles: string[] = [];
  const request = directRequestProfile("douyin", profile.resolvedUrl);
  try {
    const imagePaths: string[] = [];
    if (mode !== "audio") {
      for (let index = 0; index < imageUrls.length; index += 1) {
        if (tasks.get(taskId)?.cancelled) throw new Error("下载已取消");
        const imagePath = path.join(temporaryDirectory, `image-${String(index + 1).padStart(3, "0")}.img`);
        await fetchDirectAsset(imageUrls[index], imagePath, request.userAgent, request.referer, taskId);
        temporaryFiles.push(imagePath);
        imagePaths.push(imagePath);
        progress({
          status: "downloading",
          progress: Math.round(5 + ((index + 1) / imageUrls.length) * 25),
          message: `下载图文素材 ${index + 1}/${imageUrls.length}`,
        });
      }
    }

    let audioPath: string | undefined;
    if (audioUrl && mode !== "video") {
      audioPath = path.join(temporaryDirectory, "audio-source");
      await fetchDirectAsset(audioUrl, audioPath, request.userAgent, request.referer, taskId);
      temporaryFiles.push(audioPath);
      progress({ status: "downloading", progress: 34, message: "已下载原声音频" });
    }

    const duration = profile.durationSeconds
      ?? durationFromDisplay(metadata.duration)
      ?? Math.max(3, imagePaths.length * 3);
    const base = uniqueBasePath(
      directory,
      `${metadata.suggestedFilename ?? metadata.title}${suffixForMode(mode)}`,
      ["mp4", "m4a"],
    );
    tasks.get(taskId)?.trackedPrefixes.add(base);

    const createVideo = async (output: string, includeAudio: boolean, start: number, end: number) => {
      const secondsPerImage = Math.max(1, duration / imagePaths.length);
      const inputs = imagePaths.flatMap((imagePath) => [
        "-loop", "1",
        "-t", secondsPerImage.toFixed(3),
        "-i", imagePath,
      ]);
      if (includeAudio && audioPath) inputs.push("-i", audioPath);
      const scaled = imagePaths.map((_, index) =>
        `[${index}:v]scale=1280:720:force_original_aspect_ratio=decrease,`
        + `pad=1280:720:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v${index}]`,
      );
      const chain = imagePaths.map((_, index) => `[v${index}]`).join("");
      const filter = `${scaled.join(";")};${chain}concat=n=${imagePaths.length}:v=1:a=0[outv]`;
      const audioInputIndex = imagePaths.length;
      await runFfmpegCommand(
        ffmpeg,
        [
          ...inputs,
          "-filter_complex", filter,
          "-map", "[outv]",
          ...(includeAudio && audioPath ? ["-map", `${audioInputIndex}:a:0`, "-c:a", "aac", "-shortest"] : ["-an"]),
          "-c:v", "libx264",
          "-preset", "veryfast",
          "-crf", "18",
          "-pix_fmt", "yuv420p",
          "-movflags", "+faststart",
          "-t", duration.toFixed(3),
          output,
        ],
        taskId, duration, progress, start, end, includeAudio ? "正在合成图文视频" : "正在生成无声图文视频",
      );
    };

    const createAudio = async (output: string, start: number, end: number) => {
      if (!audioPath) throw new Error("下载失败：抖音图文作品未返回音频地址");
      await runFfmpegCommand(
        ffmpeg,
        ["-i", audioPath, "-vn", "-c:a", "aac", "-b:a", "192k", output],
        taskId, duration, progress, start, end, "正在生成音频文件",
      );
    };

    if (mode === "audio") {
      const output = `${base}.m4a`;
      await createAudio(output, 35, 99);
      return output;
    }
    if (mode === "video") {
      const output = `${base}.mp4`;
      await createVideo(output, false, 35, 99);
      return output;
    }
    if (mode === "separate") {
      const videoOutput = `${base}.mp4`;
      const audioOutput = `${base}.m4a`;
      await createVideo(videoOutput, false, 35, 75);
      await createAudio(audioOutput, 76, 99);
      return `视频 ${videoOutput}；音频 ${audioOutput}`;
    }
    const output = `${base}.mp4`;
    await createVideo(output, Boolean(audioPath), 35, 99);
    return output;
  } finally {
    for (const file of temporaryFiles) {
      if (fs.existsSync(file)) fs.unlinkSync(file);
    }
    if (fs.existsSync(temporaryDirectory)) fs.rmdirSync(temporaryDirectory);
  }
}

async function downloadViaDirectSharePage(
  metadata: DirectVideoMetadata,
  directory: string,
  mode: DownloadMode,
  taskId: string,
  progress: (event: DownloadProgressEvent) => void,
) {
  progress({ status: "preparing", progress: 2, message: `刷新${metadata.platformName}下载地址` });
  const refreshed = await directShareProfile(
    metadata.platform,
    metadata.originalUrl,
    metadata.normalizedUrl,
  ).catch(() => null);
  const profile: DirectShareProfile = refreshed ?? {
    id: metadata.id,
    resolvedUrl: metadata.normalizedUrl,
    title: metadata.title,
    author: metadata.author,
    publishedAt: metadata.publishedAt,
    durationSeconds: durationFromDisplay(metadata.duration),
    coverUrl: metadata.coverUrl,
    qualities: metadata.qualities,
    mediaUrl: metadata.directMediaUrl,
    imageUrls: metadata.directImageUrls,
    audioUrl: metadata.directAudioUrl,
    kind: metadata.directMediaKind ?? "video",
  };
  if (profile.kind === "image-post") {
    return downloadDouyinImagePost(metadata, profile, directory, mode, taskId, progress);
  }
  return downloadDirectVideo(metadata, profile, directory, mode, taskId, progress);
}

function weChatShortUri(raw: string) {
  const url = new URL(raw);
  return url.hostname === "weixin.qq.com"
    ? url.pathname.split("/").filter(Boolean)[1]
    : url.searchParams.get("id");
}

async function weChatMediaProfile(metadata: VideoMetadata, taskId: string) {
  const shortUri = weChatShortUri(metadata.originalUrl) ?? weChatShortUri(metadata.normalizedUrl);
  const shareURL = shortUri ? `https://weixin.qq.com/sph/${shortUri}` : metadata.originalUrl;
  const parsed = await weChatAuthorization.authorizedParse(shareURL, () => tasks.get(taskId)?.cancelled === true);
  const playable = text(parsed.data?.playable_url);
  if (!playable) throw new Error("下载失败：腾讯元宝未返回微信视频号播放凭证");
  const playableURL = new URL(playable);
  const token = playableURL.searchParams.get("token");
  const exportId = playableURL.searchParams.get("eid") ?? text(parsed.data?.wx_export_id);
  if (!token || !exportId) throw new Error("下载失败：微信视频号播放凭证不完整");
  const refererURL = new URL("https://channels.weixin.qq.com/finder-preview/pages/feed");
  Object.entries({ entry_card_type: "48", comment_scene: "39", appid: "0", token, entry_scene: "0", eid: exportId })
    .forEach(([key, value]) => refererURL.searchParams.set(key, value));
  const endpoint = new URL("https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info");
  endpoint.searchParams.set("_rid", `${Math.floor(Date.now() / 1000)}-${crypto.randomUUID().slice(0, 8)}`);
  endpoint.searchParams.set("_pageUrl", "https://channels.weixin.qq.com/finder-preview/pages/feed");
  const task = tasks.get(taskId);
  if (!task || task.cancelled) throw new Error("下载已取消");
  const controller = new AbortController();
  let timedOut = false;
  const abortForTask = () => controller.abort();
  task.abortController.signal.addEventListener("abort", abortForTask, { once: true });
  const timeout = setTimeout(() => {
    timedOut = true;
    controller.abort();
  }, 60_000);
  let value: any;
  try {
    const response = await net.fetch(endpoint.toString(), {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Accept: "application/json, text/plain, */*",
        "User-Agent": BROWSER_USER_AGENT,
        Origin: "https://channels.weixin.qq.com",
        Referer: refererURL.toString(),
      },
      body: JSON.stringify({ baseReq: { generalToken: token }, exportId }),
      signal: controller.signal,
    });
    if (!response.ok) throw new Error("下载失败：微信视频号播放接口暂时不可用");
    value = await response.json();
  } catch (error) {
    if (tasks.get(taskId)?.cancelled) throw new Error("下载已取消");
    if (timedOut) throw new Error("下载失败：微信视频号播放接口响应超时");
    throw error;
  } finally {
    clearTimeout(timeout);
    task.abortController.signal.removeEventListener("abort", abortForTask);
  }
  if (value.errCode && value.errCode !== 0) throw new Error(`下载失败：${value.errMsg || "微信视频号播放凭证已失效"}`);
  const feed = value.data?.feedInfo;
  const candidates = [feed?.originVideoUrl, feed?.videoUrl, feed?.h264VideoInfo?.videoUrl, feed?.h265VideoInfo?.videoUrl]
    .map(text).filter(Boolean) as string[];
  if (!candidates.length) throw new Error("下载失败：微信视频号未返回可用的视频地址");
  const cleaned = (() => {
    try {
      const url = new URL(candidates[0]);
      const encfilekey = url.searchParams.get("encfilekey");
      const mediaToken = url.searchParams.get("token");
      if (!encfilekey || !mediaToken) return candidates[0];
      url.search = "";
      url.searchParams.set("encfilekey", encfilekey);
      url.searchParams.set("token", mediaToken);
      return url.toString();
    } catch {
      return candidates[0];
    }
  })();
  return { mediaURL: cleaned, referer: refererURL.toString() };
}

async function downloadWeChat(
  metadata: VideoMetadata,
  directory: string,
  mode: DownloadMode,
  taskId: string,
  progress: (event: DownloadProgressEvent) => void,
) {
  progress({ status: "preparing", progress: 3, message: "检查微信视频号授权" });
  const profile = await weChatMediaProfile(metadata, taskId);
  progress({ status: "preparing", progress: 5, message: "已获取微信视频号媒体信息", weChatAuthorized: true });
  const ffmpeg = resolveFfmpegPath();
  if (!ffmpeg) throw new Error("未找到 FFmpeg，请先配置所需环境");
  const base = uniqueBasePath(directory, `${metadata.suggestedFilename ?? metadata.title}${suffixForMode(mode)}`, ["mp4", "m4a"]);
  tasks.get(taskId)?.trackedPrefixes.add(base);
  const common = ["-y", "-headers", `User-Agent: ${BROWSER_USER_AGENT}\r\nReferer: ${profile.referer}\r\n`, "-i", profile.mediaURL];
  const commands: Array<{ args: string[]; output: string }> = [];
  if (mode === "audio") commands.push({ args: [...common, "-vn", "-c:a", "copy", `${base}.m4a`], output: `${base}.m4a` });
  else if (mode === "video") commands.push({ args: [...common, "-an", "-c:v", "copy", `${base}.mp4`], output: `${base}.mp4` });
  else if (mode === "separate") {
    commands.push({ args: [...common, "-an", "-c:v", "copy", `${base}.mp4`], output: `${base}.mp4` });
    commands.push({ args: [...common, "-vn", "-c:a", "copy", `${base}.m4a`], output: `${base}.m4a` });
  } else commands.push({ args: [...common, "-c", "copy", `${base}.mp4`], output: `${base}.mp4` });
  for (let index = 0; index < commands.length; index += 1) {
    const command = commands[index];
    const result = await runProcess(ffmpeg, command.args, {
      timeoutMs: 30 * 60_000,
      stallTimeoutMs: 90_000,
      isPaused: () => tasks.get(taskId)?.paused === true,
      onSpawn: (child) => {
        const current = tasks.get(taskId);
        if (current) current.child = child;
      },
      onLine: (line) => {
        const time = line.match(/time=(\d+):(\d+):(\d+(?:\.\d+)?)/);
        const durationParts = metadata.duration.split(":").map(Number);
        const duration = durationParts.length === 3
          ? durationParts[0] * 3600 + durationParts[1] * 60 + durationParts[2]
          : durationParts[0] * 60 + (durationParts[1] ?? 0);
        if (time && duration > 0) {
          const current = Number(time[1]) * 3600 + Number(time[2]) * 60 + Number(time[3]);
          const local = Math.min(99, (current / duration) * 100);
          progress({ status: "downloading", progress: Math.round(((index + local / 100) / commands.length) * 99), message: "正在下载微信视频号媒体" });
        }
      },
    });
    if (tasks.get(taskId)?.cancelled) throw new Error("下载已取消");
    if (result.exitCode !== 0) throw new Error(`下载失败：${result.stderr.split(/\r?\n/).filter(Boolean).at(-1) ?? "FFmpeg 处理失败"}`);
  }
  return commands.map((item) => item.output).join("；");
}

export async function downloadVideo(
  metadata: VideoMetadata,
  downloadDirectoryPath: string | undefined,
  mode: DownloadMode,
  taskId: string,
  progress: (event: DownloadProgressEvent) => void,
) {
  const directory = downloadDirectoryPath?.trim() || defaultDownloadsDirectory();
  fs.mkdirSync(directory, { recursive: true });
  tasks.set(taskId, {
    abortController: new AbortController(),
    cancelled: false,
    paused: false,
    trackedPrefixes: new Set(),
  });
  try {
    let savedPath: string;
    if (metadata.platform === "wechatChannels") {
      savedPath = await downloadWeChat(metadata, directory, mode, taskId, progress);
    } else if (
      metadata.platform === "douyin"
      || metadata.platform === "kuaishou"
      || metadata.platform === "toutiao"
    ) {
      savedPath = await downloadViaDirectSharePage(
        metadata as DirectVideoMetadata,
        directory,
        mode,
        taskId,
        progress,
      );
    } else {
      const selected = metadata.selectedCollectionItems?.length ? metadata.selectedCollectionItems : null;
      if (selected) {
        const paths: string[] = [];
        for (let index = 0; index < selected.length; index += 1) {
          if (tasks.get(taskId)?.cancelled) throw new Error("下载已取消");
          const item = selected[index];
          progress({ status: "preparing", progress: Math.round((index / selected.length) * 100), message: `第 ${index + 1}/${selected.length} 集：准备下载` });
          const itemMetadata = { ...metadata, title: item.title, suggestedFilename: `${String(item.index).padStart(2, "0")} - ${safeFilename(item.title)}` };
          const saved = await runYtDlpDownload(itemMetadata, item.url, directory, mode, taskId, (event) => {
            progress({ ...event, message: `第 ${index + 1}/${selected.length} 集：${event.message}` });
          }, (index / selected.length) * 100, 100 / selected.length);
          paths.push(saved);
          progress({ status: "downloading", progress: Math.round(((index + 1) / selected.length) * 99), message: `第 ${index + 1}/${selected.length} 集：已完成：${saved}` });
        }
        savedPath = paths.join("；");
      } else {
        savedPath = await runYtDlpDownload(metadata, metadata.normalizedUrl, directory, mode, taskId, progress);
      }
    }
    appendDiagnostic("下载", `任务完成：${savedPath}`);
    return { savedPath };
  } finally {
    const state = tasks.get(taskId);
    if (state) state.child = undefined;
    tasks.delete(taskId);
  }
}

export async function cancelDownload(taskId: string, deletePartialFiles: boolean) {
  const state = tasks.get(taskId);
  if (!state) return false;
  state.cancelled = true;
  state.abortController.abort();
  terminateProcessTree(state.child);
  let cleanupCompleted = true;
  if (deletePartialFiles) {
    const cleanup = cleanupTrackedDownloadFiles(state.trackedPrefixes);
    cleanupCompleted = await Promise.race([
      cleanup.then(() => true),
      new Promise<false>((resolve) => setTimeout(() => resolve(false), 2_000)),
    ]);
  }
  appendDiagnostic(
    "下载",
    !deletePartialFiles
      ? "任务已取消，临时文件已保留"
      : cleanupCompleted
        ? "任务已取消，临时文件已清理"
        : "任务已取消，临时文件继续在后台清理",
  );
  return true;
}

async function cleanupTrackedDownloadFiles(prefixes: Set<string>) {
  for (const prefix of prefixes) {
    const directory = path.dirname(prefix);
    const name = path.basename(prefix);
    let entries: string[];
    try {
      entries = await fs.promises.readdir(directory);
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (entry !== name && !entry.startsWith(`${name}.`)) continue;
      const target = path.join(directory, entry);
      try {
        if ((await fs.promises.lstat(target)).isFile()) {
          await fs.promises.unlink(target);
        }
      } catch {
        // 文件可能已被下载进程或用户移除，无需阻断取消操作。
      }
    }
  }
}

export async function pauseDownload(taskId: string) {
  const state = tasks.get(taskId);
  if (!state?.child?.pid) return false;
  state.paused = true;
  try {
    await setProcessPaused(state.child.pid, true);
    return true;
  } catch (error) {
    state.paused = false;
    throw error;
  }
}

export async function resumeDownload(taskId: string) {
  const state = tasks.get(taskId);
  if (!state?.child?.pid || !state.paused) return false;
  await setProcessPaused(state.child.pid, false);
  state.paused = false;
  return true;
}

export async function downloadCover(metadata: VideoMetadata, downloadDirectoryPath?: string) {
  if (!metadata.coverUrl) throw new Error("当前作品没有可下载封面");
  const directory = downloadDirectoryPath?.trim() || defaultDownloadsDirectory();
  fs.mkdirSync(directory, { recursive: true });
  if (metadata.coverUrl.startsWith("data:")) {
    const match = metadata.coverUrl.match(/^data:([^;,]+)?(;base64)?,(.*)$/s);
    if (!match) throw new Error("封面数据格式不正确");
    const extension = match[1]?.includes("png") ? "png" : match[1]?.includes("webp") ? "webp" : match[1]?.includes("gif") ? "gif" : "jpg";
    const base = uniqueBasePath(directory, `${metadata.suggestedFilename ?? metadata.title} - 封面`, [extension]);
    const savedPath = `${base}.${extension}`;
    fs.writeFileSync(savedPath, match[2] ? Buffer.from(match[3], "base64") : Buffer.from(decodeURIComponent(match[3]), "utf8"));
    return { savedPath };
  }
  const response = await net.fetch(metadata.coverUrl, {
    redirect: "follow",
    headers: { "User-Agent": BROWSER_USER_AGENT, Referer: metadata.normalizedUrl },
  });
  if (!response.ok) throw new Error(`封面下载失败：HTTP ${response.status}`);
  const contentType = response.headers.get("content-type") ?? "";
  const extension = contentType.includes("png") ? "png" : contentType.includes("webp") ? "webp" : contentType.includes("gif") ? "gif" : "jpg";
  const base = uniqueBasePath(directory, `${metadata.suggestedFilename ?? metadata.title} - 封面`, [extension]);
  const savedPath = `${base}.${extension}`;
  fs.writeFileSync(savedPath, Buffer.from(await response.arrayBuffer()));
  return { savedPath };
}
