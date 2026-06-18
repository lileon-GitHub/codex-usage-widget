@echo off
set "SCRIPT_DIR=%~dp0"
if exist "%SCRIPT_DIR%dist\CodexUsageWidget.exe" (
  start "" "%SCRIPT_DIR%dist\CodexUsageWidget.exe"
  exit /b 0
)

where pwsh.exe >nul 2>nul
if %errorlevel%==0 (
  start "" /min pwsh.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT_DIR%CodexUsageTray.ps1"
) else (
  start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%SCRIPT_DIR%CodexUsageTray.ps1"
)
