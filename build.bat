@echo off
setlocal
set "ROOT=%~dp0"
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
  echo Cannot find csc.exe. Install .NET Framework 4.x Developer Pack or Visual Studio Build Tools.
  exit /b 1
)

if not exist "%ROOT%dist" mkdir "%ROOT%dist"

"%CSC%" ^
  /nologo ^
  /target:winexe ^
  /platform:anycpu ^
  /optimize+ ^
  /out:"%ROOT%dist\CodexUsageWidget.exe" ^
  /reference:System.dll ^
  /reference:System.Core.dll ^
  /reference:System.Drawing.dll ^
  /reference:System.Web.Extensions.dll ^
  /reference:System.Windows.Forms.dll ^
  "%ROOT%src\CodexUsageWidget.cs"

if errorlevel 1 exit /b 1
echo Built "%ROOT%dist\CodexUsageWidget.exe"
