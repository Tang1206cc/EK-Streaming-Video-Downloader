import { BrowserWindow, ipcMain, nativeTheme } from "electron";
import { checkForUpdates } from "./services/updater.js";
import { readSettings, resetSettings, writeSettings, type AppSettings } from "./services/settings.js";

let settingsWindow: BrowserWindow | null = null;

function html() {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark"><style>
  :root{font:14px "Segoe UI",sans-serif;color:#152033;background:#f5f7fb}*{box-sizing:border-box}body{margin:0;padding:24px;background:#f5f7fb;color:#152033}h1{font-size:21px;margin:0 0 14px}hr{border:0;border-top:1px solid #dce3ee;margin:0 0 18px}.row{display:flex;align-items:center;justify-content:space-between;gap:18px;margin:14px 0}.column{display:grid;gap:5px}.hint{font-size:12px;color:#667085;margin:-7px 0 5px 24px}.segmented{display:flex;border:1px solid #c8d2e1;border-radius:7px;overflow:hidden}.segmented button{border:0;border-right:1px solid #c8d2e1;padding:6px 13px;background:#fff;color:#344054}.segmented button:last-child{border:0}.segmented button.active{background:#2563eb;color:#fff}select,button{font:inherit}select{min-width:210px;padding:6px 8px;border:1px solid #c8d2e1;border-radius:7px;background:#fff;color:#152033}.spacer{height:16px}.footer{display:flex;align-items:flex-end;justify-content:space-between;border-top:1px solid #dce3ee;padding-top:16px}.right{display:grid;justify-items:end;gap:9px}.version{font-size:12px;color:#667085}.primary,.secondary{border:1px solid #b8c4d6;border-radius:7px;padding:7px 13px;background:#fff;color:#152033}.primary{border-color:#2563eb;background:#2563eb;color:#fff}input[type=checkbox]{width:16px;height:16px;accent-color:#2563eb}@media(prefers-color-scheme:dark){:root,body{background:#151b26;color:#edf2f7}.segmented button,select,.secondary{background:#242d3d;color:#edf2f7;border-color:#475569}.hint,.version{color:#aab4c4}hr,.footer{border-color:#344054}}
  </style></head><body><h1 id="title"></h1><hr><label class="row"><span id="launchLabel"></span><input id="launch" type="checkbox"></label><p class="hint" id="launchHint"></p><div class="row"><span id="themeLabel"></span><div class="segmented" id="theme"></div></div><label class="row"><span id="escLabel"></span><input id="esc" type="checkbox"></label><label class="row"><span id="quitLabel"></span><input id="quit" type="checkbox"></label><div class="row"><span id="languageLabel"></span><select id="language"><option value="zh-Hans">简体中文</option><option value="zh-Hant">繁體中文</option><option value="en">English</option></select></div><div class="spacer"></div><div class="footer"><button class="secondary" id="reset"></button><div class="right"><label><span id="autoLabel"></span> <input id="auto" type="checkbox"></label><div><span class="version" id="version"></span> <button class="primary" id="check"></button></div></div></div><script>
  const words={
    'zh-Hans':{title:'偏好设置',launch:'开机自启动',launchHint:'在当前 Windows 用户登录后自动启动',theme:'主题模式',themes:['跟随系统','浅色','深色'],esc:'按 Esc 键退出 EK StreamDL',quit:'关闭最后一个窗口时退出 EK StreamDL',language:'语言',reset:'恢复默认设置',auto:'自动检查更新',version:'当前版本',check:'检查更新'},
    'zh-Hant':{title:'偏好設定',launch:'開機時自動啟動',launchHint:'在目前 Windows 使用者登入後自動啟動',theme:'主題模式',themes:['跟隨系統','淺色','深色'],esc:'按 Esc 鍵退出 EK StreamDL',quit:'關閉最後一個視窗時退出 EK StreamDL',language:'語言',reset:'恢復預設值',auto:'自動檢查更新',version:'目前版本',check:'檢查更新'},
    en:{title:'Preferences',launch:'Launch at Login',launchHint:'Start automatically after the current Windows user signs in',theme:'Appearance',themes:['System','Light','Dark'],esc:'Quit EK StreamDL with the Esc key',quit:'Quit EK StreamDL when the last window is closed',language:'Language',reset:'Restore Defaults',auto:'Automatically Check for Updates',version:'Current version',check:'Check for Updates'}
  };let state;const ids={launch:'launchAtLogin',esc:'escToQuit',quit:'quitWhenLastWindowClosed',auto:'autoCheckForUpdates'};
  function render(){const w=words[state.language];document.documentElement.lang=state.language;title.textContent=w.title;launchLabel.textContent=w.launch;launchHint.textContent=w.launchHint;themeLabel.textContent=w.theme;escLabel.textContent=w.esc;quitLabel.textContent=w.quit;languageLabel.textContent=w.language;reset.textContent=w.reset;autoLabel.textContent=w.auto;version.textContent=w.version+': v'+window.ekSettings.version;check.textContent=w.check;language.value=state.language;for(const [id,key] of Object.entries(ids))document.getElementById(id).checked=state[key];theme.innerHTML='';['system','light','dark'].forEach((mode,index)=>{const b=document.createElement('button');b.textContent=w.themes[index];b.className=state.themeMode===mode?'active':'';b.onclick=()=>save({...state,themeMode:mode});theme.appendChild(b)});document.title=w.title}
  async function save(next){state=await window.ekSettings.save(next);render()}Object.entries(ids).forEach(([id,key])=>document.getElementById(id).onchange=e=>save({...state,[key]:e.target.checked}));language.onchange=e=>save({...state,language:e.target.value});reset.onclick=async()=>{state=await window.ekSettings.reset(state.language);render()};check.onclick=()=>window.ekSettings.checkUpdate(state.language);window.ekSettings.get().then(value=>{state=value;render()});
  </script></body></html>`;
}

export function registerSettingsHandlers(onChanged: (settings: AppSettings) => void) {
  ipcMain.handle("settings:get", () => readSettings());
  ipcMain.handle("settings:save", (_event, next: AppSettings) => {
    writeSettings(next);
    nativeTheme.themeSource = next.themeMode;
    onChanged(next);
    return next;
  });
  ipcMain.handle("settings:reset", (_event, language: AppSettings["language"]) => {
    const next = resetSettings(language);
    nativeTheme.themeSource = next.themeMode;
    onChanged(next);
    return next;
  });
  ipcMain.handle("settings:check-update", (_event, language: AppSettings["language"]) => checkForUpdates(true, language));
}

export function showSettingsWindow(preloadPath: string) {
  if (settingsWindow && !settingsWindow.isDestroyed()) {
    settingsWindow.show();
    settingsWindow.focus();
    return;
  }
  settingsWindow = new BrowserWindow({
    width: 560,
    height: 500,
    minWidth: 560,
    maxWidth: 560,
    minHeight: 500,
    maxHeight: 500,
    resizable: false,
    maximizable: false,
    autoHideMenuBar: true,
    title: "偏好设置",
    backgroundColor: "#f5f7fb",
    webPreferences: { preload: preloadPath, contextIsolation: true, nodeIntegration: false },
  });
  void settingsWindow.loadURL(`data:text/html;charset=utf-8,${encodeURIComponent(html())}`);
  settingsWindow.on("closed", () => { settingsWindow = null; });
}
