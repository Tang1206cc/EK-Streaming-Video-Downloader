import type { DownloadProgressEvent, VideoMetadata } from "../../../shared/types";

export type PlatformAdapter = {
  match(url: string): boolean;
  parse(url: string): Promise<VideoMetadata>;
  download(metadata: VideoMetadata, onProgress: (event: DownloadProgressEvent) => void): Promise<void>;
};
