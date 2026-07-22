import { createMockAdapter } from "./mockAdapterFactory";

export const toutiaoAdapter = createMockAdapter("toutiao", (url) => {
  const host = new URL(url).hostname.toLowerCase();
  return host.includes("toutiao.com");
});
