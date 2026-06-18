param(
    [int]$RefreshSeconds = 30,
    [string]$CodexHome = "$env:USERPROFILE\.codex"
)

if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $ps = if ($pwsh) { $pwsh.Source } else { Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe' }
    $args = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-STA',
        '-File', $PSCommandPath,
        '-RefreshSeconds', $RefreshSeconds,
        '-CodexHome', $CodexHome
    )
    Start-Process -FilePath $ps -ArgumentList $args -WindowStyle Hidden
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$script:LastSnapshot = $null
$script:CodexHome = $CodexHome
$script:RefreshSeconds = [Math]::Max(10, $RefreshSeconds)
$script:SettingsDir = Join-Path $env:APPDATA 'CodexUsageMeter'
$script:SettingsPath = Join-Path $script:SettingsDir 'settings.json'
$script:CurrentDetailText = '等待首次刷新...'

function Test-CodexRunning {
    try {
        $names = @('Codex', 'codex', 'Codex App', 'codex-desktop')
        $processes = Get-Process -ErrorAction SilentlyContinue
        return [bool]($processes | Where-Object {
            $names -contains $_.ProcessName -or
            $_.ProcessName -match '^codex' -or
            ($_.Path -and $_.Path -match '\\Codex\\|\\codex\\|codex')
        } | Select-Object -First 1)
    } catch {
        return $false
    }
}

function Convert-UnixSecondsToLocalText {
    param($UnixSeconds)

    if ($null -eq $UnixSeconds) {
        return '未知'
    }

    try {
        $dto = [DateTimeOffset]::FromUnixTimeSeconds([int64]$UnixSeconds)
        return $dto.LocalDateTime.ToString('MM-dd HH:mm')
    } catch {
        return '未知'
    }
}

function Get-TokenCountEventsFromFile {
    param([System.IO.FileInfo]$File)

    $events = New-Object System.Collections.Generic.List[object]
    if (-not $File.Exists) {
        return $events
    }

    try {
        $lines = Get-Content -LiteralPath $File.FullName -ErrorAction Stop
        foreach ($line in $lines) {
            if ($line -notmatch '"token_count"') {
                continue
            }

            try {
                $record = $line | ConvertFrom-Json -ErrorAction Stop
                if ($record.type -eq 'event_msg' -and $record.payload.type -eq 'token_count') {
                    $events.Add($record) | Out-Null
                }
            } catch {
                continue
            }
        }
    } catch {
        # Codex may be writing the file while we read it. Skip this pass and try again later.
    }

    return $events
}

