import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { StringDecoder } from "node:string_decoder";

export type ProcessResult = {
  exitCode: number;
  stdout: string;
  stderr: string;
};

export function runProcess(
  executable: string,
  args: string[],
  options: {
    timeoutMs?: number;
    onLine?: (line: string) => void;
    onSpawn?: (child: ChildProcessWithoutNullStreams) => void;
    cwd?: string;
  } = {},
): Promise<ProcessResult> {
  return new Promise((resolve, reject) => {
    const child = spawn(executable, args, {
      windowsHide: true,
      cwd: options.cwd,
      env: { ...process.env, PYTHONUTF8: "1", PYTHONIOENCODING: "utf-8" },
    });
    options.onSpawn?.(child);
    let stdout = "";
    let stderr = "";
    let pendingOut = "";
    let pendingErr = "";
    const stdoutDecoder = new StringDecoder("utf8");
    const stderrDecoder = new StringDecoder("utf8");
    const emitText = (text: string, isError: boolean) => {
      if (!text) return;
      if (isError) stderr += text;
      else stdout += text;
      let pending = (isError ? pendingErr : pendingOut) + text;
      const lines = pending.split(/\r?\n/);
      pending = lines.pop() ?? "";
      if (isError) pendingErr = pending;
      else pendingOut = pending;
      lines.forEach((line) => options.onLine?.(line));
    };
    child.stdout.on("data", (chunk: Buffer) => emitText(stdoutDecoder.write(chunk), false));
    child.stderr.on("data", (chunk: Buffer) => emitText(stderrDecoder.write(chunk), true));
    child.once("error", reject);

    const timeout = options.timeoutMs
      ? setTimeout(() => {
          terminateProcessTree(child);
          reject(new Error("操作超时，请检查网络后重试"));
        }, options.timeoutMs)
      : null;

    child.once("close", (code) => {
      if (timeout) clearTimeout(timeout);
      emitText(stdoutDecoder.end(), false);
      emitText(stderrDecoder.end(), true);
      if (pendingOut) options.onLine?.(pendingOut);
      if (pendingErr) options.onLine?.(pendingErr);
      resolve({ exitCode: code ?? -1, stdout, stderr });
    });
  });
}

export function terminateProcessTree(child: ChildProcessWithoutNullStreams | undefined) {
  if (!child?.pid || child.killed) return;
  if (process.platform === "win32") {
    const killer = spawn("taskkill.exe", ["/PID", String(child.pid), "/T", "/F"], {
      windowsHide: true,
      stdio: "ignore",
    });
    killer.unref();
  } else {
    child.kill("SIGTERM");
  }
}

const suspendScript = String.raw`
$signature = @'
using System;
using System.Runtime.InteropServices;
public static class EkProcessControl {
  [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr handle);
  [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr handle);
}
'@
Add-Type -TypeDefinition $signature -ErrorAction SilentlyContinue
$targetId = [int]$args[0]
$ids = New-Object System.Collections.Generic.List[int]
function Add-EkChildren([int]$parentId) {
  $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$parentId" -ErrorAction SilentlyContinue
  foreach ($child in $children) {
    Add-EkChildren ([int]$child.ProcessId)
    $ids.Add([int]$child.ProcessId)
  }
}
Add-EkChildren $targetId
$ids.Add($targetId)
if ($args[1] -eq 'resume') { $ids.Reverse() }
foreach ($id in $ids) {
  $p = Get-Process -Id $id -ErrorAction SilentlyContinue
  if ($null -eq $p) { continue }
  if ($args[1] -eq 'pause') { [EkProcessControl]::NtSuspendProcess($p.Handle) | Out-Null }
  else { [EkProcessControl]::NtResumeProcess($p.Handle) | Out-Null }
}
`;

export async function setProcessPaused(pid: number, paused: boolean) {
  if (process.platform !== "win32") {
    process.kill(pid, paused ? "SIGSTOP" : "SIGCONT");
    return;
  }
  const result = await runProcess(
    "powershell.exe",
    ["-NoProfile", "-NonInteractive", "-Command", suspendScript, String(pid), paused ? "pause" : "resume"],
    { timeoutMs: 15_000 },
  );
  if (result.exitCode !== 0) {
    throw new Error(paused ? "暂停下载失败" : "继续下载失败");
  }
}
