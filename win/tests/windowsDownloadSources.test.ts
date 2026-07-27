import { describe, expect, it } from "vitest";
import { windowsDownloadCandidates } from "../electron/services/windowsDownloadSources.js";

describe("Windows environment download sources", () => {
  it("keeps the official GitHub release URL first and adds verified fallback transports", () => {
    const official = "https://github.com/yt-dlp/yt-dlp/releases/download/2026.07.04/yt-dlp.exe";
    const candidates = windowsDownloadCandidates(official);

    expect(candidates[0]).toBe(official);
    expect(candidates).toEqual([
      official,
      `https://gh-proxy.com/${official}`,
      `https://ghproxy.net/${official}`,
      `https://ghfast.top/${official}`,
    ]);
  });

  it("does not proxy unrelated or non-HTTPS URLs", () => {
    expect(windowsDownloadCandidates("https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"))
      .toEqual(["https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest"]);
    expect(windowsDownloadCandidates("http://github.com/yt-dlp/yt-dlp/releases/download/v1/file.exe"))
      .toEqual(["http://github.com/yt-dlp/yt-dlp/releases/download/v1/file.exe"]);
  });
});
