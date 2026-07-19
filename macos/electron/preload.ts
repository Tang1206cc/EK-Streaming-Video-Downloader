import { contextBridge } from "electron";

contextBridge.exposeInMainWorld("ekStreamDLDesktop", {
  platform: process.platform,
});
