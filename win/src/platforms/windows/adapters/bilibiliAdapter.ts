import { createMockAdapter } from "./mockAdapterFactory";

export const bilibiliAdapter = createMockAdapter("bilibili", (url) => {
  const host = new URL(url).hostname.toLowerCase();
  return host.includes("bilibili.com") || host === "b23.tv";
});
