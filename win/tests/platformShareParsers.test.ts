import { describe, expect, it } from "vitest";
import {
  parseDouyinSharePage,
  parseKuaishouSharePage,
  parseToutiaoSharePage,
  parseToutiaoVodProfile,
} from "../electron/services/platformShareParsers";

describe("Windows public share-page parsers", () => {
  it("extracts a no-watermark Douyin video profile", () => {
    const router = {
      loaderData: {
        "video_(id)/page": {
          videoInfoRes: {
            item_list: [{
              aweme_id: "7615085365619988837",
              desc: "无能的人，都有这几个通病",
              create_time: 1_773_025_227,
              author: { nickname: "新时代沸腾青年" },
              video: {
                duration: 29_188,
                play_addr: {
                  uri: "v2800-test",
                  url_list: ["https://aweme.snssdk.com/aweme/v1/playwm/?video_id=v2800-test"],
                  data_size: 2_900_000,
                },
                cover: { url_list: ["https://example.com/cover.jpg"] },
              },
            }],
          },
        },
      },
    };
    const profile = parseDouyinSharePage(
      `<script>window._ROUTER_DATA = ${JSON.stringify(router)}</script>`,
      "https://www.iesdouyin.com/share/video/7615085365619988837/",
    );
    expect(profile).toMatchObject({
      id: "7615085365619988837",
      author: "新时代沸腾青年",
      durationSeconds: 29.188,
      kind: "video",
    });
    expect(profile?.mediaUrl).toContain("/play/");
    expect(profile?.mediaUrl).not.toContain("/playwm/");
  });

  it("keeps Douyin image and audio assets for local composition", () => {
    const router = {
      loaderData: {
        "note_(id)/page": {
          videoInfoRes: {
            item_list: [{
              aweme_id: "note-1",
              desc: "图文作品",
              author: { nickname: "作者" },
              music: { duration: 12 },
              video: { play_addr: { uri: "https://example.com/audio.mp3" } },
              images: [
                { url_list: ["https://example.com/1.jpg"] },
                { download_url_list: ["https://example.com/2.jpg"] },
              ],
            }],
          },
        },
      },
    };
    const profile = parseDouyinSharePage(
      `<script>window._ROUTER_DATA = ${JSON.stringify(router)}</script>`,
      "https://www.douyin.com/note/note-1",
    );
    expect(profile).toMatchObject({
      kind: "image-post",
      audioUrl: "https://example.com/audio.mp3",
      imageUrls: ["https://example.com/1.jpg", "https://example.com/2.jpg"],
    });
  });

  it("selects the highest Kuaishou representation", () => {
    const state = {
      page: {
        photo: {
          photoId: "3xdwgpc8zkhgefu",
          caption: "赛后给轮胎疯狂去死皮？",
          userName: "老牛科普",
          duration: 70_766,
          mainMvUrls: [{ url: "https://example.com/fallback.mp4" }],
          manifest: {
            adaptationSet: [{
              representation: [
                { id: 1, height: 720, avgBitrate: 1200, fileSize: 10_000, url: "https://example.com/720.mp4" },
                { id: 2, height: 1080, avgBitrate: 2200, fileSize: 20_000, url: "https://example.com/1080.mp4" },
              ],
            }],
          },
        },
      },
    };
    const profile = parseKuaishouSharePage(
      `<script>window.INIT_STATE = ${JSON.stringify(state)}</script>`,
      "https://example.m.chenzhongtech.com/fw/photo/3xdwgpc8zkhgefu?photoId=3xdwgpc8zkhgefu",
    );
    expect(profile).toMatchObject({
      id: "3xdwgpc8zkhgefu",
      durationSeconds: 70.766,
      mediaUrl: "https://example.com/1080.mp4",
    });
  });

  it("decodes Toutiao render data and VOD formats", () => {
    const playQuery = "Action=GetPlayInfo&video_id=test";
    const token = Buffer.from(JSON.stringify({ GetPlayInfoToken: playQuery })).toString("base64");
    const renderData = encodeURIComponent(JSON.stringify({
      articleInfo: {
        gid: "7664825753535512610",
        title: "辣皮子炖排骨",
        publishTime: "1784606313",
        mediaUser: { screenName: "简简厨房" },
        posterUrl: "https://example.com/poster.jpg",
        videoDuration: 203,
        playAuthTokenV2: token,
      },
    }));
    const page = parseToutiaoSharePage(
      `<script id="RENDER_DATA" type="application/json">${renderData}</script>`,
    );
    expect(page?.playQuery).toBe(playQuery);
    const profile = page && parseToutiaoVodProfile({
      Result: {
        Data: {
          Status: 10,
          Duration: 203,
          PlayInfoList: [
            { Height: 720, Bitrate: 1000, MainPlayUrl: "https://example.com/720.mp4", Size: 10_000 },
            { Height: 1080, Bitrate: 2000, MainPlayUrl: "https://example.com/1080.mp4", Size: 20_000 },
          ],
        },
      },
    }, page, "https://m.toutiao.com/video/7664825753535512610/");
    expect(profile).toMatchObject({
      title: "辣皮子炖排骨",
      author: "简简厨房",
      mediaUrl: "https://example.com/1080.mp4",
    });
  });
});
