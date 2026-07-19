import { createMockAdapter } from "./mockAdapterFactory";

export const wechatChannelsAdapter = createMockAdapter("wechatChannels", (url) => {
  const parsedUrl = new URL(url);
  const host = parsedUrl.hostname.toLowerCase();
  const weixinShareId = parsedUrl.pathname.split("/").filter(Boolean)[1]?.trim();
  const channelsShareId = parsedUrl.searchParams.get("id")?.trim();
  return (
    (host === "weixin.qq.com" && parsedUrl.pathname.startsWith("/sph/") && Boolean(weixinShareId)) ||
    (host === "channels.weixin.qq.com" &&
      parsedUrl.pathname === "/finder-preview/pages/sph" &&
      Boolean(channelsShareId))
  );
});
