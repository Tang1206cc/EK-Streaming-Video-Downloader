import { app } from "electron";
import fs from "node:fs";
import path from "node:path";

export type ThemeMode = "system" | "light" | "dark";
export type AppLanguage = "zh-Hans" | "zh-Hant" | "en";

export type AppSettings = {
  launchAtLogin: boolean;
  themeMode: ThemeMode;
  escToQuit: boolean;
  quitWhenLastWindowClosed: boolean;
  autoCheckForUpdates: boolean;
  language: AppLanguage;
};

const defaults: AppSettings = {
  launchAtLogin: false,
  themeMode: "system",
  escToQuit: false,
  quitWhenLastWindowClosed: true,
  autoCheckForUpdates: true,
  language: "zh-Hans",
};

function settingsPath() {
  return path.join(app.getPath("userData"), "settings.json");
}

export function readSettings(): AppSettings {
  try {
    const parsed = JSON.parse(fs.readFileSync(settingsPath(), "utf8")) as Partial<AppSettings>;
    return {
      ...defaults,
      ...parsed,
      themeMode: ["system", "light", "dark"].includes(parsed.themeMode ?? "")
        ? (parsed.themeMode as ThemeMode)
        : defaults.themeMode,
      language: ["zh-Hans", "zh-Hant", "en"].includes(parsed.language ?? "")
        ? (parsed.language as AppLanguage)
        : defaults.language,
    };
  } catch {
    return { ...defaults };
  }
}

export function writeSettings(next: AppSettings) {
  fs.mkdirSync(path.dirname(settingsPath()), { recursive: true });
  fs.writeFileSync(settingsPath(), JSON.stringify(next, null, 2), "utf8");
  app.setLoginItemSettings({ openAtLogin: next.launchAtLogin, path: process.execPath });
}

export function resetSettings(language: AppLanguage) {
  const next = { ...defaults, language };
  writeSettings(next);
  return next;
}
