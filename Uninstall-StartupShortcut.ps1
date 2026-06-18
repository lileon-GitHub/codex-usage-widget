$startup = [Environment]::GetFolderPath('Startup')
$shortcutPath = Join-Path $startup 'Codex Usage Meter.lnk'
$oldShortcutPath = Join-Path $startup 'Codex Usage Tray.lnk'

foreach ($path in @($shortcutPath, $oldShortcutPath)) {
    if (Test-Path -LiteralPath $path) {
        Remove-Item -LiteralPath $path -Force
        Write-Host "Removed startup shortcut: $path"
    }
}

Get-CimInstance Win32_Process |
    Where-Object { $_.Name -match 'powershell|pwsh' -and $_.CommandLine -like '*CodexUsageTray.ps1*' } |
    ForEach-Object {
        try {
            Stop-Process -Id $_.ProcessId -Force
            Write-Host "Stopped running instance: $($_.ProcessId)"
        } catch {}
    }
