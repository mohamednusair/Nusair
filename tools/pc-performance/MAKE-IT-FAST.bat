@echo off
title MAKE IT FAST - Windows 11 Performance Repair
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
echo ================================================================
echo   MAKE IT FAST
echo ================================================================
echo.
echo   This will do everything in one go:
echo.
echo     1. Check what is wrong and save a report to your Desktop
echo     2. Create a System Restore point so this can be undone
echo     3. Free up disk space
echo     4. Cut down the programs that start with Windows
echo     5. Fix power settings and stop the laptop overheating
echo     6. Turn off Windows 11 background bloat
echo     7. Repair damaged Windows files
echo.
echo   It takes 20 to 40 minutes. The screen may look frozen at
echo   times - that is normal, leave it running.
echo.
echo   Keep the laptop plugged into power.
echo.
echo ================================================================
echo.
pause

echo.
echo  [1/2] Checking what is wrong...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Diagnose-PC.ps1"

echo.
echo  [2/2] Applying all fixes...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-PC.ps1" -Apply -ThermalFix

echo.
echo ================================================================
echo   FINISHED - NOW RESTART THE LAPTOP
echo ================================================================
echo.
echo   The report on your Desktop (pc-performance-report.txt) lists
echo   anything left that needs new hardware rather than a setting.
echo.
echo   To undo: run Undo-Startup-Changes.bat, or use System Restore
echo   and pick "Before PC performance optimisation".
echo.
set /p RB="Restart now? (Y/N): "
if /i "%RB%"=="Y" shutdown /r /t 5 /c "Restarting to apply performance fixes"
echo.
pause
