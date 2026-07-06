@echo off
setlocal

set "SCRIPT_DIR=%~dp0"

if /I not "%~1"=="--temp-launcher" (
    set "TEMP_LAUNCHER=%TEMP%\CodexDesktopUpdaterLauncher-%RANDOM%-%RANDOM%"
    mkdir "%TEMP_LAUNCHER%" >nul 2>nul
    copy /Y "%SCRIPT_DIR%update-codex-desktop.ps1" "%TEMP_LAUNCHER%\update-codex-desktop.ps1" >nul
    copy /Y "%~f0" "%TEMP_LAUNCHER%\run-update-codex-desktop.cmd" >nul
    if not exist "%TEMP_LAUNCHER%\update-codex-desktop.ps1" (
        echo Failed to prepare temporary updater files.
        pause >nul
        exit /b 1
    )
    cmd /c ""%TEMP_LAUNCHER%\run-update-codex-desktop.cmd" --temp-launcher"
    set "UPDATER_EXIT=%ERRORLEVEL%"
    rmdir /s /q "%TEMP_LAUNCHER%" >nul 2>nul
    exit /b %UPDATER_EXIT%
)

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%update-codex-desktop.ps1"

echo.
echo Codex desktop updater finished. Press any key to close this window.
pause >nul
