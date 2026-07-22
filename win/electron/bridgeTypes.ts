export type SupportedPlatform = "bilibili" | "douyin" | "kuaishou" | "xiaohongshu" | "toutiao" | "wechatChannels";
export type DownloadStatus = "idle" | "preparing" | "downloading" | "completed" | "failed";
export type DownloadMode = "complete" | "audio" | "video" | "separate";
export type QualityOption = { id: string; label: string; description: string; available: boolean };
export type VideoCollectionItem = { id: string; title: string; url: string; platform: SupportedPlatform; duration?: string; coverUrl?: string; index: number };
export type VideoCollection = { id: string; title: string; items: VideoCollectionItem[] };
export type VideoMetadata = {
  id: string; originalUrl: string; normalizedUrl: string; platform: SupportedPlatform; platformName: string;
  title: string; author: string; publishedAt: string; duration: string; coverUrl: string;
  qualities: QualityOption[]; estimatedSizeMb?: number; parseMode: "mock" | "real"; note: string;
  suggestedFilename?: string; savedPath?: string; collection?: VideoCollection;
  selectedCollectionItems?: VideoCollectionItem[]; directMediaUrl?: string;
};
export type DownloadProgressEvent = {
  status: DownloadStatus; progress: number; message: string; duration?: string;
  estimatedSizeMb?: number; weChatAuthorized?: boolean;
};
export type RuntimeEnvironmentComponent = {
  id: string; name: string; purpose: string; required: boolean; installed: boolean; installable: boolean;
  version?: string; path?: string; detail: string; updateAvailable?: boolean; latestVersion?: string;
};
export type RuntimeEnvironmentReport = {
  ready: boolean; components: RuntimeEnvironmentComponent[]; missingComponentIds: string[];
  recommendedComponentIds?: string[]; message: string; managedToolsDirectory: string;
  checkedAt?: string; diagnostics?: string[];
};
export type RuntimeEnvironmentProgressEvent = { progress: number; message: string; componentId?: string };