function Get-CodexUsageSnapshot {
    $sessionsRoot = Join-Path $script:CodexHome 'sessions'
    $snapshot = [ordered]@{
        Found                = $false
        Source               = '未找到 Codex token_count 日志'
        Plan                 = '未知'
        TodayTokens          = 0
        LatestThreadTokens   = 0
        ThreadInputTokens    = 0
        ThreadCachedTokens   = 0
        ThreadOutputTokens   = 0
        ThreadReasoningTokens = 0
        LastTokens           = 0
        LastInputTokens      = 0
        LastCachedTokens     = 0
        LastOutputTokens     = 0
        LastReasoningTokens  = 0
        PrimaryPercent       = $null
        SecondaryPercent     = $null
        PrimaryReset         = '未知'
        SecondaryReset       = '未知'
        LatestEventTime      = $null
        LatestFile           = $null
    }

    if (-not (Test-Path -LiteralPath $sessionsRoot)) {
        return [pscustomobject]$snapshot
    }

    $since = (Get-Date).Date
    $files = @(Get-ChildItem -LiteralPath $sessionsRoot -Recurse -Filter '*.jsonl' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -ge $since.AddDays(-1) } |
        Sort-Object LastWriteTime)

    if ($files.Count -eq 0) {
        return [pscustomobject]$snapshot
    }

    $latestEvent = $null
    $todayTokens = 0

    foreach ($file in $files) {
        $events = Get-TokenCountEventsFromFile -File $file
        foreach ($event in $events) {
            $eventTime = $null
            if ($event.timestamp) {
                try { $eventTime = [DateTimeOffset]::Parse($event.timestamp).LocalDateTime } catch {}
            }

            if ($eventTime -and $eventTime -ge $since) {
                $lastTotal = $event.payload.info.last_token_usage.total_tokens
                if ($null -ne $lastTotal) {
                    $todayTokens += [int64]$lastTotal
                }
            }

            if ($null -eq $latestEvent -or ($event.timestamp -and $event.timestamp -gt $latestEvent.timestamp)) {
                $latestEvent = $event
                $snapshot.LatestFile = $file.FullName
            }
        }
    }

    if ($null -eq $latestEvent) {
        return [pscustomobject]$snapshot
    }

    $rate = $latestEvent.payload.rate_limits
    $info = $latestEvent.payload.info
    $snapshot.Found = $true
    $snapshot.Source = 'Codex session token_count'
    $snapshot.Plan = if ($rate.plan_type) { [string]$rate.plan_type } else { '未知' }
    $snapshot.TodayTokens = $todayTokens
    $snapshot.LatestThreadTokens = if ($null -ne $info.total_token_usage.total_tokens) { [int64]$info.total_token_usage.total_tokens } else { 0 }
    $snapshot.ThreadInputTokens = if ($null -ne $info.total_token_usage.input_tokens) { [int64]$info.total_token_usage.input_tokens } else { 0 }
    $snapshot.ThreadCachedTokens = if ($null -ne $info.total_token_usage.cached_input_tokens) { [int64]$info.total_token_usage.cached_input_tokens } else { 0 }
    $snapshot.ThreadOutputTokens = if ($null -ne $info.total_token_usage.output_tokens) { [int64]$info.total_token_usage.output_tokens } else { 0 }
    $snapshot.ThreadReasoningTokens = if ($null -ne $info.total_token_usage.reasoning_output_tokens) { [int64]$info.total_token_usage.reasoning_output_tokens } else { 0 }
    $snapshot.LastTokens = if ($null -ne $info.last_token_usage.total_tokens) { [int64]$info.last_token_usage.total_tokens } else { 0 }
    $snapshot.LastInputTokens = if ($null -ne $info.last_token_usage.input_tokens) { [int64]$info.last_token_usage.input_tokens } else { 0 }
    $snapshot.LastCachedTokens = if ($null -ne $info.last_token_usage.cached_input_tokens) { [int64]$info.last_token_usage.cached_input_tokens } else { 0 }
    $snapshot.LastOutputTokens = if ($null -ne $info.last_token_usage.output_tokens) { [int64]$info.last_token_usage.output_tokens } else { 0 }
    $snapshot.LastReasoningTokens = if ($null -ne $info.last_token_usage.reasoning_output_tokens) { [int64]$info.last_token_usage.reasoning_output_tokens } else { 0 }
    $snapshot.PrimaryPercent = $rate.primary.used_percent
    $snapshot.SecondaryPercent = $rate.secondary.used_percent
    $snapshot.PrimaryReset = Convert-UnixSecondsToLocalText $rate.primary.resets_at
    $snapshot.SecondaryReset = Convert-UnixSecondsToLocalText $rate.secondary.resets_at
    $snapshot.LatestEventTime = if ($latestEvent.timestamp) { ([DateTimeOffset]::Parse($latestEvent.timestamp)).LocalDateTime } else { $null }

    return [pscustomobject]$snapshot
}

function Format-TokenCount {
    param([int64]$Tokens)

    if ($Tokens -ge 1000000) {
        return ('{0:N2}M' -f ($Tokens / 1000000.0))
    }
    if ($Tokens -ge 1000) {
        return ('{0:N1}K' -f ($Tokens / 1000.0))
    }
    return "$Tokens"
}

