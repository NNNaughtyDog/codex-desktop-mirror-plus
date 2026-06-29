@echo off
setlocal

set "SCRIPT_DIR=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%update-codex-desktop.ps1"

echo.
echo Codex desktop updater finished. Press any key to close this window.
pause >nul
