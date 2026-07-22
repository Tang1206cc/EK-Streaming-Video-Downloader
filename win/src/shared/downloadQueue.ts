import type { DownloadStatus } from "./types";

export type PersistedQueueStatus = DownloadStatus | "queued" | "paused";

export type RestorableDownloadTask = {
  status: PersistedQueueStatus;
  progress: number;
  message: string;
  controlPending?: boolean;
};

export function restoreDownloadTaskAfterRestart<T extends RestorableDownloadTask>(task: T): T {
  if (task.status === "completed" || task.status === "failed") {
    return { ...task, controlPending: false };
  }

  return {
    ...task,
    status: "paused",
    progress: Math.max(0, Math.min(99, Number(task.progress) || 0)),
    message: "上次退出时中断，可重新开始",
    controlPending: false,
  };
}