function Get-DetailText {
    param($Snapshot, [bool]$IsRunning)

    if (-not $IsRunning) {
        return 'Codex 未运行，窗口已隐藏'
    }

    if (-not $Snapshot.Found) {
        return 'Codex 正在运行，但还没有读到 token_count 日志'
    }

    $primaryUsed = if ($null -ne $Snapshot.PrimaryPercent) { "$($Snapshot.PrimaryPercent)%" } else { '未知' }
    $secondaryUsed = if ($null -ne $Snapshot.SecondaryPercent) { "$($Snapshot.SecondaryPercent)%" } else { '未知' }
    $primaryLeft = Format-RemainingPercent (Get-RemainingPercent $Snapshot.PrimaryPercent)
    $secondaryLeft = Format-RemainingPercent (Get-RemainingPercent $Snapshot.SecondaryPercent)
    $today = Format-TokenCount $Snapshot.TodayTokens
    $thread = Format-TokenCount $Snapshot.LatestThreadTokens
    $threadInput = Format-TokenCount $Snapshot.ThreadInputTokens
    $threadCached = Format-TokenCount $Snapshot.ThreadCachedTokens
    $threadOutput = Format-TokenCount $Snapshot.ThreadOutputTokens
    $threadReasoning = Format-TokenCount $Snapshot.ThreadReasoningTokens
    $last = Format-TokenCount $Snapshot.LastTokens
    $lastInput = Format-TokenCount $Snapshot.LastInputTokens
    $lastCached = Format-TokenCount $Snapshot.LastCachedTokens
    $lastOutput = Format-TokenCount $Snapshot.LastOutputTokens
    $lastReasoning = Format-TokenCount $Snapshot.LastReasoningTokens
    $eventTime = if ($Snapshot.LatestEventTime) { $Snapshot.LatestEventTime.ToString('MM-dd HH:mm:ss') } else { '未知' }

    return "Codex 用量估算 ($($Snapshot.Plan))`r`n5小时剩余: $primaryLeft，已用: $primaryUsed，重置: $($Snapshot.PrimaryReset)`r`n本周剩余: $secondaryLeft，已用: $secondaryUsed，重置: $($Snapshot.SecondaryReset)`r`n`r`n当前线程累计: $thread tokens`r`n输入: $threadInput，缓存命中: $threadCached`r`n输出: $threadOutput，推理输出: $threadReasoning`r`n`r`n最近一次: $last tokens`r`n输入: $lastInput，缓存命中: $lastCached`r`n输出: $lastOutput，推理输出: $lastReasoning`r`n`r`n今日估算: $today tokens（本地日志估算，仅供参考）`r`n更新: $eventTime"
}

function Get-RemainingPercent {
    param($UsedPercent)

    if ($null -eq $UsedPercent) {
        return $null
    }

    return [Math]::Max(0, [Math]::Min(100, 100 - [double]$UsedPercent))
}

function Format-RemainingPercent {
    param($RemainingPercent)

    if ($null -eq $RemainingPercent) {
        return '--'
    }

    return ('{0:N0}%' -f $RemainingPercent)
}

function Get-DisplayText {
    param($Snapshot)

    if (-not $Snapshot.Found) {
        return '等待日志'
    }

    $primaryRemaining = Get-RemainingPercent $Snapshot.PrimaryPercent
    $secondaryRemaining = Get-RemainingPercent $Snapshot.SecondaryPercent
    $primaryText = Format-RemainingPercent $primaryRemaining
    $secondaryText = Format-RemainingPercent $secondaryRemaining

    return "5小时 $primaryText   本周 $secondaryText"
}

function Get-ThreadTokenDisplayText {
    param($Snapshot)

    if (-not $Snapshot.Found) {
        return '等待 Codex 写入用量日志'
    }

    $input = Format-TokenCount $Snapshot.ThreadInputTokens
    $cached = Format-TokenCount $Snapshot.ThreadCachedTokens
    $output = Format-TokenCount $Snapshot.ThreadOutputTokens
    return "入 $input  ·  命中 $cached  ·  出 $output"
}

