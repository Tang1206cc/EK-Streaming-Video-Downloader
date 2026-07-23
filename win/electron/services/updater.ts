import { app, BrowserWindow, dialog, net } from "electron";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { finished } from "node:stream/promises";
import { spawn } from "node:child_process";
import extract from "extract-zip";
import { appendDiagnostic } from "./diagnostics.js";
import { runProcess } from "./processRunner.js";
import type { AppLanguage } from "./settings.js";
import { isNewerVersion, parseReleaseVersion, windowsReleaseAssetNames } from "./releaseContract.js";

const RELEASE_API = "https://api.github.com/repos/Tang1206cc/EK-Streaming-Video-Downloader/releases/latest";
const APP_ID = "com.tang1206cc.ekstreamdl";

type GitHubRelease = {
  tag_name: string;
  draft: boolean;
  prerelease: boolean;
  body?: string;
  assets: Array<{ name: string; browser_download_url: string; size?: number }>;
};

function strings(language: AppLanguage) {
  if (language === "en") return {
    available: "A new version of EK StreamDL is available",
    current: "Current version",
    latest: "Latest version",
    update: "Update Now",
    later: "Later",
    none: "EK StreamDL is up to date.",
    error: "Unable to check for updates",
  };
  if (language === "zh-Hant") return {
    available: "EK StreamDL 有新版本可用",
    current: "目前版本",
    latest: "最新版本",
    update: "立即更新",
    later: "下次再說",
    none: "EK StreamDL 已是最新版本。",
    error: "無法檢查更新",
  };
  return {
    available: "EK StreamDL 有新版本可用",
    current: "当前版本",
    latest: "最新版本",
    update: "立即更新",
    later: "下次再说",
    none: "EK StreamDL 已是最新版本。",
    error: "无法检查更新",
  };
}

async function latestRelease() {
  const response = await net.fetch(RELEASE_API, {
    headers: {
      Accept: "application/vnd.github+json",
      "X-GitHub-Api-Version": "2022-11-28",
      "User-Agent": `EKStreamDL/${app.getVersion()} Windows`,
    },
  });
  if (!response.ok) throw new Error(`GitHub API HTTP ${response.status}`);
  const release = await response.json() as GitHubRelease;
  if (release.draft || release.prerelease) throw new Error("GitHub 仓库尚未发布可用版本");
  return release;
}

