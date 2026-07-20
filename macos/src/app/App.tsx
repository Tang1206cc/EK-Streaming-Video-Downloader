import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type {
  DownloadMode,
  DownloadProgressEvent,
  DownloadStatus,
  DownloadTask,
  RuntimeEnvironmentComponent,
  RuntimeEnvironmentProgressEvent,
  RuntimeEnvironmentReport,
  VideoCollectionItem,
  VideoMetadata,
} from "../shared/types";
import {
  cancelDownload,
  checkRuntimeEnvironment,
  clearWeChatAuthorization,
  downloadCover,
  downloadVideo,
  exportDiagnosticReport,
  getWeChatAuthorizationStatus,
  installRuntimeEnvironment,
  openPreferences,
  parseVideo,
  pauseDownload,
  playCompletionSound,
  resumeDownload,
  selectDownloadDirectory,
} from "../shared/videoService";
import { restoreDownloadTaskAfterRestart } from "../shared/downloadQueue";

const EXAMPLE_TEXT = "【【MrBeast官方】30天不吃饭挑战，坚持不住我就剃光头！-哔哩哔哩】 https://b23.tv/sKNRYNe";
const SUPPORTED_PLATFORM_NAMES = ["哔哩哔哩", "抖音", "快手", "小红书", "今日头条", "微信视频号"];
const DOWNLOAD_MODE_OPTIONS: Array<{ id: DownloadMode; shortLabel: string; label: string }> = [
  { id: "complete", shortLabel: "完整", label: "完整视频" },
  { id: "audio", shortLabel: "音频", label: "仅音频" },
  { id: "video", shortLabel: "视频", label: "仅视频" },
  { id: "separate", shortLabel: "分开", label: "音视频分开" },
];
const MAX_PARALLEL_DOWNLOADS = 2;
const DOWNLOAD_STATE_STORAGE_KEY = "ek-streamdl-downloader-state-v1";

type DownloadListTab = "active" | "completed";
type WeChatAuthorizationState = "checking" | "authorized" | "unauthorized";
type ManagedDownloadStatus = DownloadStatus | "queued" | "paused";
type ManagedDownloadTask = Omit<DownloadTask, "status"> & {
  status: ManagedDownloadStatus;
  downloadMode: DownloadMode;
  downloadDirectoryPath?: string;
  createdAt: number;
  savedPath?: string;
  controlPending?: boolean;
};

type PersistedDownloadState = {
  tasks: ManagedDownloadTask[];
  downloadDirectoryPath: string | null;
  downloadMode: DownloadMode;
  isDownloadSoundEnabled: boolean;
};

function loadPersistedDownloadState(): PersistedDownloadState {
  const fallback: PersistedDownloadState = {
    tasks: [],
    downloadDirectoryPath: null,
    downloadMode: "complete",
    isDownloadSoundEnabled: true,
  };
  try {
    const serializedState = window.localStorage.getItem(DOWNLOAD_STATE_STORAGE_KEY);
    if (!serializedState) {
      return fallback;
    }
    const parsedState = JSON.parse(serializedState) as Partial<PersistedDownloadState>;
    const tasks = Array.isArray(parsedState.tasks)
      ? parsedState.tasks
          .filter((task): task is ManagedDownloadTask => Boolean(task?.id && task?.metadata?.id))
          .map(restoreDownloadTaskAfterRestart)
      : [];
    const persistedMode = DOWNLOAD_MODE_OPTIONS.some((option) => option.id === parsedState.downloadMode)
      ? parsedState.downloadMode
      : "complete";
    return {
      tasks,
      downloadDirectoryPath:
        typeof parsedState.downloadDirectoryPath === "string" ? parsedState.downloadDirectoryPath : null,
      downloadMode: persistedMode ?? "complete",
      isDownloadSoundEnabled: parsedState.isDownloadSoundEnabled !== false,
    };
  } catch {
    return fallback;
  }
}

function savePersistedDownloadState(state: PersistedDownloadState) {
  try {
    window.localStorage.setItem(DOWNLOAD_STATE_STORAGE_KEY, JSON.stringify(state));
  } catch {
    // Local persistence is best effort and must never block downloading.
  }
}

export function App() {
  return <VideoDownloader />;
}

function SettingsGearIcon() {
  return (
    <svg viewBox="0 0 24 24" aria-hidden="true">
      <path d="M9.5 3.4h5l.6 2.1c.5.2 1 .5 1.5.9l2.1-.6 2.5 4.3-1.5 1.6v1.8l1.5 1.6-2.5 4.3-2.1-.6c-.5.4-1 .7-1.5.9l-.6 2.1h-5l-.6-2.1c-.5-.2-1-.5-1.5-.9l-2.1.6-2.5-4.3 1.5-1.6v-1.8l-1.5-1.6 2.5-4.3 2.1.6c.5-.4 1-.7 1.5-.9l.6-2.1Z" />
      <circle cx="12" cy="12.6" r="3" />
    </svg>
  );
}

