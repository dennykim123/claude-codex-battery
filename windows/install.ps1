param(
    [switch]$EnableAutoStart,
    [switch]$DisableAutoStart,
    [switch]$NoLaunch
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$sourceFile = Join-Path $scriptDir "ClaudeCodexBattery.cs"
$installDir = Join-Path $env:LOCALAPPDATA "ClaudeCodexBattery"
$outputExe = Join-Path $installDir "ClaudeCodexBattery.exe"

if ($EnableAutoStart -and $DisableAutoStart) {
    throw "Choose either -EnableAutoStart or -DisableAutoStart, not both."
}

$compilerCandidates = @(
    (Join-Path $env:SystemRoot "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
    (Join-Path $env:SystemRoot "Microsoft.NET\Framework\v4.0.30319\csc.exe")
)
$cscPath = $compilerCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $cscPath) {
    throw "The .NET Framework C# compiler (csc.exe) was not found."
}

Write-Host "Building Claude & Codex Battery for Windows..." -ForegroundColor Cyan
Get-Process -Name "ClaudeCodexBattery" -ErrorAction SilentlyContinue | Stop-Process -Force
New-Item -ItemType Directory -Path $installDir -Force | Out-Null

& $cscPath /nologo /target:winexe /out:$outputExe /r:System.dll /r:System.Drawing.dll /r:System.Web.Extensions.dll /r:System.Windows.Forms.dll $sourceFile
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $outputExe)) {
    throw "Compilation failed."
}

$regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if ($EnableAutoStart) {
    Set-ItemProperty -Path $regPath -Name "ClaudeCodexBattery" -Value ('"{0}"' -f $outputExe)
    Write-Host "Start at login enabled." -ForegroundColor Green
} elseif ($DisableAutoStart) {
    Remove-ItemProperty -Path $regPath -Name "ClaudeCodexBattery" -ErrorAction SilentlyContinue
    Write-Host "Start at login disabled." -ForegroundColor Yellow
} else {
    $existingAutoStart = Get-ItemProperty -Path $regPath -Name "ClaudeCodexBattery" -ErrorAction SilentlyContinue
    if ($existingAutoStart) {
        Set-ItemProperty -Path $regPath -Name "ClaudeCodexBattery" -Value ('"{0}"' -f $outputExe)
        Write-Host "Existing start-at-login preference preserved." -ForegroundColor Green
    } else {
        Write-Host "Start at login is off. Enable it later from Settings or rerun with -EnableAutoStart." -ForegroundColor Yellow
    }
}

if (-not $NoLaunch) {
    Start-Process -FilePath $outputExe
}

Write-Host "Installed: $outputExe" -ForegroundColor Green
