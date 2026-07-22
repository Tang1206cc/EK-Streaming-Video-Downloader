import { describe, expect, it } from "vitest";
import {
  checksumForFile,
  isNewerVersion,
  parseReleaseVersion,
  windowsReleaseAssetName,
} from "../electron/services/releaseContract";

describe("Windows Release contract", () => {
  it("accepts v-prefixed semantic release tags", () => {
    expect(parseReleaseVersion("V0.9.0")).toEqual([0, 9, 0]);
    expect(parseReleaseVersion("0.9.0")).toEqual([0, 9, 0]);
    expect(parseReleaseVersion("release-0.9.0")).toBeNull();
  });

  it("compares versions component by component", () => {
    expect(isNewerVersion([0, 10, 0], [0, 9, 9])).toBe(true);
    expect(isNewerVersion([0, 9, 0], [0, 9, 0])).toBe(false);
    expect(isNewerVersion([0, 8, 9], [0, 9, 0])).toBe(false);
  });

  it("keeps the exact updater asset filename", () => {
    expect(windowsReleaseAssetName("0.9.0")).toBe("windows-x64-EK StreamDL-0.9.0.zip");
  });

  it("reads GNU-style SHA-256 lists without weakening the filename match", () => {
    const digest = "a".repeat(64);
    expect(checksumForFile(`${digest} *yt-dlp.exe\n`, "yt-dlp.exe")).toBe(digest);
    expect(() => checksumForFile(`${digest} *yt-dlp_arm64.exe\n`, "yt-dlp.exe")).toThrow();
  });
});
