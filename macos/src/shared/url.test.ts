import { describe, expect, it } from "vitest";
import { detectPlatform, extractUrlFromText, normalizeUrl } from "./url";

const supportedSamples = [
  ["https://weixin.qq.com/sph/AvvPlOuAld", "wechatChannels"],
  ["https://weixin.qq.com/sph/AFTX7zENB5", "wechatChannels"],
  ["https://b23.tv/5rk4QPl", "bilibili"],
  ["https://b23.tv/3RB2LDv", "bilibili"],
  ["http://xhslink.com/o/3cY3K10KClX", "xiaohongshu"],
  ["http://xhslink.com/o/5cyhhhFC4gc", "xiaohongshu"],
  ["https://v.kuaishou.com/7E63UWf3", "kuaishou"],
  ["https://v.kuaishou.com/nSo27v9J", "kuaishou"],
  ["https://v.douyin.com/yD0HBXAQDHU/", "douyin"],
  ["https://v.douyin.com/GoTmu1Nr3fg/", "douyin"],
  ["https://m.toutiao.com/is/UVuCRYBjsfs/", "toutiao"],
  ["https://m.toutiao.com/is/uZ6cPUIgLfc/", "toutiao"],
] as const;

describe("platform URL recognition", () => {
  it.each(supportedSamples)("recognizes %s", (url, platform) => {
    expect(detectPlatform(url)).toBe(platform);
  });

  it.each([
    "https://bilibili.com.evil.example/video/BV1",
    "https://notdouyin.com/video/1",
    "https://xhslink.com.evil.example/o/1",
    "https://weixin.qq.com.evil.example/sph/abc",
    "https://weixin.qq.com/sph/",
  ])("rejects deceptive or incomplete URL %s", (url) => {
    expect(detectPlatform(url)).toBeNull();
  });

  it("accepts the official WeChat Channels preview form", () => {
    expect(
      detectPlatform("https://channels.weixin.qq.com/finder-preview/pages/sph?id=Arj6Dl4W8v"),
    ).toBe("wechatChannels");
  });

  it("accepts the official Kuaishou redirect domain without accepting lookalikes", () => {
    expect(detectPlatform("https://abc.m.chenzhongtech.com/fw/long-video/123")).toBe("kuaishou");
    expect(detectPlatform("https://chenzhongtech.com.evil.example/fw/long-video/123")).toBeNull();
  });
});

describe("shared text extraction", () => {
  it("extracts a URL without swallowing Chinese punctuation", () => {
    const text = "复制打开抖音，看看 https://v.douyin.com/yD0HBXAQDHU/，快来看";
    expect(extractUrlFromText(text)).toBe("https://v.douyin.com/yD0HBXAQDHU/");
  });

  it("removes fragments while preserving query parameters", () => {
    expect(normalizeUrl("https://m.toutiao.com/is/abc/?x=1#fragment")).toBe(
      "https://m.toutiao.com/is/abc/?x=1",
    );
  });
});
