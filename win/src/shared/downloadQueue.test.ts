import { describe, expect, it } from "vitest";
import { restoreDownloadTaskAfterRestart, type RestorableDownloadTask } from "./downloadQueue";

function task(status: RestorableDownloadTask["status"], progress: number): RestorableDownloadTask {
  return { status, progress, message: "原状态", controlPending: true };
}

describe("restoreDownloadTaskAfterRestart", () => {
  it.each(["idle", "queued", "preparing", "downloading", "paused"] as const)(
    "restores an interrupted %s task as resumable",
    (status) => {
      expect(restoreDownloadTaskAfterRestart(task(status, 42))).toEqual({
        status: "paused",
        progress: 42,
        message: "上次退出时中断，可重新开始",
        controlPending: false,
      });
    },
  );

  it("caps interrupted progress below completion", () => {
    expect(restoreDownloadTaskAfterRestart(task("downloading", 100)).progress).toBe(99);
    expect(restoreDownloadTaskAfterRestart(task("downloading", -8)).progress).toBe(0);
  });

  it.each(["completed", "failed"] as const)("preserves terminal %s tasks", (status) => {
    expect(restoreDownloadTaskAfterRestart(task(status, 100))).toEqual({
      status,
      progress: 100,
      message: "原状态",
      controlPending: false,
    });
  });
});
