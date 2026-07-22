export function parseReleaseVersion(value: string) {
  const match = value.trim().match(/^v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?$/i);
  if (!match) return null;
  return [Number(match[1]), Number(match[2]), Number(match[3])] as const;
}

export function isNewerVersion(remote: readonly number[], local: readonly number[]) {
  for (let index = 0; index < 3; index += 1) {
    if (remote[index] !== local[index]) return remote[index] > local[index];
  }
  return false;
}

export function windowsReleaseAssetName(version: string) {
  return `windows-x64-EK StreamDL-${version}.zip`;
}

export function checksumForFile(checksumList: string, fileName: string) {
  const escapedName = fileName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const pattern = new RegExp(`^([a-fA-F0-9]{64})\\s+\\*?${escapedName}$`);
  const hash = checksumList.split(/\r?\n/).map((line) => line.trim()).map((line) => line.match(pattern)?.[1]).find(Boolean);
  if (!hash) throw new Error(`校验清单中未找到 ${fileName}`);
  return hash.toLowerCase();
}
