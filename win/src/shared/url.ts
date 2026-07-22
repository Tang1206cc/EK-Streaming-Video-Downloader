import type { SupportedPlatform } from "./types";

const URL_PATTERN = /https?:\/\/[^\s"'<>，。、“”‘’）)]+/i;

const PLATFORM_HOSTS: Record<SupportedPlatform, string[]> = {
  bilibili: ["b23.tv", "bilibili.com", "www.bilibili.com", "m.bilibili.com"],
  douyin: ["douyin.com", "www.douyin.com", "v.douyin.com", "iesdouyin.com"],
  kuaishou: [
    "kuaishou.com",
    "www.kuaishou.com",
    "v.kuaishou.com",
    "kwai.com",
    "www.kwai.com",
    "chenzhongtech.com",
  ],
  xiaohongshu: ["xiaohongshu.com", "www.xiaohongshu.com", "xhslink.com", "www.xhslink.com"],
  toutiao: ["toutiao.com", "www.toutiao.com", "m.toutiao.com"],
  wechatChannels: [],
};

export function extractUrlFromText(input: string): string | null {
  const match = input.match(URL_PATTERN);
  return match ? match[0] : null;
}

export function normalizeUrl(rawUrl: string): string {
  const url = new URL(rawUrl.trim());
  url.hash = "";
  return url.toString();
}

export function detectPlatform(rawUrl: string): SupportedPlatform | null {
  const url = new URL(rawUrl);
  const host = url.hostname.toLowerCase();
  const weixinShareId = url.pathname.split("/").filter(Boolean)[1]?.trim();
  const channelsShareId = url.searchParams.get("id")?.trim();
  if (
    (host === "weixin.qq.com" && url.pathname.startsWith("/sph/") && Boolean(weixinShareId)) ||
    (host === "channels.weixin.qq.com" &&
      url.pathname === "/finder-preview/pages/sph" &&
      Boolean(channelsShareId))
  ) {
    return "wechatChannels";
  }
  const platform = Object.entries(PLATFORM_HOSTS).find(([, hosts]) =>
    hosts.some((knownHost) => host === knownHost || host.endsWith(`.${knownHost}`)),
  );

  return platform ? (platform[0] as SupportedPlatform) : null;
}

export function getPlatformName(platform: SupportedPlatform): string {
  const names: Record<SupportedPlatform, string> = {
    bilibili: "哔哩哔哩",
    douyin: "抖音",
    kuaishou: "快手",
    xiaohongshu: "小红书",
    toutiao: "今日头条",
    wechatChannels: "微信视频号",
  };

  return names[platform];
}
