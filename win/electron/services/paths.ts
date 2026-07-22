import { app } from "electron";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export function managedToolsDirectory() {
  const localAppData = process.env.LOCALAPPDATA;
  return localAppData
    ? path.join(localAppData, "EK StreamDL", "Tools")
    : path.join(app.getPath("userData"), "Tools");
}

export function managedYtDlpPath() {
  return path.join(managedToolsDirectory(), "yt-dlp.exe");
}

export function managedFfmpegPath() {
  return path.join(managedToolsDirectory(), "ffmpeg.exe");
}

export function defaultDownloadsDirectory() {
  return app.getPath("downloads") || path.join(os.homedir(), "Downloads");
}

function firstExecutable(candidates: Array<string | undefined>) {
  return candidates.find((candidate) => candidate && fs.existsSync(candidate)) ?? null;
}

function executableOnPath(fileName: string) {
  return (process.env.PATH ?? "")
    .split(path.delimiter)
    .map((directory) => directory.replace(/^"|"$/g, ""))
    .filter(Boolean)
    .map((directory) => path.join(directory, fileName))
    .find((candidate) => fs.existsSync(candidate));
}

export function resolveYtDlpPath() {
  const programFiles = process.env.ProgramFiles;
  const localAppData = process.env.LOCALAPPDATA;
  return firstExecutable([
    process.env.EK_STREAMDL_YTDLP_PATH,
    managedYtDlpPath(),
    localAppData ? path.join(localAppData, "Microsoft", "WinGet", "Links", "yt-dlp.exe") : undefined,
    programFiles ? path.join(programFiles, "yt-dlp", "yt-dlp.exe") : undefined,
    executableOnPath("yt-dlp.exe"),
  ]);
}

export function resolveFfmpegPath() {
  const programFiles = process.env.ProgramFiles;
  const localAppData = process.env.LOCALAPPDATA;
  return firstExecutable([
    process.env.EK_STREAMDL_FFMPEG_PATH,
    managedFfmpegPath(),
    localAppData ? path.join(localAppData, "Microsoft", "WinGet", "Links", "ffmpeg.exe") : undefined,
    programFiles ? path.join(programFiles, "ffmpeg", "bin", "ffmpeg.exe") : undefined,
    executableOnPath("ffmpeg.exe"),
  ]);
}

export function safeFilename(value: string) {
  const cleaned = value
    .replace(/[<>:"/\\|?*\u0000-\u001f]/g, "_")
    .replace(/[. ]+$/g, "")
    .trim();
  const reserved = /^(con|prn|aux|nul|com[1-9]|lpt[1-9])(?:\.|$)/i;
  const normalized = reserved.test(cleaned) ? `_${cleaned}` : cleaned;
  return (normalized || "EK StreamDL 视频").slice(0, 140);
}

export function uniqueBasePath(directory: string, baseName: string, extensions: string[]) {
  let counter = 1;
  let candidate = path.join(directory, safeFilename(baseName));
  const exists = (base: string) => extensions.some((extension) => fs.existsSync(`${base}.${extension}`));
  while (exists(candidate)) {
    counter += 1;
    candidate = path.join(directory, `${safeFilename(baseName)} (${counter})`);
  }
  return candidate;
}
