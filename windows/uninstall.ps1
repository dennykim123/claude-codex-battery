param(
    [switch]$RemoveCachedUsage
)

$ErrorActionPreference = "Stop"
$installDir = Join-Path $env:LOCALAPPDATA "ClaudeCodexBattery"
$stateDir = Join-Path $env:USERPROFILE ".claude\swiftbar"
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"

Remove-ItemProperty -Path $regPath -Name "ClaudeCodexBattery" -ErrorAction SilentlyContinue
Get-Process -Name "ClaudeCodexBattery" -ErrorAction SilentlyContinue | Stop-Process -Force

if (Test-Path -LiteralPath $installDir) {
    $resolvedInstallDir = (Resolve-Path -LiteralPath $installDir).Path
    $expectedInstallDir = [System.IO.Path]::GetFullPath($installDir)
    if ($resolvedInstallDir -ne $expectedInstallDir) {
        throw "Refusing to remove an unexpected install directory: $resolvedInstallDir"
    }
    Remove-Item -LiteralPath $resolvedInstallDir -Recurse -Force
}

if ($RemoveCachedUsage -and (Test-Path -LiteralPath $stateDir)) {
    Remove-Item -LiteralPath (Join-Path $stateDir ".claude-usage-windows.json") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stateDir ".codex-usage-windows.json") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stateDir ".skin") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stateDir ".windows-window-settings") -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $stateDir ".windows-window-position") -Force -ErrorAction SilentlyContinue
}

Write-Host "Claude & Codex Battery was removed." -ForegroundColor Green
