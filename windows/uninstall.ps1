# uninstall.ps1 - Uninstallation Script for claude-codex-battery Windows Port
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
Remove-ItemProperty -Path $regPath -Name "ClaudeCodexBattery" -ErrorAction SilentlyContinue

Get-Process -Name "ClaudeCodexBattery" -ErrorAction SilentlyContinue | Stop-Process -Force
Write-Host "✅ Stopped process and removed startup entry." -ForegroundColor Green
