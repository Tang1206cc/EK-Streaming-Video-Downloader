import { describe, expect, it } from "vitest";
import { translate, translateDynamicText } from "./i18n";

describe("application localization", () => {
  it("provides polished platform and action labels in all supported languages", () => {
    expect(translate("微信视频号", "zh-Hans")).toBe("微信视频号");
    expect(translate("微信视频号", "zh-Hant")).toBe("微信影片號");
    expect(translate("微信视频号", "en")).toBe("WeChat Channels");
    expect(translate("微信视频号", "ja")).toBe("WeChat Channels");
    expect(translate("配置所需环境", "en")).toBe("Set Up Requirements");
    expect(translate("配置所需环境", "ja")).toBe("要件の設定");
  });

  it("keeps user paths intact while localizing completion messages", () => {
    expect(translateDynamicText("已完成：/Users/example/视频.mp4", "en")).toBe(
      "Completed: /Users/example/视频.mp4",
    );
  });

  it("localizes collection progress without changing its counters", () => {
    expect(translateDynamicText("第 2/5 集：准备下载", "en")).toBe(
      "Episode 2/5: Preparing download",
    );
    expect(translateDynamicText("第 2/5 集：准备下载", "ja")).toBe(
      "第 2/5 話：ダウンロードの準備中",
    );
  });

  it("never exposes an untranslated Simplified Chinese backend error in English", () => {
    expect(translateDynamicText("下载失败：平台返回了未知媒体数据", "en")).toBe(
      "Download failed. The media source may have expired, denied access, or require parsing again.",
    );
    expect(translateDynamicText("下载失败：平台返回了未知媒体数据", "ja")).toBe(
      "ダウンロードに失敗しました。メディアの配信元が無効、アクセス拒否、または再解析が必要な可能性があります。",
    );
  });
});
