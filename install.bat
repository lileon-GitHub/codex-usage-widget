@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Install-StartupShortcut.ps1"
if errorlevel 1 (
  echo.
  echo Install failed.
  pause
  exit /b 1
)

call "%SCRIPT_DIR%Start-CodexUsageTray.bat"
echo.
echo Codex usage meter installed and started.
pause
