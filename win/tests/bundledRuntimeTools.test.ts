import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { gunzipSync } from "node:zlib";
import { describe, expect, it } from "vitest";

const runtimeTools = path.resolve(import.meta.dirname, "../resources/runtime-tools");

function sha256(data: Buffer) {
  return crypto.createHash("sha256").update(data).digest("hex");
}

describe("bundled Windows runtime tools", () => {
  it("contains the verified yt-dlp baseline payload", () => {
    const payload = gunzipSync(fs.readFileSync(path.join(runtimeTools, "yt-dlp.exe.gz")));

    expect(sha256(payload)).toBe("52fe3c26dcf71fbdc85b528589020bb0b8e383155cfa81b64dd447bbe35e24b8");
  });

  it("contains the verified FFmpeg baseline payload", () => {
    const payload = gunzipSync(fs.readFileSync(path.join(runtimeTools, "ffmpeg.exe.gz")));

    expect(sha256(payload)).toBe("43b4a15188af58c736726b9a92da3054c5822faf2e1c3ebb1ed2dfdb856c7551");
  });
});
