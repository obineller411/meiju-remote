@echo off
chcp 65001 >nul
echo ========================================
echo   Building normal + disguise arm64 APKs
echo ========================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_apks.ps1"
echo.
pause
