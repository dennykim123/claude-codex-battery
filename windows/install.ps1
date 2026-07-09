# install.ps1 — build & install the Claude/Codex battery tray app (Windows)
# Compiles ClaudeCodexBattery.cs with the csc.exe bundled in every Windows
# (.NET Framework 4.x) — no SDK, no runtime install, no dependencies.
$ErrorActionPreference = "Stop"

$src = Join-Path $PSScriptRoot "ClaudeCodexBattery.cs"
if (-not (Test-Path $src)) { throw "source not found: $src" }

$dstDir = Join-Path $env:LOCALAPPDATA "ClaudeCodexBattery"
New-Item -ItemType Directory -Force $dstDir | Out-Null
$exe = Join-Path $dstDir "ClaudeCodexBattery.exe"

$csc = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe" }
if (-not (Test-Path $csc)) { throw ".NET Framework csc.exe not found — is this Windows 10/11?" }

# stop a running instance so the exe can be replaced
Get-Process ClaudeCodexBattery -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 300

& $csc /nologo /target:winexe /optimize+ /codepage:65001 /out:"$exe" `
    /r:System.Windows.Forms.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll `
    "$src"
if ($LASTEXITCODE -ne 0) { throw "build failed (csc exit $LASTEXITCODE)" }

# register auto-start at login (per-user, no admin needed)
New-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" `
    -Name "ClaudeCodexBattery" -Value "`"$exe`"" -PropertyType String -Force | Out-Null

Start-Process $exe

# Windows 11 hides new tray icons by default — promote ours to always-visible
Start-Sleep -Seconds 4
Get-ChildItem "HKCU:\Control Panel\NotifyIconSettings" -ErrorAction SilentlyContinue | ForEach-Object {
    $p = Get-ItemProperty $_.PSPath
    if ($p.ExecutablePath -like "*ClaudeCodexBattery*") {
        Set-ItemProperty $_.PSPath -Name IsPromoted -Value 1 -Type DWord
    }
}

Write-Host "Installed: $exe"
Write-Host "Tray batteries should appear within a few seconds (check the taskbar overflow area)."
Write-Host "Auto-start at login: registered. To remove everything: .\uninstall.ps1"
