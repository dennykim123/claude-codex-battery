# install.ps1 - Native Windows Build & Installation Script for claude-codex-battery
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -ErrorAction SilentlyContinue

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Set-Location $ScriptDir

Write-Host "🔋 [Claude & Codex Battery] Building Native Windows Port..." -ForegroundColor Cyan

# 1. Locate csc.exe (.NET Framework C# Compiler)
$cscPath = Get-ChildItem -Path "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
if (-not $cscPath) {
    $cscPath = Get-ChildItem -Path "$env:SystemRoot\Microsoft.NET\Framework\v4.0.30319\csc.exe" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName -First 1
}

if (-not $cscPath) {
    Write-Error "Could not find csc.exe compiler in .NET Framework directory."
    exit 1
}

Write-Host "Found C# Compiler: $cscPath" -ForegroundColor Gray

# 2. Compile ClaudeCodexBattery.cs into GUI Executable (.exe)
$outputExe = Join-Path $ScriptDir "ClaudeCodexBattery.exe"
$sourceFile = Join-Path $ScriptDir "ClaudeCodexBattery.cs"

# Stop existing running instance if any
Get-Process -Name "ClaudeCodexBattery" -ErrorAction SilentlyContinue | Stop-Process -Force

$compileCmd = "& `"$cscPath`" /target:winexe /out:`"$outputExe`" /r:System.dll /r:System.Drawing.dll /r:System.Windows.Forms.dll `"$sourceFile`""
Invoke-Expression $compileCmd

if (Test-Path $outputExe) {
    Write-Host "✅ Successfully compiled: $outputExe" -ForegroundColor Green
} else {
    Write-Error "Compilation failed."
    exit 1
}

# 3. Add to Windows Startup (Registry)
$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
Set-ItemProperty -Path $regPath -Name "ClaudeCodexBattery" -Value "`"$outputExe`"" -ErrorAction SilentlyContinue

# 4. Launch Application
Start-Process -FilePath $outputExe
Write-Host "🚀 ClaudeCodexBattery is running! Check your System Tray (bottom right)." -ForegroundColor Green
