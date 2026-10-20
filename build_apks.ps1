# ==========================================================================
# One-click APK build script (arm64-v8a, release, debug signed)
# Output copied to the parent directory:
#   <kong-tiao-yao-kong>-arm64-v8a.apk
# Usage: double-click build_apks.cmd, or run  .\build_apks.ps1
# NOTE: keep this file ASCII-only. Chinese file names are built from
#       [char] code points so Windows PowerShell 5.1 parses them correctly.
# ==========================================================================
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $root

# --- Build environment (existing env vars are not overridden) ---
if (-not $env:PUB_CACHE) { $env:PUB_CACHE = 'C:\Users\jacker\.pub-cache' }
if (-not $env:JAVA_HOME) { $env:JAVA_HOME = 'D:\Android\Android Studio\jbr' }

$outDir = Join-Path $root 'build\app\outputs\flutter-apk'
$distDir = Split-Path -Parent $root
$dstName = (-join ([char]0x7A7A, [char]0x8C03, [char]0x9065, [char]0x63A7)) + '-arm64-v8a.apk'

Write-Host "========== Building arm64 release APK ==========" -ForegroundColor Cyan
flutter build apk --release --split-per-abi --target-platform android-arm64
if ($LASTEXITCODE -ne 0) { throw 'build failed' }

$src = Join-Path $outDir 'app-arm64-v8a-release.apk'
if (-not (Test-Path $src)) { throw "artifact not found: $src" }
$dst = Join-Path $distDir $dstName
Copy-Item $src $dst -Force
$size = [math]::Round((Get-Item $dst).Length / 1MB, 1)
Write-Host "output: $dst ($size MB)" -ForegroundColor Green
