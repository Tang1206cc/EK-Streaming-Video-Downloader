import { describe, expect, it } from "vitest";
import { runProcess } from "../electron/services/processRunner.js";

describe("download process watchdog", () => {
  it("terminates a process that stops producing output", async () => {
    await expect(runProcess(
      process.execPath,
      ["-e", "setInterval(() => {}, 1000)"],
      { stallTimeoutMs: 100 },
    )).rejects.toThrow("下载长时间没有收到新数据");
  });

  it("does not count paused time as a stall", async () => {
    const result = await runProcess(
      process.execPath,
      ["-e", "setTimeout(() => process.exit(0), 180)"],
      { timeoutMs: 50, stallTimeoutMs: 50, isPaused: () => true },
    );

    expect(result.exitCode).toBe(0);
  });
});
