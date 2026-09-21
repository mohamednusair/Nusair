@echo off
title Clean Temp Files
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo.
    echo  Asking for administrator permission - please click YES.
    echo.
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

cls
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Clean-TempFiles.ps1"

echo.
pause
