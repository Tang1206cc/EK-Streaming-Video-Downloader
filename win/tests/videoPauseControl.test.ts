import { EventEmitter } from "node:events";
import { beforeEach, describe, expect, it, vi } from "vitest";
import type { VideoMetadata } from "../electron/bridgeTypes.js";

const processHarness = vi.hoisted(() => ({
  options: undefined as { onSpawn?: (child: unknown) => void } | undefined,
  resolve: undefined as ((value: { exitCode: number; stdout: string; stderr: string }) => void) | undefined,
  setProcessPaused: vi.fn(async () => undefined),
}));

vi.mock("electron", () => ({ net: {} }));
vi.mock("../electron/services/diagnostics.js", () => ({ appendDiagnostic: vi.fn() }));
vi.mock("../electron/services/paths.js", () => ({
  defaultDownloadsDirectory: () => "/tmp",
  resolveFfmpegPath: () => "ffmpeg",
  resolveYtDlpPath: () => "yt-dlp",
  safeFilename: (value: string) => value,
  uniqueBasePath: () => "/tmp/ek-streamdl-pause-test",
}));
vi.mock("../electron/services/wechatAuthorization.js", () => ({
  BROWSER_USER_AGENT: "EK StreamDL Test",
  weChatAuthorization: {},
}));
vi.mock("../electron/services/processRunner.js", () => ({
  runProcess: vi.fn((_executable: string, _args: string[], options: { onSpawn?: (child: unknown) => void }) =>
    new Promise((resolve) => {
      processHarness.options = options;
      processHarness.resolve = resolve;
    })),
  setProcessPaused: processHarness.setProcessPaused,
  terminateProcessTree: vi.fn(),
}));

import {
  downloadVideo,
  pauseDownload,
  resumeDownload,
} from "../electron/services/videoService.js";

const metadata: VideoMetadata = {
  id: "test",
  originalUrl: "https://www.bilibili.com/video/BV1test",
  normalizedUrl: "https://www.bilibili.com/video/BV1test",
  platform: "bilibili",
  platformName: "哔哩哔哩",
  title: "暂停测试",
  author: "EK StreamDL",
  publishedAt: "",
  duration: "00:10",
  coverUrl: "",
  qualities: [],
  parseMode: "real",
  note: "",
};

function finishDownload() {
  processHarness.resolve?.({ exitCode: 0, stdout: "", stderr: "" });
}

describe("Windows deferred download pause", () => {
  beforeEach(() => {
    processHarness.options = undefined;
    processHarness.resolve = undefined;
    processHarness.setProcessPaused.mockClear();
  });

  it("accepts pause before a child process exists and pauses it when spawned", async () => {
    const download = downloadVideo(metadata, undefined, "complete", "deferred-pause", () => undefined);

    await expect(pauseDownload("deferred-pause")).resolves.toBe(true);
    expect(processHarness.setProcessPaused).not.toHaveBeenCalled();

    const child = Object.assign(new EventEmitter(), { pid: 4321, killed: false });
    processHarness.options?.onSpawn?.(child);
    await vi.waitFor(() => {
      expect(processHarness.setProcessPaused).toHaveBeenCalledWith(4321, true);
    });

    finishDownload();
    await expect(download).resolves.toEqual({ savedPath: "/tmp/ek-streamdl-pause-test.mp4" });
  });

  it("clears a deferred pause without suspending the later child process", async () => {
    const download = downloadVideo(metadata, undefined, "complete", "deferred-resume", () => undefined);

    await expect(pauseDownload("deferred-resume")).resolves.toBe(true);
    await expect(resumeDownload("deferred-resume")).resolves.toBe(true);

    const child = Object.assign(new EventEmitter(), { pid: 4322, killed: false });
    processHarness.options?.onSpawn?.(child);
    await Promise.resolve();
    expect(processHarness.setProcessPaused).not.toHaveBeenCalled();

    finishDownload();
    await expect(download).resolves.toEqual({ savedPath: "/tmp/ek-streamdl-pause-test.mp4" });
  });
});