function Get-DisplayBackColor {
    param($Snapshot)

    $primaryRemaining = Get-RemainingPercent $Snapshot.PrimaryPercent
    if ($null -eq $primaryRemaining) {
        return [System.Drawing.Color]::FromArgb(42, 46, 54)
    }
    if ($primaryRemaining -le 15) {
        return [System.Drawing.Color]::FromArgb(155, 42, 42)
    }
    if ($primaryRemaining -le 40) {
        return [System.Drawing.Color]::FromArgb(142, 101, 31)
    }
    return [System.Drawing.Color]::FromArgb(36, 112, 74)
}

function Get-AccentColor {
    param($Snapshot)

    $primaryRemaining = Get-RemainingPercent $Snapshot.PrimaryPercent
    if ($null -eq $primaryRemaining) {
        return [System.Drawing.Color]::FromArgb(107, 114, 128)
    }
    if ($primaryRemaining -le 15) {
        return [System.Drawing.Color]::FromArgb(248, 113, 113)
    }
    if ($primaryRemaining -le 40) {
        return [System.Drawing.Color]::FromArgb(251, 191, 36)
    }
    return [System.Drawing.Color]::FromArgb(52, 211, 153)
}

function New-RoundedPath {
    param(
        [int]$Width,
        [int]$Height,
        [int]$Radius = 12
    )

    $diameter = $Radius * 2
    $rect = New-Object System.Drawing.Rectangle 0, 0, ($Width - 1), ($Height - 1)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc($rect.Left, $rect.Top, $diameter, $diameter, 180, 90)
    $path.AddArc($rect.Right - $diameter, $rect.Top, $diameter, $diameter, 270, 90)
    $path.AddArc($rect.Right - $diameter, $rect.Bottom - $diameter, $diameter, $diameter, 0, 90)
    $path.AddArc($rect.Left, $rect.Bottom - $diameter, $diameter, $diameter, 90, 90)
    $path.CloseFigure()
    return $path
}

function Set-RoundedRegion {
    param(
        [System.Windows.Forms.Form]$Form,
        [int]$Radius = 10
    )

    $path = New-RoundedPath -Width $Form.Width -Height $Form.Height -Radius $Radius
    $Form.Region = New-Object System.Drawing.Region $path
    $path.Dispose()
}

function Load-WindowLocation {
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) {
        return $null
    }

    try {
        $settings = Get-Content -LiteralPath $script:SettingsPath -Raw | ConvertFrom-Json
        if ($null -ne $settings.x -and $null -ne $settings.y) {
            return New-Object System.Drawing.Point ([int]$settings.x), ([int]$settings.y)
        }
    } catch {}

    return $null
}

function Save-WindowLocation {
    if (-not $script:Form) {
        return
    }

    try {
        if (-not (Test-Path -LiteralPath $script:SettingsDir)) {
            New-Item -ItemType Directory -Path $script:SettingsDir -Force | Out-Null
        }
        $settings = [ordered]@{
            x = $script:Form.Left
            y = $script:Form.Top
        }
        $settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8
    } catch {}
}

function Update-WindowPosition {
    if (-not $script:Form) {
        return
    }

    $saved = Load-WindowLocation
    if ($saved) {
        $script:Form.Location = $saved
        return
    }

    $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $x = $screen.Right - $script:Form.Width - 12
    $y = $screen.Bottom - $script:Form.Height - 10
    $script:Form.Location = New-Object System.Drawing.Point $x, $y
}

function Open-Url {
    param([string]$Url)
    try {
        Start-Process $Url | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("无法打开：$Url", 'Codex 用量显示') | Out-Null
    }
}

