import type { NativeVideoBridge } from "./types";

export function getNativeBridge(): NativeVideoBridge | null {
  return window.ekStreamDLDesktop?.nativeBridge ?? null;
}
