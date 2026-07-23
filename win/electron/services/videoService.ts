import type { ChildProcessWithoutNullStreams } from "node:child_process";
import { net } from "electron";
import crypto from "node:crypto";
import fs from "node:fs";
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
  cancelled: boolean;
  paused: boolean;
  trackedPrefixes: Set<string>;
};

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
  if (host === "xiaohongshu.com" || host.endsWith(".xiaohongshu.com") || host === "xhslink.com" || host.endsWith(".xhslink.com")) return "xiaohongshu";
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
  });
  if (!response.ok) throw new Error("下载失败：微信视频号播放接口暂时不可用");
  const value = await response.json() as any;
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
  tasks.set(taskId, { cancelled: false, paused: false, trackedPrefixes: new Set() });
  try {
    let savedPath: string;
    if (metadata.platform === "wechatChannels") {
      savedPath = await downloadWeChat(metadata, directory, mode, taskId, progress);
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
  terminateProcessTree(state.child);
  if (deletePartialFiles) {
    for (const prefix of state.trackedPrefixes) {
      const directory = path.dirname(prefix);
      const name = path.basename(prefix);
      if (!fs.existsSync(directory)) continue;
      for (const entry of fs.readdirSync(directory)) {
        if (entry !== name && !entry.startsWith(`${name}.`)) continue;
        const target = path.join(directory, entry);
        if (fs.lstatSync(target).isFile()) fs.unlinkSync(target);
      }
    }
  }
  appendDiagnostic("下载", deletePartialFiles ? "任务已取消，临时文件已清理" : "任务已取消，临时文件已保留");
  return true;
}

export async function pauseDownload(taskId: string) {
  const state = tasks.get(taskId);
  if (!state?.child?.pid) return false;
  await setProcessPaused(state.child.pid, true);
  state.paused = true;
  return true;
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
