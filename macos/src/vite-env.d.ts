/// <reference types="vite/client" />

import type { NativeVideoBridge } from "./shared/types";

declare global {
  interface Window {
    __ekStreamDLInitialRoute?: "video-downloader";
    __ekStreamDLLanguage?: "zh-Hans" | "zh-Hant" | "en";
    __ekStreamDLApplyLanguage?: (language: string) => void;
    ekStreamDLDesktop?: {
      platform: string;
      nativeBridge?: NativeVideoBridge;
    };
  }
}

export {};