function Open-CodexStatusHelp {
    [System.Windows.Forms.MessageBox]::Show(
        "在 Codex 输入框里输入 /status，可以查看上下文用量和 rate limits。`r`n`r`n如果你使用 CLI/TUI，也可以输入 /usage 查看账号 token 活动或使用 rate-limit reset。`r`n`r`n本工具读取本机 session 日志做估算，不是官方个人账号额度 API。",
        'Codex 用量校准'
    ) | Out-Null
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$detailItem = $menu.Items.Add('查看详情')
$menu.Items.Add('-') | Out-Null
$refreshItem = $menu.Items.Add('立即刷新')
$usageItem = $menu.Items.Add('打开 ChatGPT / Codex')
$statusItem = $menu.Items.Add('如何用 /status 校准')
$menu.Items.Add('-') | Out-Null
$exitItem = $menu.Items.Add('退出')

$script:Form = New-Object System.Windows.Forms.Form
$script:Form.Text = 'Codex 用量显示'
$script:Form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:Form.ShowInTaskbar = $false
$script:Form.TopMost = $true
$script:Form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$script:Form.Size = New-Object System.Drawing.Size 232, 58
$script:Form.BackColor = [System.Drawing.Color]::FromArgb(17, 24, 39)
$script:Form.Opacity = 1.0
$script:Form.ContextMenuStrip = $menu

$script:Accent = New-Object System.Windows.Forms.Panel
$script:Accent.Dock = [System.Windows.Forms.DockStyle]::Left
$script:Accent.Width = 5
$script:Accent.BackColor = [System.Drawing.Color]::FromArgb(52, 211, 153)
$script:Accent.ContextMenuStrip = $menu
$script:Form.Controls.Add($script:Accent)

$script:TitleLabel = New-Object System.Windows.Forms.Label
$script:TitleLabel.AutoSize = $false
$script:TitleLabel.Location = New-Object System.Drawing.Point 15, 4
$script:TitleLabel.Size = New-Object System.Drawing.Size 206, 14
$script:TitleLabel.Text = 'Codex 剩余额度'
$script:TitleLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:TitleLabel.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 8, ([System.Drawing.FontStyle]::Regular)
$script:TitleLabel.ForeColor = [System.Drawing.Color]::FromArgb(209, 213, 219)
$script:TitleLabel.BackColor = [System.Drawing.Color]::Transparent
$script:TitleLabel.ContextMenuStrip = $menu
$script:Form.Controls.Add($script:TitleLabel)

$script:Label = New-Object System.Windows.Forms.Label
$script:Label.AutoSize = $false
$script:Label.Location = New-Object System.Drawing.Point 14, 18
$script:Label.Size = New-Object System.Drawing.Size 212, 20
$script:Label.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:Label.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 10, ([System.Drawing.FontStyle]::Bold)
$script:Label.ForeColor = [System.Drawing.Color]::White
$script:Label.BackColor = [System.Drawing.Color]::Transparent
$script:Label.ContextMenuStrip = $menu
$script:Form.Controls.Add($script:Label)

$script:TokenSummaryLabel = New-Object System.Windows.Forms.Label
$script:TokenSummaryLabel.AutoSize = $false
$script:TokenSummaryLabel.Location = New-Object System.Drawing.Point 15, 39
$script:TokenSummaryLabel.Size = New-Object System.Drawing.Size 212, 14
$script:TokenSummaryLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
$script:TokenSummaryLabel.Font = New-Object System.Drawing.Font 'Microsoft YaHei UI', 7.5, ([System.Drawing.FontStyle]::Regular)
$script:TokenSummaryLabel.ForeColor = [System.Drawing.Color]::FromArgb(156, 163, 175)
$script:TokenSummaryLabel.BackColor = [System.Drawing.Color]::Transparent
$script:TokenSummaryLabel.ContextMenuStrip = $menu
$script:Form.Controls.Add($script:TokenSummaryLabel)

$script:Form.add_Shown({
    Set-RoundedRegion -Form $script:Form
})
$script:Form.add_Resize({
    Set-RoundedRegion -Form $script:Form
})
$script:Form.add_Paint({
    param($sender, $eventArgs)
    $eventArgs.Graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $path = New-RoundedPath -Width $script:Form.Width -Height $script:Form.Height -Radius 10
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(31, 41, 55)), 1
    $eventArgs.Graphics.DrawPath($pen, $path)
    $pen.Dispose()
    $path.Dispose()
})

