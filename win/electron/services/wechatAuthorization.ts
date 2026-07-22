import { BrowserWindow, session } from "electron";
import { appendDiagnostic } from "./diagnostics.js";

const YUANBAO_URL = "https://yuanbao.tencent.com/chat/naQivTmsDa/cf4d0079-ed1b-4c55-a3f3-2ca1379727d1";
const BROWSER_USER_AGENT =
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

type YuanbaoParseResponse = {
  code?: number;
  msg?: string;
  data?: {
    wx_export_id?: string;
    cover_url?: string;
    author?: string;
    desc?: string;
    playable_url?: string;
  };
};

type WebResponse = { status: number; body: string };

class WeChatAuthorizationService {
  private window: BrowserWindow | null = null;
  private needsFreshAuthorization = false;
  private userCancelled = false;

  private createWindow() {
    if (this.window && !this.window.isDestroyed()) return this.window;
    const window = new BrowserWindow({
      width: 920,
      height: 720,
      minWidth: 760,
      minHeight: 620,
      show: false,
      title: "微信视频号授权 · 腾讯元宝",
      autoHideMenuBar: true,
      webPreferences: {
        contextIsolation: true,
        nodeIntegration: false,
        partition: "persist:ek-streamdl-wechat-authorization",
      },
    });
    window.webContents.setUserAgent(BROWSER_USER_AGENT);
    window.on("close", (event) => {
      if (!window.isDestroyed()) {
        event.preventDefault();
        this.userCancelled = true;
        window.hide();
      }
    });
    this.window = window;
    return window;
  }

  private async preparedWindow() {
    const window = this.createWindow();
    const currentHost = (() => {
      try {
        return new URL(window.webContents.getURL()).hostname;
      } catch {
        return "";
      }
    })();
    if (!currentHost.endsWith("yuanbao.tencent.com")) {
      await window.loadURL(YUANBAO_URL, { userAgent: BROWSER_USER_AGENT });
    }
    return window;
  }

  private async isLoggedIn(window: BrowserWindow) {
    try {
      const status = await window.webContents.executeJavaScript(`
        fetch('/api/getuserinfo', { credentials: 'include', cache: 'no-store' })
          .then((response) => response.status)
          .catch(() => 0)
      `);
      return Number(status) === 200;
    } catch {
      return false;
    }
  }

  private async requestParseResult(window: BrowserWindow, shareURL: string): Promise<WebResponse> {
    return (await window.webContents.executeJavaScript(`
      (async () => {
        const response = await fetch('/api/weixin/get_parse_result', {
          method: 'POST', credentials: 'include', cache: 'no-store',
          headers: {
            'Accept': 'application/json, text/plain, */*',
            'Content-Type': 'application/json',
            'X-Requested-With': 'XMLHttpRequest',
            'X-Source': 'web',
            'X-Platform': 'windows',
            'X-Language': 'zh-CN',
            'X-Web-Third-Source': 'main',
            'X-AgentId': 'naQivTmsDa/cf4d0079-ed1b-4c55-a3f3-2ca1379727d1'
          },
          body: JSON.stringify({ type: 'video_channel_url', url: ${JSON.stringify(shareURL)}, scene: 1 })
        });
        return { status: response.status, body: await response.text() };
      })()
    `)) as WebResponse;
  }

  private decode(response: WebResponse): YuanbaoParseResponse {
    try {
      return JSON.parse(response.body) as YuanbaoParseResponse;
    } catch {
      throw new Error("下载失败：腾讯元宝返回了无法识别的解析数据");
    }
  }

  private isAuthorizationFailure(web: WebResponse, parsed: YuanbaoParseResponse) {
    return web.status === 401 || web.status === 403 || /登录|授权/.test(parsed.msg ?? "");
  }

  async parseIfAuthorized(shareURL: string) {
    if (this.needsFreshAuthorization) return null;
    try {
      const window = await this.preparedWindow();
      if (!(await this.isLoggedIn(window))) return null;
      const web = await this.requestParseResult(window, shareURL);
      const parsed = this.decode(web);
      if (web.status >= 200 && web.status < 300 && parsed.code === 0) return parsed;
      if (this.isAuthorizationFailure(web, parsed)) this.needsFreshAuthorization = true;
      return null;
    } catch {
      return null;
    }
  }

  async authorizedParse(shareURL: string, shouldCancel: () => boolean) {
    const window = await this.preparedWindow();
    for (let attempt = 0; attempt < 2; attempt += 1) {
      if (shouldCancel()) throw new Error("下载已取消");
      if (this.needsFreshAuthorization) {
        await this.clearAuthorization();
        await window.loadURL(YUANBAO_URL, { userAgent: BROWSER_USER_AGENT });
        this.needsFreshAuthorization = false;
      }
      if (!(await this.isLoggedIn(window))) {
        this.userCancelled = false;
        window.show();
        window.focus();
        const deadline = Date.now() + 300_000;
        while (!this.userCancelled && Date.now() < deadline) {
          if (shouldCancel()) throw new Error("下载已取消");
          if (await this.isLoggedIn(window)) break;
          await new Promise((resolve) => setTimeout(resolve, 1_000));
        }
        if (this.userCancelled) throw new Error("微信视频号授权已取消");
        if (!(await this.isLoggedIn(window))) throw new Error("微信视频号授权等待超时，请重新点击下载后登录");
      }
      const web = await this.requestParseResult(window, shareURL);
      const parsed = this.decode(web);
      if (web.status >= 200 && web.status < 300 && parsed.code === 0) {
        this.needsFreshAuthorization = false;
        window.hide();
        return parsed;
      }
      if (this.isAuthorizationFailure(web, parsed)) {
        this.needsFreshAuthorization = true;
        continue;
      }
      throw new Error(`下载失败：${parsed.msg?.trim() || `腾讯元宝解析服务响应异常（${web.status}）`}`);
    }
    throw new Error("下载失败：微信登录状态未生效，再次点击下载将重新发起授权");
  }

  async status() {
    if (this.needsFreshAuthorization) return false;
    try {
      return await this.isLoggedIn(await this.preparedWindow());
    } catch {
      return false;
    }
  }

  async clearAuthorization() {
    this.needsFreshAuthorization = true;
    this.userCancelled = true;
    const window = this.window;
    if (window && !window.isDestroyed()) {
      await window.webContents.executeJavaScript("localStorage.clear(); sessionStorage.clear(); true").catch(() => undefined);
      window.hide();
    }
    const authorizationSession = session.fromPartition("persist:ek-streamdl-wechat-authorization");
    const cookies = await authorizationSession.cookies.get({ domain: "yuanbao.tencent.com" });
    for (const cookie of cookies) {
      const secure = cookie.secure ? "https" : "http";
      const domain = cookie.domain?.replace(/^\./, "") || "yuanbao.tencent.com";
      await authorizationSession.cookies.remove(`${secure}://${domain}${cookie.path}`, cookie.name);
    }
    appendDiagnostic("微信视频号", "用户已清理当前腾讯元宝授权");
  }
}

export const weChatAuthorization = new WeChatAuthorizationService();
export { BROWSER_USER_AGENT };
