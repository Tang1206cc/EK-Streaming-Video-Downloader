import { createMockAdapter } from "./mockAdapterFactory";

export const douyinAdapter = createMockAdapter("douyin", (url) => {
  const host = new URL(url).hostname.toLowerCase();
  return host.includes("douyin.com") || host.includes("iesdouyin.com");
});
