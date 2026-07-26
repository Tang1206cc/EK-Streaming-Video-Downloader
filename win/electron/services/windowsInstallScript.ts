export function buildWindowsInstallScript() {
  return String.raw`param([int]$ProcessId,[string]$Source,[string]$Target,[string]$Executable)
$ErrorActionPreference='Stop'
$TransactionId=[guid]::NewGuid().ToString('N')
$Candidate="$Target.update-$TransactionId"
$Backup="$Target.backup-$TransactionId"
$Failed="$Target.failed-$TransactionId"
$Log=Join-Path $env:TEMP "EKStreamDL-Updater-$TransactionId.log"

function Write-EkUpdateLog([string]$Message) {
  try {
    Add-Content -LiteralPath $Log -Value "$(Get-Date -Format o) $Message" -Encoding UTF8 -ErrorAction Stop
  }
  catch {
    # 日志写入失败不得阻断目录切换或回滚。
  }
}

try {
  Write-EkUpdateLog "等待应用退出"
  Wait-Process -Id $ProcessId -Timeout 120 -ErrorAction SilentlyContinue

  Write-EkUpdateLog "将新版本完整暂存到 $Candidate"
  New-Item -ItemType Directory -Path $Candidate | Out-Null
  Get-ChildItem -LiteralPath $Source -Force | ForEach-Object {
    Copy-Item -LiteralPath $_.FullName -Destination $Candidate -Recurse -Force
  }
  if (Test-Path -LiteralPath $Target) {
    Get-ChildItem -LiteralPath $Target -Force -File |
      Where-Object { $_.Name -match '^uninstall.*\.exe$' } |
      Copy-Item -Destination $Candidate -Force
  }
  $CandidateExecutable=Join-Path $Candidate $Executable
  if (!(Test-Path -LiteralPath $CandidateExecutable -PathType Leaf)) {
    throw "暂存目录中缺少主程序：$Executable"
  }

  if (Test-Path -LiteralPath $Target) {
    Write-EkUpdateLog "将当前版本备份到 $Backup"
    Move-Item -LiteralPath $Target -Destination $Backup
  }
  Write-EkUpdateLog "切换到已验证的新版本"
  Move-Item -LiteralPath $Candidate -Destination $Target
  Start-Process -FilePath (Join-Path $Target $Executable)
  Write-EkUpdateLog "更新完成；旧版本备份保留在 $Backup"
  exit 0
}
catch {
  Write-EkUpdateLog "更新失败：$($_.Exception.Message)"
  if ((Test-Path -LiteralPath $Backup) -and (Test-Path -LiteralPath $Target)) {
    Move-Item -LiteralPath $Target -Destination $Failed
    Write-EkUpdateLog "失败的新版本保留在 $Failed"
  }
  if ((Test-Path -LiteralPath $Backup) -and !(Test-Path -LiteralPath $Target)) {
    Move-Item -LiteralPath $Backup -Destination $Target
    Start-Process -FilePath (Join-Path $Target $Executable)
    Write-EkUpdateLog "已恢复并启动更新前版本"
  }
  exit 1
}
`;
}
