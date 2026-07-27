const GITHUB_RELEASE_MIRRORS = [
  "https://gh-proxy.com/",
  "https://ghproxy.net/",
  "https://ghfast.top/",
] as const;

export function windowsDownloadCandidates(url: string) {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return [url];
  }
  if (parsed.protocol !== "https:" || parsed.hostname !== "github.com" || !parsed.pathname.includes("/releases/")) {
    return [url];
  }
  return [url, ...GITHUB_RELEASE_MIRRORS.map((mirror) => `${mirror}${url}`)];
}