function VideoDownloader() {
  const persistedState = useMemo(loadPersistedDownloadState, []);
  const [inputText, setInputText] = useState("");
  const [metadata, setMetadata] = useState<VideoMetadata | null>(null);
  const [downloadTasks, setDownloadTasks] = useState<ManagedDownloadTask[]>(persistedState.tasks);
  const [isParsing, setIsParsing] = useState(false);
  const [isOpeningSettings, setIsOpeningSettings] = useState(false);
  const [parseStageMessage, setParseStageMessage] = useState("");
  const [error, setError] = useState("");
  const [isEnvironmentModalOpen, setIsEnvironmentModalOpen] = useState(false);
  const [isSupportModalOpen, setIsSupportModalOpen] = useState(false);
  const [isAboutModalOpen, setIsAboutModalOpen] = useState(false);
  const [isDownloadListOpen, setIsDownloadListOpen] = useState(false);
  const [downloadListTab, setDownloadListTab] = useState<DownloadListTab>("active");
  const [isDownloadQueuePaused, setIsDownloadQueuePaused] = useState(false);
  const [downloadDirectoryPath, setDownloadDirectoryPath] = useState<string | null>(
    persistedState.downloadDirectoryPath,
  );
  const [downloadMode, setDownloadMode] = useState<DownloadMode>(persistedState.downloadMode);
  const [isDownloadModeMenuOpen, setIsDownloadModeMenuOpen] = useState(false);
  const [isCollectionPickerOpen, setIsCollectionPickerOpen] = useState(false);
  const [draftCollectionSelection, setDraftCollectionSelection] = useState<string[]>([]);
  const [confirmedCollectionSelection, setConfirmedCollectionSelection] = useState<string[]>([]);
  const [isCoverDownloading, setIsCoverDownloading] = useState(false);
  const [coverDownloadMessage, setCoverDownloadMessage] = useState("");
  const [isDownloadSoundEnabled, setIsDownloadSoundEnabled] = useState(persistedState.isDownloadSoundEnabled);
  const [isClearingWeChatAuthorization, setIsClearingWeChatAuthorization] = useState(false);
  const [weChatAuthorizationMessage, setWeChatAuthorizationMessage] = useState("");
  const [weChatAuthorizationState, setWeChatAuthorizationState] =
    useState<WeChatAuthorizationState>("checking");
  const weChatAuthorizationRequestRef = useRef(0);
  const activeDownloadIdsRef = useRef<Set<string>>(new Set());
  const controlIntentRef = useRef<Map<string, "delete">>(new Map());
  const downloadSoundEnabledRef = useRef(persistedState.isDownloadSoundEnabled);

  const canDownload = useMemo(() => {
    return metadata !== null && !isParsing;
  }, [isParsing, metadata]);
  const downloadDirectoryLabel = downloadDirectoryPath ?? "系统下载文件夹";
  const selectedDownloadMode =
    DOWNLOAD_MODE_OPTIONS.find((option) => option.id === downloadMode) ?? DOWNLOAD_MODE_OPTIONS[0];
  const collectionItems = metadata?.collection?.items ?? [];
  const hasCollection = collectionItems.length > 1;
  const activeDownloadCount = downloadTasks.filter((item) => item.status !== "completed").length;
  const completedDownloadCount = downloadTasks.filter((item) => item.status === "completed").length;
  const visibleTask = useMemo(() => {
    if (!metadata) {
      return null;
    }

    return [...downloadTasks].reverse().find((item) => item.metadata.id === metadata.id) ?? null;
  }, [downloadTasks, metadata]);

  const updateDownloadTask = useCallback(
    (taskId: string, updater: (task: ManagedDownloadTask) => ManagedDownloadTask) => {
      setDownloadTasks((currentTasks) =>
        currentTasks.map((currentTask) => (currentTask.id === taskId ? updater(currentTask) : currentTask)),
      );
    },
    [],
  );

  const notifyDownloadComplete = useCallback(() => {
    if (!downloadSoundEnabledRef.current) {
      return;
    }
    void playCompletionSound().catch(() => undefined);
  }, []);

  const refreshWeChatAuthorizationStatus = useCallback(async (showChecking = false) => {
    const requestIdentifier = ++weChatAuthorizationRequestRef.current;
    if (showChecking) {
      setWeChatAuthorizationState("checking");
    }
    try {
      const isAuthorized = await getWeChatAuthorizationStatus();
      if (requestIdentifier === weChatAuthorizationRequestRef.current) {
        setWeChatAuthorizationState(isAuthorized ? "authorized" : "unauthorized");
      }
    } catch {
      if (requestIdentifier === weChatAuthorizationRequestRef.current) {
        setWeChatAuthorizationState("unauthorized");
      }
    }
  }, []);

  const runManagedDownload = useCallback(
    async (queuedTask: ManagedDownloadTask) => {
      const notifiedCollectionItems = new Set<string>();
      updateDownloadTask(queuedTask.id, (currentTask) => ({
        ...currentTask,
        status: "preparing",
        progress: Math.max(currentTask.progress, 1),
        message: "准备下载",
      }));

      try {
        const result = await downloadVideo(
          queuedTask.metadata,
          queuedTask.downloadMode,
          (event: DownloadProgressEvent) => {
            const hasMediaDetails =
              Boolean(event.duration) ||
              (typeof event.estimatedSizeMb === "number" && event.estimatedSizeMb > 0);
            updateDownloadTask(queuedTask.id, (currentTask) => {
              if (currentTask.status === "paused") {
                return currentTask;
              }
              return {
                ...currentTask,
                status: event.status === "completed" ? "downloading" : event.status,
                progress: event.status === "completed" ? 99 : Math.min(event.progress, 99),
                message: event.message,
                metadata: hasMediaDetails
                  ? {
                      ...currentTask.metadata,
                      ...(event.duration ? { duration: event.duration } : {}),
                      ...(typeof event.estimatedSizeMb === "number" && event.estimatedSizeMb > 0
                        ? { estimatedSizeMb: event.estimatedSizeMb }
                        : {}),
                    }
                  : currentTask.metadata,
              };
            });
            if (hasMediaDetails) {
              setMetadata((currentMetadata) =>
                currentMetadata?.id === queuedTask.metadata.id
                  ? {
                      ...currentMetadata,
                      ...(event.duration ? { duration: event.duration } : {}),
                      ...(typeof event.estimatedSizeMb === "number" && event.estimatedSizeMb > 0
                        ? { estimatedSizeMb: event.estimatedSizeMb }
                        : {}),
                    }
                  : currentMetadata,
              );
            }
            if (queuedTask.metadata.platform === "wechatChannels" && event.weChatAuthorized === true) {
              weChatAuthorizationRequestRef.current += 1;
              setWeChatAuthorizationState("authorized");
            }
            const completedCollectionItem = event.message.match(/^第 (\d+)\/\d+ 集：已完成：/);
            if (
              completedCollectionItem &&
              !controlIntentRef.current.has(queuedTask.id) &&
              !notifiedCollectionItems.has(completedCollectionItem[1])
            ) {
              notifiedCollectionItems.add(completedCollectionItem[1]);
              notifyDownloadComplete();
            }
          },
          queuedTask.downloadDirectoryPath,
          queuedTask.id,
        );

        const completedMessage = result.savedPath ? `已完成：${result.savedPath}` : "已完成";
        activeDownloadIdsRef.current.delete(queuedTask.id);
        const controlIntent = controlIntentRef.current.get(queuedTask.id);
        if (controlIntent === "delete") {
          controlIntentRef.current.delete(queuedTask.id);
          setDownloadTasks((currentTasks) => currentTasks.filter((currentTask) => currentTask.id !== queuedTask.id));
          return;
        }
        if (notifiedCollectionItems.size === 0) {
          notifyDownloadComplete();
        }
        updateDownloadTask(queuedTask.id, (currentTask) => ({
          ...currentTask,
          status: "completed",
          progress: 100,
          message: completedMessage,
          savedPath: result.savedPath,
        }));
      } catch (caughtError) {
        const failedMessage = caughtError instanceof Error ? caughtError.message : "下载失败";
        activeDownloadIdsRef.current.delete(queuedTask.id);
        const controlIntent = controlIntentRef.current.get(queuedTask.id);
        if (controlIntent === "delete") {
          controlIntentRef.current.delete(queuedTask.id);
          setDownloadTasks((currentTasks) => currentTasks.filter((currentTask) => currentTask.id !== queuedTask.id));
          return;
        }
        updateDownloadTask(queuedTask.id, (currentTask) => ({
          ...currentTask,
          status: "failed",
          progress: Math.max(currentTask.progress, 1),
          message: failedMessage || "下载失败",
        }));
        if (queuedTask.metadata.platform === "wechatChannels") {
          void refreshWeChatAuthorizationStatus();
        }
      }
    },
    [notifyDownloadComplete, refreshWeChatAuthorizationStatus, updateDownloadTask],
  );

  useEffect(() => {
    if (metadata?.platform !== "wechatChannels") {
      weChatAuthorizationRequestRef.current += 1;
      setWeChatAuthorizationState("checking");
      setWeChatAuthorizationMessage("");
      return;
    }

    void refreshWeChatAuthorizationStatus(true);
    const intervalIdentifier = window.setInterval(() => {
      void refreshWeChatAuthorizationStatus();
    }, 3000);
    return () => window.clearInterval(intervalIdentifier);
  }, [metadata?.id, metadata?.platform, refreshWeChatAuthorizationStatus]);

  useEffect(() => {
    const timeoutIdentifier = window.setTimeout(() => {
      savePersistedDownloadState({
        tasks: downloadTasks.map(({ controlPending: _controlPending, ...task }) => task),
        downloadDirectoryPath,
        downloadMode,
        isDownloadSoundEnabled,
      });
    }, 150);
    return () => window.clearTimeout(timeoutIdentifier);
  }, [downloadDirectoryPath, downloadMode, downloadTasks, isDownloadSoundEnabled]);

  useEffect(() => {
    if (!downloadTasks.some((task) => task.status !== "completed")) {
      setIsDownloadQueuePaused(false);
    }
  }, [downloadTasks]);

  useEffect(() => {
    if (!isParsing) {
      setParseStageMessage("");
      return;
    }
    setParseStageMessage("正在识别链接");
    const accessTimer = window.setTimeout(() => setParseStageMessage("正在访问平台页面"), 800);
    const metadataTimer = window.setTimeout(() => setParseStageMessage("正在读取视频信息"), 4000);
    return () => {
      window.clearTimeout(accessTimer);
      window.clearTimeout(metadataTimer);
    };
  }, [isParsing]);

  useEffect(() => {
    if (isDownloadQueuePaused) {
      return;
    }

    const availableSlots = MAX_PARALLEL_DOWNLOADS - activeDownloadIdsRef.current.size;
    if (availableSlots <= 0) {
      return;
    }

    const nextTasks = downloadTasks
      .filter((candidate) => candidate.status === "queued" && !activeDownloadIdsRef.current.has(candidate.id))
      .slice(0, availableSlots);

    nextTasks.forEach((nextTask) => {
      activeDownloadIdsRef.current.add(nextTask.id);
      void runManagedDownload(nextTask);
    });
  }, [downloadTasks, isDownloadQueuePaused, runManagedDownload]);

  async function handleParse() {
    setError("");
    setCoverDownloadMessage("");
    setIsDownloadModeMenuOpen(false);
    setIsParsing(true);

    try {
      const result = await parseVideo(inputText);
      const initialCollectionSelection = getInitialCollectionSelection(result);
      setMetadata(result);
      setWeChatAuthorizationMessage("");
      setDraftCollectionSelection(initialCollectionSelection);
      setConfirmedCollectionSelection(initialCollectionSelection);
      setIsCollectionPickerOpen(false);
    } catch (caughtError) {
      setMetadata(null);
      setDraftCollectionSelection([]);
      setConfirmedCollectionSelection([]);
      setIsCollectionPickerOpen(false);
      setCoverDownloadMessage("");
      setError(caughtError instanceof Error ? caughtError.message : "解析失败");
    } finally {
      setIsParsing(false);
    }
  }

  async function handleDownload() {
    if (!metadata) {
      return;
    }

    setError("");
    if (metadata.platform === "wechatChannels") {
      setWeChatAuthorizationMessage("");
    }
    setIsDownloadModeMenuOpen(false);
    setIsCollectionPickerOpen(false);

    let metadataForDownload = metadata;
    if (hasCollection) {
      const selectedItems = collectionItems.filter((item) => confirmedCollectionSelection.includes(item.id));
      if (selectedItems.length === 0) {
        setError("请先选择合集视频");
        return;
      }
      metadataForDownload = {
        ...metadata,
        selectedCollectionItems: selectedItems,
      };
      if (selectedItems.length === 1) {
        const selectedItem = selectedItems[0];
        metadataForDownload = {
          ...metadataForDownload,
          title: selectedItem.title,
          coverUrl: selectedItem.coverUrl ?? metadata.coverUrl,
          duration: selectedItem.duration ?? metadata.duration,
        };
        if (metadata.platform === "bilibili") {
          try {
            const itemMetadata = await parseVideo(selectedItem.url);
            if (itemMetadata.coverUrl.trim()) {
              metadataForDownload = {
                ...metadataForDownload,
                coverUrl: itemMetadata.coverUrl,
              };
            }
          } catch {
            // Keep the existing collection cover when the single-item lookup is unavailable.
          }
        }
      }
    }

    const taskId = `task-${metadataForDownload.id}-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
    const queuedTask: ManagedDownloadTask = {
      id: taskId,
      metadata: metadataForDownload,
      status: isDownloadQueuePaused ? "paused" : "queued",
      progress: 0,
      message: isDownloadQueuePaused ? "已暂停，等待开始" : "等待下载",
      downloadMode,
      downloadDirectoryPath: downloadDirectoryPath ?? undefined,
      createdAt: Date.now(),
    };

    setDownloadTasks((currentTasks) => [...currentTasks, queuedTask]);
    setDownloadListTab("active");
  }

  async function handleDownloadCover() {
    if (!metadata || !metadata.coverUrl) {
      return;
    }

    setError("");
    setCoverDownloadMessage("");
    setIsDownloadModeMenuOpen(false);
    setIsCollectionPickerOpen(false);
    setIsCoverDownloading(true);

    try {
      const result = await downloadCover(metadata, downloadDirectoryPath ?? undefined);
      setCoverDownloadMessage(result.savedPath ? `封面已保存：${result.savedPath}` : "封面已保存");
    } catch (caughtError) {
      setCoverDownloadMessage("封面下载失败");
      setError(caughtError instanceof Error ? caughtError.message : "封面下载失败");
    } finally {
      setIsCoverDownloading(false);
    }
  }

  async function handleSelectDownloadDirectory() {
    setError("");

    try {
      const directoryPath = await selectDownloadDirectory();
      if (directoryPath) {
        setDownloadDirectoryPath(directoryPath);
      }
    } catch (caughtError) {
      setError(caughtError instanceof Error ? caughtError.message : "目录选择失败");
    }
  }

  async function handleClearWeChatAuthorization() {
    if (isClearingWeChatAuthorization) {
      return;
    }
    setError("");
    setWeChatAuthorizationMessage("");
    weChatAuthorizationRequestRef.current += 1;
    setIsClearingWeChatAuthorization(true);
    try {
      await clearWeChatAuthorization();
      weChatAuthorizationRequestRef.current += 1;
      setWeChatAuthorizationState("unauthorized");
      setWeChatAuthorizationMessage("已清理，下次下载需重新授权");
    } catch (caughtError) {
      setError(caughtError instanceof Error ? caughtError.message : "微信视频号授权清理失败");
    } finally {
      setIsClearingWeChatAuthorization(false);
    }
  }

  async function pauseRunningDownload(taskId: string) {
    updateDownloadTask(taskId, (currentTask) => ({
      ...currentTask,
      status: "paused",
      message: "正在暂停",
      controlPending: true,
    }));
    try {
      await pauseDownload(taskId);
      updateDownloadTask(taskId, (currentTask) => ({
        ...currentTask,
        status: "paused",
        message: "已暂停",
        controlPending: false,
      }));
    } catch (caughtError) {
      updateDownloadTask(taskId, (currentTask) => ({
        ...currentTask,
        status: "failed",
        message: caughtError instanceof Error ? caughtError.message : "暂停失败",
        controlPending: false,
      }));
    }
  }

  async function handlePauseAllDownloads() {
    const runningTaskIds = downloadTasks
      .filter((currentTask) => isRunningDownloadStatus(currentTask.status) && !currentTask.controlPending)
      .map((currentTask) => currentTask.id);
    setIsDownloadQueuePaused(true);
    setDownloadTasks((currentTasks) =>
      currentTasks.map((currentTask) =>
        currentTask.status === "queued"
          ? {
              ...currentTask,
              status: "paused",
              message: "已暂停，等待开始",
            }
          : currentTask,
      ),
    );
    await Promise.all(runningTaskIds.map((taskId) => pauseRunningDownload(taskId)));
  }

  async function handleStartAllDownloads() {
    const pausedRunningTaskIds = downloadTasks
      .filter(
        (currentTask) =>
          currentTask.status === "paused" &&
          activeDownloadIdsRef.current.has(currentTask.id) &&
          !currentTask.controlPending,
      )
      .map((currentTask) => currentTask.id);
    const failedTaskIds = downloadTasks
      .filter((currentTask) => currentTask.status === "failed" && !currentTask.controlPending)
      .map((currentTask) => currentTask.id);
    await Promise.all(failedTaskIds.map((taskId) => cancelDownload(taskId, true).catch(() => undefined)));
    const resumeResults = await Promise.allSettled(pausedRunningTaskIds.map((taskId) => resumeDownload(taskId)));
    const failedResumeTaskIds = new Set(
      resumeResults
        .map((result, index) => (result.status === "rejected" ? pausedRunningTaskIds[index] : null))
        .filter((taskId): taskId is string => taskId !== null),
    );
    setIsDownloadQueuePaused(false);
    setDownloadTasks((currentTasks) =>
      currentTasks.map((currentTask) => {
        if (failedResumeTaskIds.has(currentTask.id)) {
          activeDownloadIdsRef.current.delete(currentTask.id);
          return { ...currentTask, status: "failed", message: "继续下载失败" };
        }
        if (pausedRunningTaskIds.includes(currentTask.id)) {
          return { ...currentTask, status: "downloading", message: "继续下载" };
        }
        if ((currentTask.status === "paused" || currentTask.status === "failed") && !currentTask.controlPending) {
          return {
            ...currentTask,
            status: "queued",
            progress: currentTask.status === "failed" ? 0 : currentTask.progress,
            message: "等待下载",
          };
        }
        return currentTask;
      }),
    );
  }

  async function deleteDownloadTask(taskId: string) {
    const currentTask = downloadTasks.find((candidate) => candidate.id === taskId);
    if (!currentTask || currentTask.controlPending) {
      return;
    }
    if (currentTask.status === "completed") {
      setDownloadTasks((currentTasks) => currentTasks.filter((candidate) => candidate.id !== taskId));
      return;
    }

    const wasRunning = isRunningDownloadStatus(currentTask.status) || activeDownloadIdsRef.current.has(taskId);
    if (wasRunning) {
      controlIntentRef.current.set(taskId, "delete");
      updateDownloadTask(taskId, (taskToDelete) => ({
        ...taskToDelete,
        message: "正在终止并删除",
        controlPending: true,
      }));
    }
    try {
      await cancelDownload(taskId, true);
      if (!wasRunning) {
        setDownloadTasks((currentTasks) => currentTasks.filter((candidate) => candidate.id !== taskId));
      }
    } catch (caughtError) {
      controlIntentRef.current.delete(taskId);
      updateDownloadTask(taskId, (taskToDelete) => ({
        ...taskToDelete,
        status: "failed",
        message: caughtError instanceof Error ? caughtError.message : "删除失败",
        controlPending: false,
      }));
    }
  }

  async function handleDeleteVisibleDownloads() {
    const visibleTaskIds = downloadTasks
      .filter((currentTask) =>
        downloadListTab === "completed" ? currentTask.status === "completed" : currentTask.status !== "completed",
      )
      .filter((currentTask) => !currentTask.controlPending)
      .map((currentTask) => currentTask.id);
    await Promise.all(visibleTaskIds.map((taskId) => deleteDownloadTask(taskId)));
  }

  async function handlePauseDownload(taskId: string) {
    const currentTask = downloadTasks.find((candidate) => candidate.id === taskId);
    if (!currentTask || currentTask.controlPending) {
      return;
    }
    if (isRunningDownloadStatus(currentTask.status)) {
      await pauseRunningDownload(taskId);
      return;
    }
    setDownloadTasks((currentTasks) =>
      currentTasks.map((currentTask) =>
        currentTask.id === taskId && currentTask.status === "queued"
          ? {
              ...currentTask,
              status: "paused",
              message: "已暂停，等待开始",
            }
          : currentTask,
      ),
    );
  }

  async function handleStartDownload(taskId: string) {
    const currentTask = downloadTasks.find((candidate) => candidate.id === taskId);
    if (!currentTask || currentTask.controlPending) {
      return;
    }
    if (currentTask.status === "paused" && activeDownloadIdsRef.current.has(taskId)) {
      updateDownloadTask(taskId, (taskToResume) => ({
        ...taskToResume,
        message: "正在继续",
        controlPending: true,
      }));
      try {
        await resumeDownload(taskId);
        setIsDownloadQueuePaused(false);
        updateDownloadTask(taskId, (taskToResume) => ({
          ...taskToResume,
          status: "downloading",
          message: "继续下载",
          controlPending: false,
        }));
      } catch (caughtError) {
        activeDownloadIdsRef.current.delete(taskId);
        updateDownloadTask(taskId, (taskToResume) => ({
          ...taskToResume,
          status: "failed",
          message: caughtError instanceof Error ? caughtError.message : "继续下载失败",
          controlPending: false,
        }));
      }
      return;
    }
    if (currentTask.status === "failed") {
      await cancelDownload(taskId, true).catch(() => undefined);
    }
    setIsDownloadQueuePaused(false);
    setDownloadTasks((currentTasks) =>
      currentTasks.map((currentTask) =>
        currentTask.id === taskId && (currentTask.status === "paused" || currentTask.status === "failed")
          ? {
              ...currentTask,
              status: "queued",
              progress: currentTask.status === "failed" ? 0 : currentTask.progress,
              message: "等待下载",
            }
          : currentTask,
      ),
    );
  }

  async function handleDeleteDownload(taskId: string) {
    await deleteDownloadTask(taskId);
  }

  async function handleOpenPreferences() {
    setError("");
    setIsOpeningSettings(true);
    try {
      await openPreferences();
    } catch (caughtError) {
      setError(caughtError instanceof Error ? caughtError.message : "无法打开偏好设置");
    } finally {
      setIsOpeningSettings(false);
    }
  }

  return (
    <main className="app-shell">
      <section className="workspace">
        <header className="toolbar app-home-toolbar">
          <div className="app-home-heading">
            <div className="title-row">
              <h1>
                <img className="app-wordmark" src="./brand/ek-streamdl-wordmark.png" alt="EK StreamDL" />
              </h1>
              <a className="author-home-link" href="https://github.com/Tang1206cc">
                作者：唐梓耀（Emir Kaya） 主页：https://github.com/Tang1206cc
              </a>
            </div>
            <p>
              实现主流网站视频快速按需下载，本工具仅作学习与非盈利用途，请勿恶意利用其侵犯他人/组织的合法权益，用户行为与本工具作者无关。
            </p>
          </div>
          <div className="app-home-actions">
            <button
              type="button"
              className="settings-button"
              disabled={isOpeningSettings}
              aria-label="打开偏好设置"
              title="偏好设置"
              onClick={handleOpenPreferences}
            >
              <SettingsGearIcon />
            </button>
            <div className="app-info-pills">
              <span className="platform-pill">macOS</span>
              <button type="button" className="about-pill" onClick={() => setIsAboutModalOpen(true)}>
                关于
              </button>
            </div>
          </div>
        </header>

        <section className="input-panel" aria-label="链接解析">
          <textarea
            value={inputText}
            onChange={(event) => setInputText(event.target.value)}
            placeholder="粘贴视频页分享链接"
            rows={2}
          />
          <div className="input-actions">
            <div className="environment-entry">
              <button
                type="button"
                className="environment-config-button"
                onClick={() => setIsEnvironmentModalOpen(true)}
              >
                ⚠️配置所需环境
              </button>
              <span>初次使用务必点击，否则可能无法正常使用</span>
            </div>
            <button type="button" className="support-link" onClick={() => setIsSupportModalOpen(true)}>
              查看目前支持平台
            </button>
            <button type="button" className="download-list-open" onClick={() => setIsDownloadListOpen(true)}>
              <DownloadListIcon />
              <span>下载列表</span>
              {downloadTasks.length > 0 ? <span className="download-list-badge">{downloadTasks.length}</span> : null}
            </button>
            <button type="button" className="ghost-button" onClick={() => setInputText(EXAMPLE_TEXT)}>
              填入示例
            </button>
            <button type="button" className="primary-button" disabled={isParsing} onClick={handleParse}>
              {isParsing ? "解析中" : "解析"}
            </button>
          </div>
          {parseStageMessage ? (
            <p className="parse-stage-text" aria-live="polite">
              {parseStageMessage}
            </p>
          ) : null}
          {error ? <p className="error-text">{error}</p> : null}
        </section>

        {metadata ? (
          <section className="result-panel" aria-label="解析结果">
            <div className="cover-block">
              <img className="cover" src={metadata.coverUrl} alt={`${metadata.platformName}封面预览`} />
              <button
                type="button"
                className="ghost-button cover-download-button"
                disabled={isCoverDownloading || !metadata.coverUrl}
                onClick={handleDownloadCover}
              >
                {isCoverDownloading ? "下载中" : "下载封面"}
              </button>
              {coverDownloadMessage ? (
                <p className="cover-download-message" title={coverDownloadMessage}>
                  {coverDownloadMessage}
                </p>
              ) : null}
              <label className="download-sound-toggle">
                <input
                  type="checkbox"
                  checked={isDownloadSoundEnabled}
                  onChange={(event) => {
                    const isEnabled = event.target.checked;
                    downloadSoundEnabledRef.current = isEnabled;
                    setIsDownloadSoundEnabled(isEnabled);
                  }}
                />
                <span>下载后提示🔔</span>
              </label>
            </div>
            <div className="video-detail">
              <div className="detail-heading">
                <div className="detail-platform-row">
                  <span className="detail-platform-badge">{metadata.platformName}</span>
                  {metadata.platform === "douyin" ? (
                    <small className="douyin-collection-disclaimer">
                      注意：抖音平台合集视频的列表暂时无法完整呈现，请自行分集解析。
                    </small>
                  ) : null}
                  {metadata.platform === "wechatChannels" ? (
                    <small className="wechat-login-disclaimer">
                      <span className={`wechat-auth-indicator ${weChatAuthorizationState}`} aria-live="polite">
                        授权状态：
                        {weChatAuthorizationState === "checking"
                          ? "检查中"
                          : weChatAuthorizationState === "authorized"
                            ? "已授权"
                            : "未授权"}
                      </span>
                      <span>下载过程中腾讯可能会要求登录微信，此登录与本工具无关。</span>
                      <button
                        type="button"
                        className="wechat-auth-clear-link"
                        disabled={isClearingWeChatAuthorization}
                        onClick={handleClearWeChatAuthorization}
                      >
                        {isClearingWeChatAuthorization ? "正在清理" : "清理当前授权"}
                      </button>
                      {weChatAuthorizationMessage ? (
                        <span className="wechat-auth-status">{weChatAuthorizationMessage}</span>
                      ) : null}
                    </small>
                  ) : null}
                </div>
                <strong>{metadata.title}</strong>
              </div>

              <dl className="meta-grid">
                <div>
                  <dt>作者</dt>
                  <dd>{metadata.author}</dd>
                </div>
                <div>
                  <dt>发布日期</dt>
                  <dd>{metadata.publishedAt}</dd>
                </div>
                <div>
                  <dt>视频时长</dt>
                  <dd>{metadata.duration}</dd>
                </div>
                <div>
                  <dt>下载信息</dt>
                  <dd>
                    {metadata.platform === "wechatChannels" && !metadata.estimatedSizeMb
                      ? "登录后获取"
                      : formatEstimatedSize(metadata.estimatedSizeMb)}
                  </dd>
                </div>
              </dl>

              <p className="note">{metadata.note}</p>

              {hasCollection ? (
                <CollectionSelector
                  items={collectionItems}
                  isOpen={isCollectionPickerOpen}
                  draftSelection={draftCollectionSelection}
                  confirmedSelection={confirmedCollectionSelection}
                  onOpenChange={setIsCollectionPickerOpen}
                  onDraftChange={setDraftCollectionSelection}
                  onConfirm={() => {
                    setConfirmedCollectionSelection(draftCollectionSelection);
                    setIsCollectionPickerOpen(false);
                  }}
                />
              ) : null}

              <div className="download-row">
                <div className="download-action">
                  <div className="download-mode-select">
                    <button
                      type="button"
                      className="ghost-button mode-button"
                      disabled={!canDownload}
                      aria-haspopup="menu"
                      aria-expanded={isDownloadModeMenuOpen}
                      title={`当前下载模式：${selectedDownloadMode.label}`}
                      onClick={() => setIsDownloadModeMenuOpen((isOpen) => !isOpen)}
                    >
                      <span>{selectedDownloadMode.shortLabel}</span>
                      <span className="mode-arrow" aria-hidden="true" />
                    </button>
                    {isDownloadModeMenuOpen ? (
                      <div className="mode-menu" role="menu" aria-label="下载模式">
                        {DOWNLOAD_MODE_OPTIONS.map((option) => (
                          <button
                            key={option.id}
                            type="button"
                            role="menuitemradio"
                            aria-checked={option.id === downloadMode}
                            className={option.id === downloadMode ? "active" : ""}
                            onClick={() => {
                              setDownloadMode(option.id);
                              setIsDownloadModeMenuOpen(false);
                            }}
                          >
                            {option.label}
                          </button>
                        ))}
                      </div>
                    ) : null}
                  </div>
                  <button
                    type="button"
                    className="primary-button download-button"
                    disabled={!canDownload}
                    onClick={handleDownload}
                  >
                    下载
                  </button>
                </div>
                <div className="download-directory" aria-label="下载目录选择">
                  <span className="directory-label">下载目录</span>
                  <span className="directory-path" title={downloadDirectoryLabel}>
                    {downloadDirectoryLabel}
                  </span>
                  <button type="button" className="ghost-button compact-button" onClick={handleSelectDownloadDirectory}>
                    选择
                  </button>
                  {downloadDirectoryPath ? (
                    <button type="button" className="directory-reset" onClick={() => setDownloadDirectoryPath(null)}>
                      恢复默认
                    </button>
                  ) : null}
                </div>
                {visibleTask ? <Progress task={visibleTask} /> : null}
              </div>
            </div>
          </section>
        ) : (
          <section className="empty-panel" aria-label="空状态">
            <span>等待解析链接</span>
          </section>
        )}
      </section>

      {isEnvironmentModalOpen ? (
        <EnvironmentSetupModal onClose={() => setIsEnvironmentModalOpen(false)} />
      ) : null}

      {isAboutModalOpen ? <AboutModal onClose={() => setIsAboutModalOpen(false)} /> : null}

      {isSupportModalOpen ? (
        <div className="modal-backdrop" role="presentation" onClick={() => setIsSupportModalOpen(false)}>
          <section
            className="support-modal"
            role="dialog"
            aria-modal="true"
            aria-labelledby="support-modal-title"
            onClick={(event) => event.stopPropagation()}
          >
            <h2 id="support-modal-title">目前支持平台</h2>
            <p>{SUPPORTED_PLATFORM_NAMES.join("、")}</p>
            <button type="button" className="primary-button" onClick={() => setIsSupportModalOpen(false)}>
              知道了
            </button>
          </section>
        </div>
      ) : null}

      {isDownloadListOpen ? (
        <DownloadListModal
          tasks={downloadTasks}
          activeCount={activeDownloadCount}
          completedCount={completedDownloadCount}
          activeTab={downloadListTab}
          onTabChange={setDownloadListTab}
          onClose={() => setIsDownloadListOpen(false)}
          onPauseAll={handlePauseAllDownloads}
          onStartAll={handleStartAllDownloads}
          onDeleteVisible={handleDeleteVisibleDownloads}
          onPauseTask={handlePauseDownload}
          onStartTask={handleStartDownload}
          onDeleteTask={handleDeleteDownload}
        />
      ) : null}
    </main>
  );
}

function AboutModal({ onClose }: { onClose: () => void }) {
  return (
    <div className="modal-backdrop" role="presentation" onClick={onClose}>
      <section
        className="about-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="about-modal-title"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="about-modal-head">
          <span aria-hidden="true" />
          <h2 id="about-modal-title">关于</h2>
          <button type="button" className="about-modal-close" aria-label="关闭关于窗口" onClick={onClose}>
            ×
          </button>
        </div>

        <div className="about-contact-list">
          <a className="about-contact-card about-contact-link" href="https://b23.tv/HzxdJwK">
            <span>bilibili弹幕网：EmirKaya（UID:3546715558775600）</span>
            <small>点击可跳转 ↗</small>
          </a>
          <a className="about-contact-card about-contact-link" href="https://xhslink.com/m/5x8KUzU0lwn">
            <span>小红书：EmirKaya（Tangzyhard）</span>
            <small>点击可跳转 ↗</small>
          </a>
          <div className="about-contact-card about-copyable">QQ：2410710390（邮箱同号）</div>
          <div className="about-contact-card about-copyable">QQ群：922281790</div>
        </div>

        <img
          className="about-visual"
          src="./about/ek-author-card.png"
          alt="EK StreamDL 作者与版权信息"
        />
      </section>
    </div>
  );
}

type EnvironmentSetupStage = "intro" | "checking" | "result" | "installing" | "ready" | "error";

const ENVIRONMENT_REQUIREMENTS: RuntimeEnvironmentComponent[] = [
  {
    id: "macos",
    name: "macOS 13 或更高版本",
    purpose: "提供应用界面、网络访问与本地文件处理能力",
    required: true,
    installed: false,
    installable: false,
    detail: "待检查系统版本",
  },
  {
    id: "downloads",
    name: "下载目录",
    purpose: "验证系统默认下载目录可写，确保文件能正常保存",
    required: true,
    installed: false,
    installable: false,
    detail: "待检查目录权限",
  },
  {
    id: "network",
    name: "平台网络",
    purpose: "验证所有已支持平台的 DNS 与 HTTPS 连通性",
    required: true,
    installed: false,
    installable: false,
    detail: "待检查平台连通性",
  },
  {
    id: "yt-dlp",
    name: "yt-dlp",
    purpose: "解析视频页面信息并获取可下载的视频、音频资源",
    required: true,
    installed: false,
    installable: true,
    detail: "待检查运行组件",
  },
  {
    id: "ffmpeg",
    name: "FFmpeg",
    purpose: "合并音视频、提取音频并完成下载后的媒体处理",
    required: true,
    installed: false,
    installable: true,
    detail: "待检查运行组件",
  },
];

function EnvironmentSetupModal({ onClose }: { onClose: () => void }) {
  const [stage, setStage] = useState<EnvironmentSetupStage>("intro");
  const [report, setReport] = useState<RuntimeEnvironmentReport | null>(null);
  const [progressEvent, setProgressEvent] = useState<RuntimeEnvironmentProgressEvent>({
    progress: 0,
    message: "等待开始检查",
  });
  const [operationError, setOperationError] = useState("");
  const [diagnosticMessage, setDiagnosticMessage] = useState("");
  const isBusy = stage === "checking" || stage === "installing";
  const components = report?.components ?? ENVIRONMENT_REQUIREMENTS;
  const missingComponents = report?.components.filter((component) => component.required && !component.installed) ?? [];
  const recommendedComponents = report?.components.filter((component) => component.updateAvailable) ?? [];
  const installableMissingComponents = missingComponents.filter((component) => component.installable);
  const unsupportedMissingComponents = missingComponents.filter((component) => !component.installable);
  const actionableComponents = [...installableMissingComponents, ...recommendedComponents].filter(
    (component, index, allComponents) => allComponents.findIndex((candidate) => candidate.id === component.id) === index,
  );

  async function handleCheckEnvironment() {
    setOperationError("");
    setStage("checking");
    setDiagnosticMessage("");
    setProgressEvent({ progress: 18, message: "正在检查系统、目录、网络与运行组件" });
    try {
      const nextReport = await checkRuntimeEnvironment();
      setReport(nextReport);
      setProgressEvent({ progress: 100, message: "设备检查完成" });
      setStage(nextReport.ready && (nextReport.recommendedComponentIds?.length ?? 0) === 0 ? "ready" : "result");
    } catch (caughtError) {
      setOperationError(caughtError instanceof Error ? caughtError.message : "设备环境检查失败");
      setStage("error");
    }
  }

  async function handleInstallEnvironment() {
    setOperationError("");
    setStage("installing");
    setProgressEvent({ progress: 1, message: "正在准备按需配置" });
    try {
      const nextReport = await installRuntimeEnvironment((event) => {
        setProgressEvent({
          ...event,
          progress: Math.max(0, Math.min(100, event.progress)),
        });
      });
      setReport(nextReport);
      setProgressEvent({ progress: 100, message: "环境配置完成" });
      setStage(nextReport.ready && (nextReport.recommendedComponentIds?.length ?? 0) === 0 ? "ready" : "result");
    } catch (caughtError) {
      setOperationError(caughtError instanceof Error ? caughtError.message : "自动配置失败");
      setStage("error");
    }
  }

  async function handleExportDiagnostics() {
    setDiagnosticMessage("");
    try {
      const result = await exportDiagnosticReport(report ?? undefined);
      setDiagnosticMessage(result.savedPath ? `诊断报告已保存：${result.savedPath}` : "已取消导出");
    } catch (caughtError) {
      setDiagnosticMessage(caughtError instanceof Error ? caughtError.message : "诊断报告导出失败");
    }
  }

  function closeIfIdle() {
    if (!isBusy) {
      onClose();
    }
  }

  return (
    <div className="modal-backdrop" role="presentation" onClick={closeIfIdle}>
      <section
        className="environment-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="environment-modal-title"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="environment-modal-head">
          <div>
            <span>EK流媒体视频下载器 · 运行环境</span>
            <h2 id="environment-modal-title">配置所需环境</h2>
          </div>
          <button
            type="button"
            className="environment-modal-close"
            aria-label="关闭环境配置"
            disabled={isBusy}
            onClick={closeIfIdle}
          >
            ×
          </button>
        </div>

        <p className="environment-intro">
          本功能会检查视频解析、下载及媒体处理所需组件。应用会优先复用设备上已有工具；缺失时仅安装应用专用副本，无需安装 Xcode、Node.js 或 Homebrew，也不会改动已有工具。
        </p>

        <div className="environment-component-list">
          {components.map((component) => {
            const hasReport = report !== null;
            const statusClass = !hasReport
              ? "pending"
              : component.updateAvailable
                ? "update"
                : component.installed
                  ? "ready"
                  : "missing";
            const statusText = !hasReport
              ? "待检查"
              : component.updateAvailable
                ? "建议更新"
                : component.installed
                  ? "已就绪"
                  : "需配置";
            return (
              <article className="environment-component" key={component.id}>
                <div className="environment-component-heading">
                  <strong>{component.name}</strong>
                  <span className={`environment-component-status ${statusClass}`}>{statusText}</span>
                </div>
                <p>{component.purpose}</p>
                <small title={component.path ?? component.detail}>
                  {component.version ? `${component.version} · ` : ""}
                  {component.detail}
                  {component.latestVersion ? ` · 最新 ${component.latestVersion}` : ""}
                </small>
              </article>
            );
          })}
        </div>

        {isBusy ? (
          <div className="environment-progress" aria-live="polite">
            <div className="environment-progress-label">
              <span>{progressEvent.message}</span>
              <strong>{progressEvent.progress}%</strong>
            </div>
            <div className="environment-progress-track">
              <span style={{ width: `${progressEvent.progress}%` }} />
            </div>
            <small>{stage === "installing" ? "请保持应用开启，安装完成后会自动复查" : "正在读取本设备环境信息"}</small>
          </div>
        ) : null}

        {stage === "ready" ? <p className="environment-ready">✅当前设备环境齐全，无需配置</p> : null}
        {stage === "result" && (missingComponents.length > 0 || recommendedComponents.length > 0) ? (
          <p className="environment-needed">
            {actionableComponents.length > 0
              ? `${installableMissingComponents.length > 0 ? "需要配置" : "建议更新"}：${actionableComponents.map((component) => component.name).join("、")}。组件将保存到当前用户的应用支持目录，不需要管理员权限。`
              : `当前设备不满足运行要求：${unsupportedMissingComponents.map((component) => component.name).join("、")}。请按检查结果处理后重试。`}
          </p>
        ) : null}
        {stage === "error" ? <p className="environment-operation-error">{operationError}</p> : null}

        <div className="environment-modal-actions">
          {stage === "intro" ? (
            <button type="button" className="primary-button environment-check-button" onClick={handleCheckEnvironment}>
              检查本设备，以准备按需配置
            </button>
          ) : null}
          {stage === "result" && actionableComponents.length > 0 ? (
            <button type="button" className="primary-button environment-install-button" onClick={handleInstallEnvironment}>
              一键安装/更新
            </button>
          ) : null}
          {stage === "result" && actionableComponents.length === 0 ? (
            <button type="button" className="primary-button" onClick={onClose}>
              知道了
            </button>
          ) : null}
          {stage === "ready" ? (
            <button type="button" className="primary-button" onClick={onClose}>
              完成
            </button>
          ) : null}
          {stage === "error" ? (
            <>
              <button type="button" className="ghost-button" onClick={handleCheckEnvironment}>
                重新检查
              </button>
              {report && missingComponents.some((component) => component.installable) ? (
                <button type="button" className="primary-button" onClick={handleInstallEnvironment}>
                  重新尝试安装
                </button>
              ) : null}
            </>
          ) : null}
          {report && !isBusy ? (
            <button type="button" className="ghost-button environment-export-button" onClick={handleExportDiagnostics}>
              导出诊断报告
            </button>
          ) : null}
        </div>

        {diagnosticMessage ? (
          <p className="environment-diagnostic-message" title={diagnosticMessage}>
            {diagnosticMessage}
          </p>
        ) : null}

        <p className="environment-source-note">
          自动配置需要联网；下载支持断点续传与最多 3 次重试，安装文件通过 HTTPS 获取并进行 SHA-256 完整性校验。FFmpeg 会按当前 Mac 架构使用主、备发行源。
        </p>
        <details className="third-party-notices">
          <summary>第三方组件来源与许可</summary>
          <div>
            <p>
              <strong>yt-dlp</strong>：用于解析公开视频页面，来自
              <a href="https://github.com/yt-dlp/yt-dlp"> yt-dlp 官方 GitHub</a>，遵循 Unlicense 许可。
            </p>
            <p>
              <strong>FFmpeg</strong>：用于媒体检查、合并与转换，主源为
              <a href="https://github.com/myndrai/myndr-ffmpeg-lgpl"> myndr-ffmpeg-lgpl</a>，备用源为
              <a href="https://github.com/eugeneware/ffmpeg-static"> ffmpeg-static</a> 与
              <a href="https://www.osxexperts.net/"> osxexperts.net</a>；实际适用 LGPL/GPL 条款以所安装构建为准。
            </p>
          </div>
        </details>
      </section>
    </div>
  );
}

function formatEstimatedSize(value?: number) {
  if (typeof value !== "number" || !Number.isFinite(value) || value <= 0) {
    return "预估大小未知";
  }

  const roundedValue = value >= 100 ? Math.round(value) : Math.round(value * 10) / 10;
  return `约 ${roundedValue} MB`;
}

function getInitialCollectionSelection(metadata: VideoMetadata) {
  const items = metadata.collection?.items ?? [];
  if (items.length <= 1) {
    return [];
  }
  const currentItem = items.find((item) => item.url === metadata.normalizedUrl || item.id === metadata.id);
  return [currentItem?.id ?? items[0].id];
}

function CollectionSelector({
  items,
  isOpen,
  draftSelection,
  confirmedSelection,
  onOpenChange,
  onDraftChange,
  onConfirm,
}: {
  items: VideoCollectionItem[];
  isOpen: boolean;
  draftSelection: string[];
  confirmedSelection: string[];
  onOpenChange: (isOpen: boolean) => void;
  onDraftChange: (selection: string[]) => void;
  onConfirm: () => void;
}) {
  const selectedCount = confirmedSelection.length;
  const selectedEpisodesSummary = confirmedSelection
    .map((itemId) => items.find((item) => item.id === itemId)?.index)
    .filter((index): index is number => typeof index === "number")
    .sort((left, right) => left - right)
    .map((index) => `第${index}集`)
    .join("、");

  function toggleItem(itemId: string) {
    onDraftChange(
      draftSelection.includes(itemId)
        ? draftSelection.filter((candidate) => candidate !== itemId)
        : [...draftSelection, itemId],
    );
  }

  return (
    <div className="collection-selector">
      <button
        type="button"
        className="ghost-button collection-trigger"
        aria-expanded={isOpen}
        onClick={() => {
          if (!isOpen) {
            onDraftChange(confirmedSelection);
          }
          onOpenChange(!isOpen);
        }}
      >
        <span className="collection-trigger-label">合集选择：已选 {selectedCount}/{items.length} 集</span>
        <span className="collection-trigger-summary" title={selectedEpisodesSummary}>
          {selectedEpisodesSummary || "未选择"}
        </span>
      </button>

      {isOpen ? (
        <div className="collection-panel">
          <div className="collection-panel-head">
            <button
              type="button"
              className="collection-panel-link"
              onClick={() => onDraftChange(items.map((item) => item.id))}
            >
              勾选全部
            </button>
            <button type="button" className="collection-panel-link" onClick={() => onDraftChange([])}>
              取消勾选
            </button>
          </div>
          <div className="collection-list" role="group" aria-label="合集视频选择">
            {items.map((item) => (
              <label key={item.id} className="collection-item">
                <input
                  type="checkbox"
                  checked={draftSelection.includes(item.id)}
                  onChange={() => toggleItem(item.id)}
                />
                <span className="collection-item-index">第 {item.index} 集</span>
                <span className="collection-item-title">{item.title}</span>
              </label>
            ))}
          </div>
          <div className="collection-panel-actions">
            <button type="button" className="primary-button collection-confirm" disabled={draftSelection.length === 0} onClick={onConfirm}>
              确定
            </button>
          </div>
        </div>
      ) : null}
    </div>
  );
}

function DownloadListModal({
  tasks,
  activeCount,
  completedCount,
  activeTab,
  onTabChange,
  onClose,
  onPauseAll,
  onStartAll,
  onDeleteVisible,
  onPauseTask,
  onStartTask,
  onDeleteTask,
}: {
  tasks: ManagedDownloadTask[];
  activeCount: number;
  completedCount: number;
  activeTab: DownloadListTab;
  onTabChange: (tab: DownloadListTab) => void;
  onClose: () => void;
  onPauseAll: () => void;
  onStartAll: () => void;
  onDeleteVisible: () => void;
  onPauseTask: (taskId: string) => void;
  onStartTask: (taskId: string) => void;
  onDeleteTask: (taskId: string) => void;
}) {
  const visibleTasks = tasks.filter((task) =>
    activeTab === "completed" ? task.status === "completed" : task.status !== "completed",
  );
  const hasPausableTasks = tasks.some(
    (task) => (task.status === "queued" || isRunningDownloadStatus(task.status)) && !task.controlPending,
  );
  const hasStartableTasks = tasks.some(
    (task) => (task.status === "paused" || task.status === "failed") && !task.controlPending,
  );
  const hasDeletableVisibleTasks = visibleTasks.some((task) => !task.controlPending);

  return (
    <div className="modal-backdrop" role="presentation" onClick={onClose}>
      <section
        className="download-list-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="download-list-title"
        onClick={(event) => event.stopPropagation()}
      >
        <div className="download-list-head">
          <div className="download-list-tabs" role="tablist" aria-label="下载任务分类">
            <button
              type="button"
              id="download-list-title"
              className={activeTab === "active" ? "active" : ""}
              role="tab"
              aria-selected={activeTab === "active"}
              onClick={() => onTabChange("active")}
            >
              下载中({activeCount})
            </button>
            <button
              type="button"
              className={activeTab === "completed" ? "active" : ""}
              role="tab"
              aria-selected={activeTab === "completed"}
              onClick={() => onTabChange("completed")}
            >
              已完成({completedCount})
            </button>
          </div>
          <button type="button" className="download-list-close" aria-label="关闭下载列表" onClick={onClose}>
            ×
          </button>
        </div>

        <div className="download-list-controls">
          <button type="button" className="list-control-button" disabled={!hasPausableTasks} onClick={onPauseAll}>
            <span aria-hidden="true">Ⅱ</span>
            全部暂停
          </button>
          <button type="button" className="list-control-button" disabled={!hasStartableTasks} onClick={onStartAll}>
            <span aria-hidden="true">▷</span>
            全部开始
          </button>
          <button type="button" className="list-control-button" disabled={!hasDeletableVisibleTasks} onClick={onDeleteVisible}>
            <span aria-hidden="true">⌫</span>
            全部删除
          </button>
        </div>

        <div className="download-list-content">
          {visibleTasks.length > 0 ? (
            visibleTasks.map((task) => (
              <DownloadListItem
                key={task.id}
                task={task}
                onPauseTask={onPauseTask}
                onStartTask={onStartTask}
                onDeleteTask={onDeleteTask}
              />
            ))
          ) : (
            <div className="download-list-empty">
              {activeTab === "completed" ? "暂无已完成任务" : "暂无下载任务"}
            </div>
          )}
        </div>
      </section>
    </div>
  );
}

function DownloadListItem({
  task,
  onPauseTask,
  onStartTask,
  onDeleteTask,
}: {
  task: ManagedDownloadTask;
  onPauseTask: (taskId: string) => void;
  onStartTask: (taskId: string) => void;
  onDeleteTask: (taskId: string) => void;
}) {
  const isRunning = isRunningDownloadStatus(task.status);
  const canPause = (task.status === "queued" || isRunning) && !task.controlPending;
  const canStart = (task.status === "paused" || task.status === "failed") && !task.controlPending;
  const canDelete = !task.controlPending;
  const modeLabel = getDownloadModeLabel(task.downloadMode);
  const collectionCount = task.metadata.selectedCollectionItems?.length ?? 0;
  const selectedCollectionItem = collectionCount === 1 ? task.metadata.selectedCollectionItems?.[0] : undefined;

  return (
    <article className="download-list-item">
      <img className="download-list-cover" src={task.metadata.coverUrl} alt="" />
      <div className="download-list-item-main">
        <div className="download-list-item-title" title={task.metadata.title}>
          {task.metadata.title}
        </div>
        <div className="download-list-item-meta">
          <span>{task.metadata.platformName}</span>
          <span>{modeLabel}</span>
          {selectedCollectionItem ? <span>第 {selectedCollectionItem.index} 集</span> : null}
          {collectionCount > 1 ? <span>合集 {collectionCount} 集</span> : null}
          <span>{getDownloadStatusLabel(task.status)}</span>
        </div>
        <div className="download-list-item-message" title={task.message}>
          {task.message}
        </div>
        <div className="download-list-progress">
          <div className="download-list-progress-track">
            <div className="download-list-progress-bar" style={{ width: `${task.progress}%` }} />
          </div>
          <span>{task.progress}%</span>
        </div>
      </div>
      <div className="download-list-item-actions">
        {canPause ? (
          <button type="button" className="small-action-button" onClick={() => onPauseTask(task.id)}>
            暂停
          </button>
        ) : null}
        {canStart ? (
          <button type="button" className="small-action-button" onClick={() => onStartTask(task.id)}>
            开始
          </button>
        ) : null}
        <button
          type="button"
          className="small-action-button"
          disabled={!canDelete}
          onClick={() => onDeleteTask(task.id)}
        >
          删除
        </button>
      </div>
    </article>
  );
}

function Progress({ task }: { task: ManagedDownloadTask }) {
  return (
    <div className="progress-wrap" aria-label="下载进度">
      <div className="progress-meta">
        <span>{task.message}</span>
        <span>{task.progress}%</span>
      </div>
      <div className="progress-track">
        <div className="progress-bar" style={{ width: `${task.progress}%` }} />
      </div>
    </div>
  );
}

function DownloadListIcon() {
  return (
    <svg className="download-list-icon" viewBox="0 0 24 24" aria-hidden="true">
      <path d="M5 6.5h8.5" />
      <path d="M5 11.5h6.5" />
      <path d="M5 16.5h4.5" />
      <path d="M17 5v9" />
      <path d="m13.5 10.5 3.5 3.5 3.5-3.5" />
      <path d="M13.5 18.5h7" />
    </svg>
  );
}

function isRunningDownloadStatus(status: ManagedDownloadStatus) {
  return status === "preparing" || status === "downloading";
}

function getDownloadStatusLabel(status: ManagedDownloadStatus) {
  switch (status) {
    case "queued":
      return "等待中";
    case "paused":
      return "已暂停";
    case "preparing":
      return "准备中";
    case "downloading":
      return "下载中";
    case "completed":
      return "已完成";
    case "failed":
      return "失败";
    default:
      return "待开始";
  }
}

function getDownloadModeLabel(mode: DownloadMode) {
  return DOWNLOAD_MODE_OPTIONS.find((option) => option.id === mode)?.label ?? "完整视频";
}
