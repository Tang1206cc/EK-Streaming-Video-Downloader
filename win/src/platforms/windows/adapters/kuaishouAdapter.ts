import { createMockAdapter } from "./mockAdapterFactory";

export const kuaishouAdapter = createMockAdapter("kuaishou", (url) => {
  const host = new URL(url).hostname.toLowerCase();
  return host.includes("kuaishou.com") || host.includes("kwai.com");
});
