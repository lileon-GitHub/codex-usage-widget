$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$exeTarget = Join-Path $scriptDir 'dist\CodexUsageWidget.exe'
$batTarget = Join-Path $scriptDir 'Start-CodexUsageTray.bat'
$target = if (Test-Path -LiteralPath $exeTarget) { $exeTarget } else { $batTarget }
$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'Codex Usage Meter.lnk'
$oldShortcutPath = Join-Path $startup 'Codex Usage Tray.lnk'

if (-not (Test-Path -LiteralPath $target)) {
    throw "Missing launcher: $target"
}

if (Test-Path -LiteralPath $oldShortcutPath) {
    Remove-Item -LiteralPath $oldShortcutPath -Force
}

$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $target
$shortcut.WorkingDirectory = $scriptDir
$shortcut.WindowStyle = 7
$shortcut.Description = 'Show estimated Codex usage near the Windows taskbar when Codex is running.'
$shortcut.Save()

Write-Host "Created startup shortcut: $shortcutPath"