$script:DragStart = $null
$script:Form.add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:DragStart = $eventArgs.Location
    }
})
$script:Form.add_MouseMove({
    param($sender, $eventArgs)
    if ($script:DragStart -and $eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:Form.Left += $eventArgs.X - $script:DragStart.X
        $script:Form.Top += $eventArgs.Y - $script:DragStart.Y
    }
})
$script:Form.add_MouseUp({
    $script:DragStart = $null
    Save-WindowLocation
})
$script:Label.add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:DragStart = $eventArgs.Location
    }
})
$script:Label.add_MouseMove({
    param($sender, $eventArgs)
    if ($script:DragStart -and $eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:Form.Left += $eventArgs.X - $script:DragStart.X
        $script:Form.Top += $eventArgs.Y - $script:DragStart.Y
    }
})
$script:Label.add_MouseUp({
    $script:DragStart = $null
    Save-WindowLocation
})
$script:TitleLabel.add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:DragStart = $eventArgs.Location
    }
})
$script:TitleLabel.add_MouseMove({
    param($sender, $eventArgs)
    if ($script:DragStart -and $eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:Form.Left += $eventArgs.X - $script:DragStart.X
        $script:Form.Top += $eventArgs.Y - $script:DragStart.Y
    }
})
$script:TitleLabel.add_MouseUp({
    $script:DragStart = $null
    Save-WindowLocation
})
$script:TokenSummaryLabel.add_MouseDown({
    param($sender, $eventArgs)
    if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:DragStart = $eventArgs.Location
    }
})
$script:TokenSummaryLabel.add_MouseMove({
    param($sender, $eventArgs)
    if ($script:DragStart -and $eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:Form.Left += $eventArgs.X - $script:DragStart.X
        $script:Form.Top += $eventArgs.Y - $script:DragStart.Y
    }
})
$script:TokenSummaryLabel.add_MouseUp({
    $script:DragStart = $null
    Save-WindowLocation
})
$refreshItem.add_Click({
    Update-Tray
})
$detailItem.add_Click({
    [System.Windows.Forms.MessageBox]::Show($script:CurrentDetailText, 'Codex 用量详情') | Out-Null
})
$usageItem.add_Click({
    Open-Url 'https://chatgpt.com/codex'
})
$statusItem.add_Click({
    Open-CodexStatusHelp
})
$exitItem.add_Click({
    $timer.Stop()
    $script:Form.Close()
    [System.Windows.Forms.Application]::Exit()
})

function Update-Tray {
    $isRunning = Test-CodexRunning
    $snapshot = Get-CodexUsageSnapshot
    $script:LastSnapshot = $snapshot

    $script:Label.Text = (Get-DisplayText -Snapshot $snapshot)
    $script:TokenSummaryLabel.Text = (Get-ThreadTokenDisplayText -Snapshot $snapshot)
    $script:Accent.BackColor = (Get-AccentColor -Snapshot $snapshot)
    $script:CurrentDetailText = (Get-DetailText -Snapshot $snapshot -IsRunning $isRunning)
    if ($isRunning) {
        if (-not $script:Form.Visible) {
            Update-WindowPosition
            $script:Form.Show()
        }
    } else {
        $script:Form.Hide()
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $script:RefreshSeconds * 1000
$timer.add_Tick({
    Update-Tray
})

Update-Tray
$timer.Start()
[System.Windows.Forms.Application]::Run()
