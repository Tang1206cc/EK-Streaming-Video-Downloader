import { bilibiliAdapter } from "./bilibiliAdapter";
import { douyinAdapter } from "./douyinAdapter";
import { kuaishouAdapter } from "./kuaishouAdapter";
import { toutiaoAdapter } from "./toutiaoAdapter";
import { wechatChannelsAdapter } from "./wechatChannelsAdapter";
import { xiaohongshuAdapter } from "./xiaohongshuAdapter";
import type { PlatformAdapter } from "./types";

export const macosAdapters: PlatformAdapter[] = [
  bilibiliAdapter,
  douyinAdapter,
  kuaishouAdapter,
  xiaohongshuAdapter,
  toutiaoAdapter,
  wechatChannelsAdapter,
];
