@echo off
REM ============================================================
REM  CareWebServiceV5 - One-Click Deployment Launcher
REM
REM  USAGE (pick whichever fits the release):
REM    A) Drag & drop a release .zip already on disk onto this .bat
REM    B) Double-click the .bat with nothing dropped -> paste a OneDrive
REM       "anyone with the link" share URL when prompted, OR leave the
REM       prompt blank to browse for a local zip instead
REM
REM  All the real logic lives in Deploy-Launcher.ps1 (kept in PowerShell,
REM  not batch, so links/paths with special characters like & are never
REM  mangled by nested cmd quoting).
REM ============================================================

setlocal

set "SCRIPT_DIR=%~dp0"
set "LAUNCHER=%SCRIPT_DIR%Deploy-Launcher.ps1"

if not exist "%LAUNCHER%" (
    echo Cannot find Deploy-Launcher.ps1 next to this launcher.
    echo Expected at: %LAUNCHER%
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER%" -DroppedPath "%~1"

pause
