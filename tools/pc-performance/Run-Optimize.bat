@echo off
title PC Performance Optimiser
cd /d "%~dp0"

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator rights...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo.
echo  This will first PREVIEW the changes without altering anything.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-PC.ps1"

echo.
set /p GO="Apply these fixes now? (Y/N): "
if /i not "%GO%"=="Y" goto :done

echo.
set /p HOT="Does the laptop run hot with loud fans? (Y/N): "
if /i "%HOT%"=="Y" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-PC.ps1" -Apply -ThermalFix
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-PC.ps1" -Apply
)

:done
echo.
pause
