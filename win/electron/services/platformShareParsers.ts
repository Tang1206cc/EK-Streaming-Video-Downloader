import crypto from "node:crypto";
import type { QualityOption } from "../bridgeTypes.js";

export type DirectShareProfile = {
  id: string;
  resolvedUrl: string;
  title: string;
  author: string;
  publishedAt: string;
  durationSeconds?: number;
  coverUrl: string;
  qualities: QualityOption[];
  sizeBytes?: number;
  mediaUrl?: string;
  imageUrls?: string[];
  audioUrl?: string;
  kind: "video" | "image-post";
};

export type ToutiaoPageProfile = {
  id: string;
  title: string;
  author: string;
  publishedAt: string;
  durationSeconds?: number;
  coverUrl: string;
  playQuery: string;
};

type JsonObject = Record<string, any>;

function nonEmpty(value: unknown) {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function positiveNumber(value: unknown) {
  const parsed = typeof value === "number" ? value : Number(value);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : undefined;
}

function durationSeconds(value: unknown) {
  const parsed = positiveNumber(value);
  if (!parsed) return undefined;
  return parsed > 1000 ? parsed / 1000 : parsed;
}

function timestampDate(value: unknown) {
  const parsed = positiveNumber(value);
  if (!parsed) return "未知日期";
  const milliseconds = parsed > 10_000_000_000 ? parsed : parsed * 1000;
  return new Date(milliseconds).toISOString().slice(0, 10);
}

function firstUrl(value: unknown): string | undefined {
  if (Array.isArray(value)) {
    return value.map(firstUrl).find(Boolean);
  }
  if (typeof value === "object" && value) {
    const item = value as JsonObject;
    return firstUrl(item.url) ?? firstUrl(item.url_list) ?? firstUrl(item.backupUrl) ?? firstUrl(item.backup_url);
  }
  const candidate = nonEmpty(value);
  if (!candidate) return undefined;
  try {
    const url = new URL(candidate.startsWith("//") ? `https:${candidate}` : candidate);
    return url.protocol === "http:" || url.protocol === "https:" ? url.toString() : undefined;
  } catch {
    return undefined;
  }
}

function titleFromDescription(value: unknown) {
  const raw = nonEmpty(value) ?? "未命名视频";
  const firstLine = raw.split(/\r?\n/).map((line) => line.trim()).find(Boolean) ?? raw;
  return firstLine.slice(0, 80);
}

function jsonAssignment(html: string, expression: RegExp) {
  const match = html.match(expression);
  if (!match?.[1]) return null;
  try {
    return JSON.parse(match[1]) as JsonObject;
  } catch {
    return null;
  }
}

function douyinNoWatermarkUrl(playAddress: JsonObject | undefined) {
  const videoId = nonEmpty(playAddress?.uri);
  if (videoId && !/^https?:/i.test(videoId)) {
    return `https://aweme.snssdk.com/aweme/v1/play/?video_id=${encodeURIComponent(videoId)}&ratio=720p&line=0`;
  }
  const url = firstUrl(playAddress?.url_list);
  return url?.replace("/playwm/", "/play/");
}

export function parseDouyinSharePage(
  html: string,
  resolvedUrl: string,
): DirectShareProfile | null {
  const router = jsonAssignment(
    html,
    /window\._ROUTER_DATA\s*=\s*(\{.*?\})\s*<\/script>/s,
  );
  const page = router?.loaderData?.["video_(id)/page"] ?? router?.loaderData?.["note_(id)/page"];
  const item = page?.videoInfoRes?.item_list?.[0] as JsonObject | undefined;
  const id = nonEmpty(item?.aweme_id);
  if (!id) return null;

  const imageUrls = (item?.images ?? [])
    .map((image: JsonObject) => firstUrl(image?.url_list) ?? firstUrl(image?.download_url_list))
    .filter(Boolean) as string[];
  const isImagePost = imageUrls.length > 0;
  const playAddress = item?.video?.play_addr as JsonObject | undefined;
  const mediaUrl = isImagePost ? undefined : douyinNoWatermarkUrl(playAddress);
  const audioUrl = isImagePost
    ? firstUrl(playAddress?.uri) ?? firstUrl(playAddress?.url_list)
    : undefined;
  if (!mediaUrl && !imageUrls.length) return null;

  const coverUrl = firstUrl(item?.video?.cover?.url_list) ?? imageUrls[0] ?? "";
  const duration = durationSeconds(isImagePost ? item?.music?.duration : item?.video?.duration);
  const canonical = `https://www.douyin.com/${isImagePost ? "note" : "video"}/${id}`;
  return {
    id,
    resolvedUrl: canonical || resolvedUrl,
    title: titleFromDescription(item?.desc),
    author: nonEmpty(item?.author?.nickname) ?? "未知作者",
    publishedAt: timestampDate(item?.create_time),
    durationSeconds: duration,
    coverUrl,
    qualities: [{
      id: isImagePost ? "note-share-page" : "no-watermark-share-page",
      label: isImagePost ? "图文作品" : "无水印播放流",
      description: isImagePost ? "解析信息来自抖音图文分享页" : "解析信息来自抖音移动分享页",
      available: true,
    }],
    sizeBytes: positiveNumber(playAddress?.data_size),
    mediaUrl,
    imageUrls: imageUrls.length ? imageUrls : undefined,
    audioUrl,
    kind: isImagePost ? "image-post" : "video",
  };
}

function kuaishouPhoto(state: JsonObject, resolvedUrl: string) {
  const photos = Object.values(state)
    .map((page: any) => page?.photo)
    .filter(Boolean) as JsonObject[];
  if (!photos.length) return undefined;
  const url = new URL(resolvedUrl);
  const preferredId = url.searchParams.get("photoId")
    ?? url.pathname.split("/").filter(Boolean).at(-1);
  return photos.find((photo) =>
    nonEmpty(photo.photoId) === preferredId
    || nonEmpty(photo.share_info)?.includes(`photoId=${preferredId}`),
  ) ?? photos[0];
}

function kuaishouRepresentations(photo: JsonObject) {
  return (photo?.manifest?.adaptationSet ?? [])
    .flatMap((set: JsonObject) => set?.representation ?? [])
    .filter((item: JsonObject) => firstUrl(item?.url) ?? firstUrl(item?.backupUrl)) as JsonObject[];
}

function representationScore(item: JsonObject) {
  return [
    positiveNumber(item.height) ?? 0,
    positiveNumber(item.width) ?? 0,
    positiveNumber(item.avgBitrate) ?? 0,
    positiveNumber(item.fileSize) ?? 0,
  ];
}

function compareScore(left: JsonObject, right: JsonObject) {
  const a = representationScore(left);
  const b = representationScore(right);
  for (let index = 0; index < a.length; index += 1) {
    if (a[index] !== b[index]) return b[index] - a[index];
  }
  return 0;
}

export function parseKuaishouSharePage(
  html: string,
  resolvedUrl: string,
): DirectShareProfile | null {
  const state = jsonAssignment(
    html,
    /window\.INIT_STATE\s*=\s*(\{.*?\})\s*<\/script>/s,
  );
  if (!state) return null;
  const photo = kuaishouPhoto(state, resolvedUrl);
  if (!photo) return null;
  const representations = kuaishouRepresentations(photo).sort(compareScore);
  const best = representations[0];
  const mediaUrl = firstUrl(best?.url)
    ?? firstUrl(best?.backupUrl)
    ?? firstUrl(photo?.mainMvUrls);
  if (!mediaUrl) return null;

  const qualities = representations.slice(0, 6).map((item, index) => {
    const height = positiveNumber(item.height);
    const label = nonEmpty(item.qualityLabel)
      ?? nonEmpty(item.qualityType)
      ?? (height ? `${height}p` : "可下载格式");
    const size = positiveNumber(item.fileSize);
    return {
      id: String(item.id ?? `${label}-${index}`),
      label,
      description: [
        nonEmpty(item.videoCodec) ?? "mp4",
        size ? `约 ${(size / 1_048_576).toFixed(1)} MB` : "大小未知",
      ].join(" · "),
      available: true,
    };
  });

  const id = nonEmpty(photo.photoId)
    ?? new URL(resolvedUrl).searchParams.get("photoId")
    ?? crypto.randomUUID();
  return {
    id,
    resolvedUrl,
    title: titleFromDescription(photo.caption),
    author: nonEmpty(photo.userName) ?? "未知作者",
    publishedAt: timestampDate(photo.timestamp),
    durationSeconds: durationSeconds(
      photo.duration ?? photo?.manifest?.adaptationSet?.find((set: JsonObject) => positiveNumber(set?.duration))?.duration,
    ),
    coverUrl: firstUrl(photo.coverUrls) ?? firstUrl(photo.webpCoverUrls) ?? "",
    qualities: qualities.length ? qualities : [{
      id: "share-page",
      label: "公开视频信息",
      description: "解析信息来自快手分享页",
      available: true,
    }],
    sizeBytes: positiveNumber(best?.fileSize),
    mediaUrl,
    kind: "video",
  };
}

export function parseToutiaoSharePage(html: string): ToutiaoPageProfile | null {
  const match = html.match(/<script[^>]*id=["']RENDER_DATA["'][^>]*>(.*?)<\/script>/s);
  if (!match?.[1]) return null;
  let root: JsonObject;
  try {
    root = JSON.parse(decodeURIComponent(match[1])) as JsonObject;
  } catch {
    return null;
  }
  const article = root.articleInfo as JsonObject | undefined;
  const token = nonEmpty(article?.playAuthTokenV2);
  if (!article || !token) return null;
  let playQuery: string | undefined;
  try {
    const decoded = JSON.parse(Buffer.from(token, "base64").toString("utf8")) as JsonObject;
    playQuery = nonEmpty(decoded.GetPlayInfoToken);
  } catch {
    return null;
  }
  if (!playQuery) return null;
  return {
    id: nonEmpty(article.gid) ?? nonEmpty(article.videoId) ?? crypto.randomUUID(),
    title: titleFromDescription(article.title),
    author: nonEmpty(article?.mediaUser?.screenName)
      ?? nonEmpty(article.detailSource)
      ?? "未知作者",
    publishedAt: timestampDate(article.publishTime),
    durationSeconds: durationSeconds(article.videoDuration),
    coverUrl: firstUrl(article.posterUrl) ?? "",
    playQuery,
  };
}

export function parseToutiaoVodProfile(
  value: JsonObject,
  page: ToutiaoPageProfile,
  resolvedUrl: string,
): DirectShareProfile | null {
  const data = value?.Result?.Data as JsonObject | undefined;
  if (!data || Number(data.Status) !== 10) return null;
  const formats = (data.PlayInfoList ?? [])
    .filter((item: JsonObject) => firstUrl(item.MainPlayUrl) ?? firstUrl(item.BackupPlayUrl))
    .sort((left: JsonObject, right: JsonObject) => {
      const a = [positiveNumber(left.Height) ?? 0, positiveNumber(left.Bitrate) ?? 0];
      const b = [positiveNumber(right.Height) ?? 0, positiveNumber(right.Bitrate) ?? 0];
      return b[0] - a[0] || b[1] - a[1];
    }) as JsonObject[];
  const selected = formats[0];
  const mediaUrl = firstUrl(selected?.MainPlayUrl) ?? firstUrl(selected?.BackupPlayUrl);
  if (!mediaUrl) return null;
  return {
    id: page.id,
    resolvedUrl,
    title: page.title,
    author: page.author,
    publishedAt: page.publishedAt,
    durationSeconds: durationSeconds(selected?.Duration ?? data.Duration) ?? page.durationSeconds,
    coverUrl: firstUrl(data.CoverUrl) ?? page.coverUrl,
    qualities: formats.slice(0, 6).map((item, index) => {
      const label = nonEmpty(item.Definition)
        ?? (positiveNumber(item.Height) ? `${positiveNumber(item.Height)}p` : "可下载格式");
      const size = positiveNumber(item.Size);
      return {
        id: `toutiao-${index}-${label}`,
        label,
        description: [
          positiveNumber(item.Width) && positiveNumber(item.Height)
            ? `${positiveNumber(item.Width)}x${positiveNumber(item.Height)}`
            : undefined,
          nonEmpty(item.Codec),
          size ? `约 ${(size / 1_048_576).toFixed(1)} MB` : "大小未知",
        ].filter(Boolean).join(" · "),
        available: true,
      };
    }),
    sizeBytes: positiveNumber(selected?.Size),
    mediaUrl,
    kind: "video",
  };
}
