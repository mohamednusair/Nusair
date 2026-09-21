@echo off
title PC Performance Diagnosis
cd /d "%~dp0"

:: Re-launch elevated if we are not already admin
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Diagnose-PC.ps1"

echo.
echo ============================================================
echo  Diagnosis finished. The report was saved to your Desktop.
echo ============================================================
echo.
pause
