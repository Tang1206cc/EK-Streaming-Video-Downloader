import type { SupportedPlatform, VideoMetadata } from "../../../shared/types";
import { getPlatformName } from "../../../shared/url";
import type { PlatformAdapter } from "./types";

const COVER_BACKGROUNDS: Record<SupportedPlatform, string> = {
  bilibili: "linear-gradient(135deg, #7fd1e8 0%, #5a80d8 100%)",
  douyin: "linear-gradient(135deg, #111827 0%, #ef476f 52%, #20d3d8 100%)",
  kuaishou: "linear-gradient(135deg, #ffb15c 0%, #f45b35 100%)",
  xiaohongshu: "linear-gradient(135deg, #ff6b7d 0%, #d92336 100%)",
  toutiao: "linear-gradient(135deg, #f43f3b 0%, #2563eb 100%)",
  wechatChannels: "linear-gradient(135deg, #20c56d 0%, #1677ff 100%)",
};

export function createMockAdapter(platform: SupportedPlatform, matcher: (url: string) => boolean): PlatformAdapter {
  return {
    match: matcher,
    async parse(url) {
      const parsedUrl = new URL(url);
      const platformName = getPlatformName(platform);
      const titleHint = decodeURIComponent(parsedUrl.pathname.split("/").filter(Boolean).at(-1) ?? "分享视频");

      await delay(520);

      return {
        id: `${platform}-${Date.now()}`,
        originalUrl: url,
        normalizedUrl: url,
        platform,
        platformName,
        title: `${platformName}链接解析预览：${titleHint}`,
        author: "待真实解析获取",
        publishedAt: "待真实解析获取",
        duration: "待真实解析获取",
        coverUrl: buildCoverDataUrl(platformName, COVER_BACKGROUNDS[platform]),
        qualities: [
          {
            id: "source",
            label: "原始清晰度",
            description: "预留选项，接入真实解析后显示可下载格式",
            available: false,
          },
        ],
        parseMode: "mock",
        note: "首版已完成链接提取、平台识别和下载状态闭环；真实视频信息与文件下载需后续接入平台解析或 yt-dlp。",
      };
    },
    async download(_metadata, onProgress) {
      onProgress({ status: "preparing", progress: 3, message: "准备下载" });
      await delay(420);

      for (let progress = 10; progress <= 100; progress += 10) {
        onProgress({
          status: progress === 100 ? "completed" : "downloading",
          progress,
          message: progress === 100 ? "已完成" : "下载中",
        });
        await delay(180);
      }
    },
  };
}

function buildCoverDataUrl(platformName: string, background: string): string {
  const svg = `
    <svg xmlns="http://www.w3.org/2000/svg" width="640" height="360" viewBox="0 0 640 360">
      <defs><style>.t{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-weight:700;}</style></defs>
      <rect width="640" height="360" fill="#1f2937"/>
      <foreignObject width="640" height="360">
        <div xmlns="http://www.w3.org/1999/xhtml" style="width:640px;height:360px;background:${background};display:flex;align-items:center;justify-content:center;color:white;">
          <div style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;font-size:44px;font-weight:700;">${platformName}</div>
        </div>
      </foreignObject>
    </svg>
  `;

  return `data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`;
}

function delay(ms: number) {
  return new Promise((resolve) => window.setTimeout(resolve, ms));
}
