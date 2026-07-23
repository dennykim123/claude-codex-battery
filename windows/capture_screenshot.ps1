# capture_screenshot.ps1 - Automated screenshot capture of the Windows Flyout UI
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$exePath = Join-Path $ScriptDir "ClaudeCodexBattery.exe"

# Stop previous instance and start fresh with --show --pin flags
Get-Process -Name "ClaudeCodexBattery" -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 500

Start-Process -FilePath $exePath -ArgumentList "--show --pin"
Start-Sleep -Seconds 2

Write-Host "Capturing Centered Dashboard Flyout UI screenshot..." -ForegroundColor Cyan

# Screen dimensions
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
$width = 420
$height = 360
$x = [int]($screen.Width / 2 - $width / 2)
$y = [int]($screen.Height / 2 - $height / 2)

$bmp = New-Object System.Drawing.Bitmap $width, $height
$graphics = [System.Drawing.Graphics]::FromImage($bmp)
$graphics.CopyFromScreen($x, $y, 0, 0, (New-Object System.Drawing.Size $width, $height))

$docsDir = Join-Path $ScriptDir "docs"
if (-not (Test-Path $docsDir)) { New-Item -ItemType Directory -Path $docsDir | Out-Null }
$outputImage = Join-Path $docsDir "screenshot.png"
$bmp.Save($outputImage, [System.Drawing.Imaging.ImageFormat]::Png)

$graphics.Dispose()
$bmp.Dispose()

Write-Host "✅ Screenshot captured: $outputImage" -ForegroundColor Green
