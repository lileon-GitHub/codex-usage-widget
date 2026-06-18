@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Uninstall-StartupShortcut.ps1"
echo.
echo Codex usage meter startup shortcut removed.
pause