function progressWindow() {
  const window = new BrowserWindow({
    width: 460,
    height: 180,
    resizable: false,
    minimizable: false,
    maximizable: false,
    autoHideMenuBar: true,
    title: "EK StreamDL 更新",
    backgroundColor: "#f5f7fb",
    webPreferences: { contextIsolation: true, nodeIntegration: false },
  });
  void window.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(`<!doctype html><meta charset="utf-8"><style>body{font:14px 'Segoe UI',sans-serif;color:#152033;background:#f5f7fb;padding:24px}h2{font-size:18px;margin:0 0 20px}progress{width:100%;height:16px}p{color:#667085}</style><h2>正在下载 EK StreamDL 更新</h2><progress id="p" max="100" value="0"></progress><p id="m">准备下载…</p>`)}`);
  return window;
}

async function downloadAsset(url: string, destination: string, window: BrowserWindow) {
  const response = await net.fetch(url, {
    redirect: "follow",
    headers: { "User-Agent": `EKStreamDL/${app.getVersion()} Windows` },
  });
  if (!response.ok || !response.body) throw new Error(`更新包下载失败：HTTP ${response.status}`);
  const total = Number(response.headers.get("content-length") ?? 0);
  let received = 0;
  const hash = crypto.createHash("sha256");
  const stream = fs.createWriteStream(destination);
  const completion = finished(stream);
  for await (const chunk of response.body) {
    const buffer = Buffer.from(chunk);
    hash.update(buffer);
    if (!stream.write(buffer)) {
      await new Promise<void>((resolve, reject) => {
        const onDrain = () => { cleanup(); resolve(); };
        const onError = (error: Error) => { cleanup(); reject(error); };
        const cleanup = () => {
          stream.removeListener("drain", onDrain);
          stream.removeListener("error", onError);
        };
        stream.once("drain", onDrain);
        stream.once("error", onError);
      });
    }
    received += buffer.length;
    const percent = total > 0 ? Math.min(100, Math.round((received / total) * 100)) : 0;
    if (!window.isDestroyed()) {
      void window.webContents.executeJavaScript(`document.getElementById('p').value=${percent};document.getElementById('m').textContent=${JSON.stringify(total > 0 ? `${percent}%` : `${Math.round(received / 1_048_576)} MB`)}`);
    }
  }
  stream.end();
  await completion;
  return hash.digest("hex");
}

function findExecutable(directory: string): string | null {
  for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
    const candidate = path.join(directory, entry.name);
    if (entry.isFile() && entry.name.toLowerCase() === "ek streamdl.exe") return candidate;
    if (entry.isDirectory()) {
      const nested = findExecutable(candidate);
      if (nested) return nested;
    }
  }
  return null;
}

async function validateExecutable(executable: string, expectedVersion: string) {
  const result = await runProcess(executable, ["--version-json"], { timeoutMs: 30_000 });
  if (result.exitCode !== 0) throw new Error("无法验证更新包中的应用身份");
  const line = result.stdout.split(/\r?\n/).find((value) => value.trim().startsWith("{"));
  if (!line) throw new Error("更新包中的应用未返回身份信息");
  const identity = JSON.parse(line) as { appId?: string; productName?: string; version?: string };
  if (identity.appId !== APP_ID || identity.productName !== "EK StreamDL") {
    throw new Error("更新包中的应用身份与 EK StreamDL 不匹配");
  }
  if (identity.version !== expectedVersion) throw new Error("更新包版本与 GitHub Release 标签不一致");
}

function launchInstaller(sourceDirectory: string) {
  const targetDirectory = path.dirname(process.execPath);
  const scriptPath = path.join(app.getPath("temp"), `ek-streamdl-updater-${crypto.randomUUID()}.ps1`);
  const script = `param([int]$ProcessId,[string]$Source,[string]$Target,[string]$Executable)\n` +
    `$ErrorActionPreference='Stop'\n` +
    `Wait-Process -Id $ProcessId -Timeout 120 -ErrorAction SilentlyContinue\n` +
    `New-Item -ItemType Directory -Force -Path $Target | Out-Null\n` +
    `Copy-Item -Path (Join-Path $Source '*') -Destination $Target -Recurse -Force\n` +
    `Start-Process -FilePath (Join-Path $Target $Executable)\n`;
  fs.writeFileSync(scriptPath, script, "utf8");
  const child = spawn("powershell.exe", [
    "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", scriptPath,
    "-ProcessId", String(process.pid), "-Source", sourceDirectory,
    "-Target", targetDirectory, "-Executable", path.basename(process.execPath),
  ], { detached: true, stdio: "ignore", windowsHide: true });
  child.unref();
  app.quit();
}

export async function checkForUpdates(interactive: boolean, language: AppLanguage) {
  const t = strings(language);
  try {
    const release = await latestRelease();
    const local = parseReleaseVersion(app.getVersion());
    const remote = parseReleaseVersion(release.tag_name);
    if (!local || !remote) throw new Error("GitHub Release 版本号格式不正确");
    if (!isNewerVersion(remote, local)) {
      if (interactive) await dialog.showMessageBox({ type: "info", title: "EK StreamDL", message: t.none, buttons: ["OK"] });
      return { updateAvailable: false };
    }
    const remoteText = remote.join(".");
    const expectedNames = windowsReleaseAssetNames(remoteText);
    const asset = expectedNames
      .map((name) => release.assets.find((item) => item.name === name))
      .find((item) => item !== undefined);
    if (!asset) throw new Error(`未找到符合命名规范的 Windows 更新包：${expectedNames[0]}`);
    const expectedName = asset.name;
    const choice = await dialog.showMessageBox({
      type: "info",
      title: t.available,
      message: `${t.current}：v${app.getVersion()}\n${t.latest}：v${remoteText}`,
      detail: release.body?.trim() || "此版本暂无推版描述。",
      buttons: [t.update, t.later],
      defaultId: 0,
      cancelId: 1,
      noLink: true,
    });
    if (choice.response !== 0) return { updateAvailable: true, deferred: true };
    const window = progressWindow();
    const archive = path.join(app.getPath("temp"), `${crypto.randomUUID()}-${expectedName}`);
    const digest = await downloadAsset(asset.browser_download_url, archive, window);
    const staging = path.join(app.getPath("temp"), `EKStreamDL-Update-${remoteText}-${crypto.randomUUID()}`);
    fs.mkdirSync(staging, { recursive: true });
    await extract(archive, { dir: staging });
    fs.unlinkSync(archive);
    const executable = findExecutable(staging);
    if (!executable) throw new Error("未在更新包中找到 EK StreamDL.exe");
    await validateExecutable(executable, remoteText);
    appendDiagnostic("更新", `更新包验证通过：${expectedName}；SHA-256 ${digest}`);
    if (!window.isDestroyed()) window.close();
    launchInstaller(path.dirname(executable));
    return { updateAvailable: true, installing: true };
  } catch (error) {
    appendDiagnostic("更新", `检查或安装失败：${error instanceof Error ? error.message : "未知错误"}`);
    if (interactive) {
      await dialog.showMessageBox({
        type: "error",
        title: t.error,
        message: error instanceof Error ? error.message : t.error,
        buttons: ["OK"],
      });
    }
    return { updateAvailable: false, error: error instanceof Error ? error.message : t.error };
  }
}
