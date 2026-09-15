@echo off
setlocal

REM ---------------------------------------------------------------------
REM Launcher for Fix-ValorantMonitorResolution.ps1
REM Double-click this .bat file. It will:
REM   1. Check if it's running as Administrator
REM   2. If not, relaunch itself elevated (UAC prompt)
REM   3. Run the PowerShell script from the same folder
REM ---------------------------------------------------------------------

net session >nul 2>&1
if %errorLevel% == 0 (
    goto :run
) else (
    echo Not running as Administrator - requesting elevation...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

:run
cd /d "%~dp0"
echo Running Fix-ValorantMonitorResolution.ps1 as Administrator...
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Fix-ValorantMonitorResolution.ps1"

echo.
echo ---------------------------------------------------------------------
pause
