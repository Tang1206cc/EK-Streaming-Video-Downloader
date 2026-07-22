import { createMockAdapter } from "./mockAdapterFactory";

export const xiaohongshuAdapter = createMockAdapter("xiaohongshu", (url) => {
  const host = new URL(url).hostname.toLowerCase();
  return host.includes("xiaohongshu.com") || host.includes("xhslink.com");
});
