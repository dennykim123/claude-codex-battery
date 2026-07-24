# uninstall.ps1 — remove the Claude/Codex battery tray app (Windows)
$ErrorActionPreference = "SilentlyContinue"

Get-Process ClaudeCodexBattery | Stop-Process -Force
Start-Sleep -Milliseconds 300

Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "ClaudeCodexBattery"
Remove-Item -Recurse -Force (Join-Path $env:LOCALAPPDATA "ClaudeCodexBattery")
Remove-Item -Recurse -Force (Join-Path $env:USERPROFILE ".claude\ccbattery")

Write-Host "Uninstalled. (Tray icons disappear immediately; nothing else was touched.)"
