@echo off
set "SCRIPT_DIR=%~dp0"
where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  start "" /min pwsh.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT_DIR%CodexUsageTray.ps1"
) else (
  start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT_DIR%CodexUsageTray.ps1"
)
