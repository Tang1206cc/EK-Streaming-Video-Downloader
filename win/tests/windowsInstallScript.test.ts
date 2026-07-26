import { describe, expect, it } from "vitest";
import { buildWindowsInstallScript } from "../electron/services/windowsInstallScript.js";

describe("Windows update replacement script", () => {
  it("stages and validates the whole new version before switching directories", () => {
    const script = buildWindowsInstallScript();
    const stage = script.indexOf("Copy-Item -LiteralPath $_.FullName -Destination $Candidate");
    const preserveUninstaller = script.indexOf("Where-Object { $_.Name -match '^uninstall.*\\.exe$' }");
    const validate = script.indexOf("Test-Path -LiteralPath $CandidateExecutable -PathType Leaf");
    const backup = script.indexOf("Move-Item -LiteralPath $Target -Destination $Backup");
    const activate = script.indexOf("Move-Item -LiteralPath $Candidate -Destination $Target");

    expect(stage).toBeGreaterThan(-1);
    expect(preserveUninstaller).toBeGreaterThan(stage);
    expect(validate).toBeGreaterThan(preserveUninstaller);
    expect(backup).toBeGreaterThan(validate);
    expect(activate).toBeGreaterThan(backup);
    expect(script).not.toContain("Copy-Item -Path (Join-Path $Source '*') -Destination $Target");
  });

  it("restores the prior directory and restarts it when activation fails", () => {
    const script = buildWindowsInstallScript();

    expect(script).toContain("Move-Item -LiteralPath $Target -Destination $Failed");
    expect(script).toContain("Move-Item -LiteralPath $Backup -Destination $Target");
    expect(script).toContain("Start-Process -FilePath (Join-Path $Target $Executable)");
    expect(script).not.toContain("Remove-Item");
  });
});
