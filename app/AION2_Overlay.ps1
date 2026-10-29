# AION2 Yustiel weekly schedule overlay v1.8.5. Windows PowerShell 5.1 / WinForms.
# No compiler, memory inspection, packet capture or injection required.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$script:root = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:version = [Version]'1.8.5'
$script:latestRelease = $null
$script:releaseCheckBusy = $false
$script:configFile = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'AION2_Yustiel_Overlay\settings_ps.json'
$script:csvFile = Join-Path $script:root 'schedule.csv'
$script:overridesFile = Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'AION2_Yustiel_Overlay\schedule_overrides.csv'
$script:config = @{ AutoDetect = $true; Pinned = $false; AlertWhenGameClosed = $true; AlertOn = $true; Lead = 10; Group = 1; SoundOn = $true; PopupOn = $true; StartAlertOn = $true; Volume = 65; Melody = 1; OpacityPercent = 96; ViewMode = 'Full'; X = -1; Y = -1; StartWithWindows = $false; UpdateRepo = 'dlwp00700-oss/aion2-yustiel-overlay' }
$script:seen = @{}
$script:tick = 0
$script:gameRunning = $false
$script:lastGameRunning = $false
$script:suppressed = $false
$script:quit = $false
$script:dayRendered = ''
$script:eventPanels = @()
try {
    $data = Get-Content -LiteralPath $script:configFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($k in @($script:config.Keys)) { if ($null -ne $data.PSObject.Properties[$k]) { $script:config[$k] = $data.$k } }
} catch { }
try { $script:config.OpacityPercent = [Math]::Max(20,[Math]::Min(100,[int]$script:config.OpacityPercent)) }
catch { $script:config.OpacityPercent = 96 }
if ([string]$script:config.ViewMode -notin @('Full','Compact')) { $script:config.ViewMode = 'Full' }
$script:forcePreview = ($env:AION2_FORCE_PREVIEW -eq '1')
try { $script:events = @(Import-Csv -LiteralPath $script:csvFile -Encoding UTF8) }
catch { [System.Windows.Forms.MessageBox]::Show('schedule.csv 파일을 읽을 수 없습니다: ' + $_.Exception.Message, 'AION2') | Out-Null; exit 1 }
try {
    if (Test-Path -LiteralPath $script:overridesFile) {
        foreach($change in @(Import-Csv -LiteralPath $script:overridesFile -Encoding UTF8)) {
            foreach($entry in $script:events) {
                if($entry.Id -eq $change.Id) {
                    if($change.Time -match '^([01][0-9]|2[0-3]):[0-5][0-9]$') { $entry.Time = $change.Time }
                    $entry.Enabled = $change.Enabled
                }
            }
        }
    }
} catch { }
try { $script:zone = [TimeZoneInfo]::FindSystemTimeZoneById('Korea Standard Time') }
catch { $script:zone = [TimeZoneInfo]::Local }

function Now-KST { [TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $script:zone) }
# Argo is a fixed daily schedule after the 2026-10-28 patch; no manual or guild sync required.

function Save-Prefs {
    try {
        $parent = Split-Path -Parent $script:configFile
        if (-not (Test-Path -LiteralPath $parent)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
        $script:config | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $script:configFile -Encoding UTF8
    } catch { }
}
# Re-register an existing auto-start entry after an update to a different folder.
# Do not enable auto-start unless the user previously enabled it.
if([bool]$script:config.StartWithWindows) {
    try {
        $runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
        $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
        $command = '"{0}" "{1}"' -f $wscript,(Join-Path $script:root 'AION2_start.vbs')
        New-ItemProperty -Path $runKey -Name 'AION2YustielOverlayPS' -Value $command -PropertyType String -Force | Out-Null
    } catch { }
}
function Save-Overrides {
    try {
        $dir = Split-Path -Parent $script:overridesFile
        if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        $lines = @('Id,Time,Enabled')
        foreach($entry in $script:events) { $lines += ("{0},{1},{2}" -f $entry.Id,$entry.Time,$entry.Enabled) }
        [System.IO.File]::WriteAllLines($script:overridesFile, [string[]]$lines, [System.Text.Encoding]::UTF8)
    } catch {
        [System.Windows.Forms.MessageBox]::Show('일정 설정 저장 오류: ' + $_.Exception.Message, 'AION2') | Out-Null
    }
}
function Play-Alert([int]$volume, [int]$melody) {
    if($volume -le 0) { return }
    try {
        $notes = if($melody -eq 0) { @(880) } elseif($melody -eq 2) { @(660,880,660,1046,880,1046) } else { @(660,880,1046) }
        $rate = 22050
        $samples = 2 * $rate
        $samples = [Math]::Max($samples, [int]([Math]::Ceiling(($notes.Count * .27 + .12) * $rate)))
        $pcm = New-Object byte[] ($samples * 2)
        for($i=0;$i -lt $samples;$i++) {
            $sec = $i / [double]$rate
            $part = [int][Math]::Floor($sec / .27)
            if($part -ge $notes.Count){continue}
            $local = $sec - ($part * .27)
            $envelope = [Math]::Min(1, $local / .015) * [Math]::Min(1,[Math]::Max(0, (.24 - $local)/.055))
            $sample = [int]([Math]::Sin(2 * [Math]::PI * $notes[$part] * $sec) * $envelope * .2 * ($volume / 100.0) * 32767)
            $pcm[2*$i] = [byte]($sample -band 255)
            $pcm[2*$i+1] = [byte](($sample -shr 8) -band 255)
        }
        $stream = [System.IO.MemoryStream]::new()
        $writer = [System.IO.BinaryWriter]::new($stream)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
        $writer.Write([int](36 + $pcm.Length))
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('WAVEfmt '))
        $writer.Write([int]16); $writer.Write([int16]1); $writer.Write([int16]1)
        $writer.Write([int]$rate); $writer.Write([int]($rate * 2)); $writer.Write([int16]2); $writer.Write([int16]16)
        $writer.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
        $writer.Write([int]$pcm.Length); $writer.Write($pcm)
        $stream.Position = 0
        $script:activeSoundStream = $stream
        $script:activeSound = [System.Media.SoundPlayer]::new($stream)
        $script:activeSound.Play()
    } catch { [System.Media.SystemSounds]::Asterisk.Play() }
}
function Event-Time($evt, [datetime]$today) {
    $parts = $evt.Time.Split(':')
    $offset = if ($evt.GroupShift -eq '1') { 30 * ([int]$script:config.Group - 1) } else { 0 }
    return $today.Date.AddHours([int]$parts[0]).AddMinutes([int]$parts[1] + $offset)
}
function Today-Events([datetime]$today) {
    return @($script:events | Where-Object { $_.Enabled -eq '1' -and $_.Day -eq $today.DayOfWeek.ToString() } | Sort-Object { (Event-Time $_ $today).Ticks })
}
function Duration-Text([timespan]$span) {
    $mins = [int][Math]::Ceiling($span.TotalMinutes)
    if ($mins -le 0) { return '1분 이내' }
    if ($mins -ge 60) { return ('{0}시간 {1}분' -f [int][Math]::Floor($mins/60), ($mins%60)) }
    return ('{0}분' -f $mins)
}
function Game-IsRunning {
    foreach($name in @('AION2','AION2Client','AION2-Win64-Shipping')) {
        try { if (Get-Process -Name $name -ErrorAction SilentlyContinue) { return $true } } catch { }
    }
    return $false
}
function New-Label($content, $x, $y, $w, $h, $fontSize, $foreground, $bold = $false) {
    $label = New-Object System.Windows.Forms.Label
    $label.SetBounds($x, $y, $w, $h)
    $label.Text = $content
    $label.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($foreground)
    $label.BackColor = [System.Drawing.Color]::Transparent
    $style = if ($bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $label.Font = [System.Drawing.Font]::new('Malgun Gothic', [single]$fontSize, $style)
    $label.AutoEllipsis = $true
    return $label
}
$script:form = New-Object System.Windows.Forms.Form
$script:form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$script:form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$script:form.TopMost = $true
$script:form.ShowInTaskbar = $false
$script:form.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#0F172A')
$script:form.Width = 360
$script:form.Height = 244
$script:form.Opacity = [Math]::Min(1.0,[Math]::Max(0.2,[int]$script:config.OpacityPercent / 100.0))
$script:form.Font = [System.Drawing.Font]::new('Malgun Gothic', [single]9)
$script:form.Add_FormClosing({ param($sender,$args)
    if (-not $script:quit) { $args.Cancel = $true; $script:suppressed = $true; $script:form.Hide() }
})
$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
if ([int]$script:config.X -ge $screen.Left -and [int]$script:config.X -lt $screen.Right -and [int]$script:config.Y -ge $screen.Top -and [int]$script:config.Y -lt $screen.Bottom) {
    $script:form.Location = [System.Drawing.Point]::new([int]$script:config.X,[int]$script:config.Y)
} else { $script:form.Location = [System.Drawing.Point]::new(($screen.Right - 385),($screen.Top + 95)) }
$script:dragging = $false
$script:dragOffset = [System.Drawing.Point]::new(0,0)
$script:dragStart = {
    param($sender,$evt)
    if($evt.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        $script:dragging = $true
        $script:dragOffset = [System.Drawing.Point]::new($evt.X, $evt.Y)
    }
}
$script:dragMove = {
    param($sender,$evt)
    if($script:dragging -and [System.Windows.Forms.Control]::MouseButtons -eq [System.Windows.Forms.MouseButtons]::Left) {
        $p = [System.Windows.Forms.Control]::MousePosition
        $script:form.Location = [System.Drawing.Point]::new(($p.X - $script:dragOffset.X),($p.Y - $script:dragOffset.Y))
    }
}
$script:dragEnd = {
    $script:dragging = $false
    $script:config.X = $script:form.Left
    $script:config.Y = $script:form.Top
    Save-Prefs
}
$script:form.Add_MouseDown($script:dragStart)
$script:form.Add_MouseMove($script:dragMove)
$script:form.Add_MouseUp($script:dragEnd)
$script:title = New-Label 'AION2  /  유스티엘' 18 10 286 31 12 '#E8F3FF' $true
$script:subtitle = New-Label '' 19 43 327 22 8.5 '#9CACBF'
$script:nextLabel = New-Label '' 19 69 328 20 8.5 '#FFD37E'
$script:footer = New-Label '' 19 207 219 28 8 '#92A4B9'
$script:updateLabel = New-Label '새 업데이트 · 설치 ›' 13 155 334 37 9.5 '#FFFFFF' $true
$script:updateLabel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#277768')
$script:updateLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:updateLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:updateLabel.Visible = $false
$script:updateLabel.Add_MouseEnter({ if($script:updateLabel.Enabled){$script:updateLabel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#359781')} })
$script:updateLabel.Add_MouseLeave({ $script:updateLabel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#277768') })
$script:updateLabel.Add_Click({ Install-AvailableRelease })
$script:detailLabel = New-Label '상세설정 ›' 244 207 101 27 9 '#B9F5E9' $true
$script:detailLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:detailLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$script:detailLabel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#2B465A')
$script:detailLabel.Add_Click({ Show-Settings })
# Always-visible view switch. No settings dialog needed.
$script:fullViewButton = New-Label '전체 일정' 13 97 162 33 9 '#FFFFFF' $true
$script:compactViewButton = New-Label '간단히 보기' 185 97 162 33 9 '#FFFFFF' $true
foreach ($button in @($script:fullViewButton,$script:compactViewButton)) {
    $button.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $button.Cursor = [System.Windows.Forms.Cursors]::Hand
}
$script:fullViewButton.Add_Click({ Set-ViewMode 'Full' })
$script:compactViewButton.Add_Click({ Set-ViewMode 'Compact' })
$script:closeLabel = New-Label '×' 323 11 25 28 13 '#B2C4D8' $true
$script:closeLabel.Cursor = [System.Windows.Forms.Cursors]::Hand
$script:closeLabel.Add_Click({ $script:suppressed = $true; $script:form.Hide() })
foreach($c in @($script:title,$script:subtitle,$script:nextLabel,$script:fullViewButton,$script:compactViewButton,$script:footer,$script:detailLabel,$script:updateLabel,$script:closeLabel)) { [void]$script:form.Controls.Add($c) }
foreach($c in @($script:title,$script:subtitle)) { $c.Add_MouseDown($script:dragStart);$c.Add_MouseMove($script:dragMove);$c.Add_MouseUp($script:dragEnd) }

$script:notify = New-Object System.Windows.Forms.NotifyIcon
$script:notify.Icon = [System.Drawing.SystemIcons]::Information
$script:notify.Text = 'AION2 유스티엘 주간 일정'
$script:notify.Visible = $true
try {
    $healthDir = Join-Path $env:LOCALAPPDATA 'AION2_Yustiel_Overlay'
    [void][System.IO.Directory]::CreateDirectory($healthDir)
    [System.IO.File]::WriteAllText((Join-Path $healthDir 'status.txt'),('RUNNING: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + [Environment]::NewLine + 'PowerShell overlay taskbar icon initialized.'),[System.Text.Encoding]::UTF8)
} catch { }
$script:menu = New-Object System.Windows.Forms.ContextMenuStrip
$script:form.ContextMenuStrip = $script:menu
$script:notify.ContextMenuStrip = $script:menu
function New-MenuItem($label, [scriptblock]$action, $checked = $false) {
    $item = New-Object System.Windows.Forms.ToolStripMenuItem
    $item.Text = $label
    $item.Checked = [bool]$checked
    $item.Add_Click($action)
    return $item
}
function Update-Visibility {
    $shouldShow = -not $script:suppressed -and ($script:forcePreview -or $script:config.Pinned -or ($script:config.AutoDetect -and $script:gameRunning))
    if ($shouldShow -and -not $script:form.Visible) { $script:form.Show() }
    if (-not $shouldShow -and $script:form.Visible) { $script:form.Hide() }
}
function Refresh-Menu {
    $script:menu.Items.Clear()
    $show = New-MenuItem '오늘 일정 보기 / 숨기기' {
        if ($script:form.Visible) { $script:suppressed = $true; $script:form.Hide() }
        else { $script:suppressed = $false; $script:config.Pinned = $true; Update-Visibility }
        Save-Prefs; Refresh-Menu
    }
    [void]$script:menu.Items.Add($show)
    [void]$script:menu.Items.Add((New-MenuItem '상세설정 열기...' { Show-Settings }))
    [void]$script:menu.Items.Add((New-MenuItem '업데이트 확인' { Start-BackgroundReleaseCheck }))
    [void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$script:menu.Items.Add((New-MenuItem '게임 실행 시 자동 표시' {
        $script:config.AutoDetect = -not $script:config.AutoDetect; Save-Prefs; Update-Visibility; Refresh-Menu
    } $script:config.AutoDetect))
    [void]$script:menu.Items.Add((New-MenuItem '게임 종료 후에도 항상 표시' {
        $script:config.Pinned = -not $script:config.Pinned; $script:suppressed = $false; Save-Prefs; Update-Visibility; Refresh-Menu
    } $script:config.Pinned))
    [void]$script:menu.Items.Add((New-MenuItem '게임 미실행 중에도 알림' {
        $script:config.AlertWhenGameClosed = -not [bool]$script:config.AlertWhenGameClosed
        Save-Prefs; Refresh-Menu
    } $script:config.AlertWhenGameClosed))
    [void]$script:menu.Items.Add((New-MenuItem '소리 · 알림 켜기' {
        $script:config.AlertOn = -not $script:config.AlertOn; Save-Prefs; Refresh-Menu
    } $script:config.AlertOn))
    $groupRoot = [System.Windows.Forms.ToolStripMenuItem]::new('매칭 그룹')
    foreach($i in @(1,2,3)) {
        $choice = $i
        $sub = [System.Windows.Forms.ToolStripMenuItem]::new("${choice}그룹")
        $sub.Checked = ([int]$script:config.Group -eq $choice)
        $sub.Tag = $choice
        $sub.Add_Click({ param($sender,$args) $script:config.Group = [int]$sender.Tag; $script:dayRendered = ''; Save-Prefs; Refresh-Menu })
        [void]$groupRoot.DropDownItems.Add($sub)
    }
    [void]$script:menu.Items.Add($groupRoot)
    $leadRoot = [System.Windows.Forms.ToolStripMenuItem]::new('사전 알림 시간')
    foreach($minutes in @(5,10,15,20,30,60)) {
        $sub = [System.Windows.Forms.ToolStripMenuItem]::new("${minutes}분 전")
        $sub.Checked = ([int]$script:config.Lead -eq $minutes)
        $sub.Tag = $minutes
        $sub.Add_Click({ param($sender,$args) $script:config.Lead = [int]$sender.Tag; Save-Prefs; Refresh-Menu })
        [void]$leadRoot.DropDownItems.Add($sub)
    }
    [void]$script:menu.Items.Add($leadRoot)
    [void]$script:menu.Items.Add((New-MenuItem 'Windows 시작 시 자동 실행' {
        try {
            $runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
            if(-not $script:config.StartWithWindows) {
                $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
                $command='"{0}" "{1}"' -f $wscript,(Join-Path $script:root 'AION2_start.vbs')
                New-ItemProperty -Path $runKey -Name 'AION2YustielOverlayPS' -Value $command -PropertyType String -Force | Out-Null
            } else { Remove-ItemProperty -Path $runKey -Name 'AION2YustielOverlayPS' -ErrorAction SilentlyContinue }
            $script:config.StartWithWindows = -not $script:config.StartWithWindows
            Save-Prefs; Refresh-Menu
        } catch { [System.Windows.Forms.MessageBox]::Show($_.Exception.Message,'자동 실행 설정 오류') | Out-Null }
    } $script:config.StartWithWindows))
    [void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$script:menu.Items.Add((New-MenuItem '일정 CSV 열기 (수정 후 재시작)' {
        Start-Process notepad.exe -ArgumentList ('"{0}"' -f $script:csvFile)
    }))
    [void]$script:menu.Items.Add((New-MenuItem '알림 테스트' {
        Play-Alert ([int]$script:config.Volume) ([int]$script:config.Melody)
        $script:notify.ShowBalloonTip(5000,'AION2 유스티엘','알림 테스트입니다.',[System.Windows.Forms.ToolTipIcon]::Info)
    }))
    [void]$script:menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$script:menu.Items.Add((New-MenuItem '프로그램 완전 종료' {
        $script:quit = $true; Save-Prefs; $script:timer.Stop(); $script:notify.Visible = $false; $script:notify.Dispose(); $script:form.Dispose(); $script:context.ExitThread()
    }))
}
function Update-ViewModeButtons {
    $activeColor = [System.Drawing.ColorTranslator]::FromHtml('#246E62')
    $inactiveColor = [System.Drawing.ColorTranslator]::FromHtml('#2B465A')
    $script:fullViewButton.BackColor = if ($script:config.ViewMode -eq 'Full') { $activeColor } else { $inactiveColor }
    $script:compactViewButton.BackColor = if ($script:config.ViewMode -eq 'Compact') { $activeColor } else { $inactiveColor }
}
function Set-ViewMode([string]$mode) {
    if ($mode -notin @('Full','Compact')) { return }
    if ($script:config.ViewMode -eq $mode) { return }
    $script:config.ViewMode = $mode
    $script:dayRendered = ''
    Save-Prefs
    Redraw (Now-KST)
}
function Redraw([datetime]$now) {
    $eventsToday = @(Today-Events $now)
    $tomorrow = $now.Date.AddDays(1)
    $eventsTomorrow = @(Today-Events $tomorrow)
    # Build a two-day timeline, so the next item is highlighted across midnight.
    $timeline = @(
        foreach($e in $eventsToday) {
            [pscustomobject]@{ Entry=$e; Date=$now.Date; At=(Event-Time $e $now) }
        }
        foreach($e in $eventsTomorrow) {
            [pscustomobject]@{ Entry=$e; Date=$tomorrow; At=(Event-Time $e $tomorrow) }
        }
    ) | Sort-Object At, @{Expression={$_.Entry.Id}}
    # A start time remains highlighted for the following three minutes.
    # All events at identical times stay highlighted together.
    $nextItem = @($timeline | Where-Object { $_.At -gt $now } | Select-Object -First 1)
    $nextAt = if($nextItem.Count -gt 0){$nextItem[0].At}else{$null}
    $startedItems = @($timeline | Where-Object { $_.At -le $now -and $_.At.AddMinutes(3) -gt $now })
    $focus = @{}
    if($null -ne $nextAt) {
        foreach($item in $timeline) {
            if($item.At -eq $nextAt) { $focus[($item.Date.ToString('yyyyMMdd')+':'+[string]$item.Entry.Id)]='next' }
        }
    }
    foreach($item in $startedItems) {
        $focus[($item.Date.ToString('yyyyMMdd')+':'+[string]$item.Entry.Id)]='grace'
    }
    if ($script:config.ViewMode -eq 'Compact') {
        # Show the two closest future START TIMES, not just two event rows.
        # At the same time (e.g. Argo + Kaira) display ALL events.
        $upcomingTimes = @($timeline | Where-Object { $_.At -gt $now } |
            ForEach-Object { $_.At.Ticks } | Sort-Object -Unique | Select-Object -First 2)
        $displayItems = @($timeline | Where-Object {
            ($_.At -gt $now -and $upcomingTimes -contains $_.At.Ticks) -or
            ($_.At -le $now -and $_.At.AddMinutes(3) -gt $now)
        })
    } else {
        # Existing full-day behavior is unchanged, including the single nearest Kaira row.
        $displayItems = @($timeline | Where-Object { $_.Date -eq $now.Date -and $_.Entry.Id -notlike 'daily-kaira-*' })
        $kairaToShow = @($timeline | Where-Object { $_.Entry.Id -like 'daily-kaira-*' -and $_.At.AddMinutes(3) -gt $now } | Select-Object -First 1)
        if($kairaToShow.Count -gt 0) { $displayItems += $kairaToShow[0] }
        if($nextItem.Count -gt 0) {
            $exists = @($displayItems | Where-Object { $_.At -eq $nextAt })
            if($exists.Count -eq 0) { $displayItems += $nextItem[0] }
        }
    }
    $displayItems = @($displayItems | Sort-Object At, @{Expression={$_.Entry.Id}})
    $renderIds = (@($displayItems | ForEach-Object { $_.Date.ToString('yyyyMMdd')+':'+$_.Entry.Id }) -join '|')
    $dayKey = $now.ToString('yyyy-MM-dd') + ':' + $script:config.Group + ':' + [string]($null -ne $script:latestRelease) + ':' + [string]$script:config.ViewMode + ':' + $renderIds
    if ($script:dayRendered -ne $dayKey) {
        foreach($panel in $script:eventPanels) { $script:form.Controls.Remove($panel); $panel.Dispose() }
        $script:eventPanels = @()
        $count = [Math]::Max($displayItems.Count,1)
        $script:form.Height = 195 + (49 * $count) + $(if($null -ne $script:latestRelease){44}else{0})
        foreach($item in $displayItems) {
            $event=$item.Entry
            $index = $script:eventPanels.Count
            $panel = New-Object System.Windows.Forms.Panel
            $panel.SetBounds(13,(141 + 49*$index),334,45)
            $panel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#213047')
            $time = $item.At.ToString('HH:mm')
            $prefix = if($item.Date -gt $now.Date){'내일 '}else{''}
            $caption = "$prefix$time  ·  " + $event.Name
            $line1 = New-Label $caption 12 2 311 22 9 '#ECF5FF' $true
            $line2 = New-Label '' 13 23 305 18 8 '#AFC0D1'
            [void]$panel.Controls.Add($line1)
            [void]$panel.Controls.Add($line2)
            $panel.Tag = @{ Entry = $event; EventDate=$item.Date; EventAt=$item.At; StatusLabel = $line2; MainLabel=$line1; Caption=$caption }
            [void]$script:form.Controls.Add($panel)
            $script:eventPanels += $panel
        }
        if ($displayItems.Count -eq 0) {
            $panel = New-Object System.Windows.Forms.Panel
            $panel.SetBounds(13,141,334,45)
            $panel.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#213047')
            [void]$panel.Controls.Add((New-Label '등록된 일정 없음 · 상세설정에서 확인' 12 9 305 30 9 '#AFC0D1'))
            [void]$script:form.Controls.Add($panel)
            $script:eventPanels += $panel
        }
        $script:updateLabel.Top = $script:form.Height - 91
        $script:updateLabel.Visible = ($null -ne $script:latestRelease)
        $script:footer.Top = $script:form.Height - 42
        $script:detailLabel.Top = $script:form.Height - 39
        $script:dayRendered = $dayKey
    }
    Update-ViewModeButtons
    $names = @('일','월','화','수','목','금','토')
    $script:subtitle.Text = ('{0:MM월 dd일} ({1})  ·  {2}그룹  ·  오늘 {3}개' -f $now,$names[[int]$now.DayOfWeek],$script:config.Group,$eventsToday.Count)
    if($null -eq $nextAt){ $script:nextLabel.Text = '등록된 다음 일정 없음' }
    else {
        $prefix=if($nextAt.Date -gt $now.Date){'내일 '}else{''}
        $script:nextLabel.Text = ('다음 일정  {0}{1:HH:mm} · {2}' -f $prefix,$nextAt,(Duration-Text ($nextAt-$now)))
    }
    foreach($panel in $script:eventPanels) {
        if ($panel.Tag -is [hashtable]) {
            $event = $panel.Tag.Entry
            $at = $panel.Tag.EventAt
            $label = $panel.Tag.StatusLabel
            $title = $panel.Tag.MainLabel
            $remaining = $at-$now
            $key=$panel.Tag.EventDate.ToString('yyyyMMdd')+':'+[string]$event.Id
            $state=if($focus.ContainsKey($key)){$focus[$key]}else{''}
            if($state -eq 'grace') {
                $label.Text='방금 시작 · 3분 유지 ('+[Math]::Max(1,[int][Math]::Ceiling(($at.AddMinutes(3)-$now).TotalSeconds))+'초 남음)'
            } elseif($remaining.TotalSeconds -gt 0) {
                $label.Text='시작까지 '+(Duration-Text $remaining)
            } else {
                $label.Text='예정 시작 시각 경과'
            }
            if($state) {
                $panel.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#246E62')
                $title.Text='●  '+[string]$panel.Tag.Caption
                $title.ForeColor=[System.Drawing.ColorTranslator]::FromHtml('#FFFFFF')
                $label.ForeColor=[System.Drawing.ColorTranslator]::FromHtml('#B8FFE0')
            } else {
                $panel.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#213047')
                $title.Text=[string]$panel.Tag.Caption
                $title.ForeColor=[System.Drawing.ColorTranslator]::FromHtml('#ECF5FF')
                $label.ForeColor=[System.Drawing.ColorTranslator]::FromHtml('#AFC0D1')
            }
        }
    }
    $status = if($script:gameRunning) { '아이온2 실행 중' } elseif ($script:config.Pinned) { '상시 표시' } else { '게임 미감지' }
    $alarm = if ($script:config.AlertOn) { "$($script:config.Lead)분 전" + $(if($script:config.AlertWhenGameClosed){' · 백그라운드'}else{''}) } else { '알림 꺼짐' }
    $script:footer.Text = "$status  |  $alarm"
}
function Tick-App {
    $now = Now-KST
    $script:tick += 1
    if($script:tick -eq 1 -or $script:tick % 4 -eq 0) {
        $script:gameRunning = Game-IsRunning
        if($script:gameRunning -and -not $script:lastGameRunning) { $script:suppressed = $false }
        $script:lastGameRunning = $script:gameRunning
        Update-Visibility
    }
    if($script:config.AlertOn -and ($script:gameRunning -or $script:config.Pinned -or $script:config.AlertWhenGameClosed)) {
        foreach($event in @(Today-Events $now)) {
            $at = Event-Time $event $now
            foreach($phase in @('before','now')) {
                if($phase -eq 'now' -and -not $script:config.StartAlertOn) { continue }
                $alarmAt = if($phase -eq 'before') { $at.AddMinutes(-[int]$script:config.Lead) } else { $at }
                $elapsed = ($now-$alarmAt).TotalSeconds
                if($elapsed -ge 0 -and $elapsed -lt 60) {
                    $key = "$($now.ToString('yyyyMMdd')):$($event.Id):${phase}:$($script:config.Group)"
                    if(-not $script:seen.ContainsKey($key)) {
                        $script:seen[$key] = $true
                        $message = if($phase -eq 'before') { "$($script:config.Lead)분 뒤 $($event.Name) 시작" } else { "$($event.Name) 시작 시각입니다!" }
                        if($script:config.PopupOn) { $script:notify.ShowBalloonTip(5000,'AION2 유스티엘',$message,[System.Windows.Forms.ToolTipIcon]::Info) }
                        if($script:config.SoundOn) { Play-Alert ([int]$script:config.Volume) ([int]$script:config.Melody) }
                    }
                }
            }
        }
    }
    if(($script:tick -eq 15 -or $script:tick % 21600 -eq 0) -and [string]$script:config.UpdateRepo) { Start-BackgroundReleaseCheck }
    if($script:seen.Count -gt 150) { $script:seen.Clear() }
    if($script:form.Visible -or ($script:tick % 4 -eq 0)) { Redraw $now }
}
function Start-BackgroundReleaseCheck {
    if($script:releaseCheckBusy){return}
    $repo=[string]$script:config.UpdateRepo
    if($repo -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$'){return}
    $script:releaseCheckBusy=$true
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $script:releaseClient = New-Object System.Net.WebClient
        $script:releaseClient.Headers.Add('User-Agent','AION2-Yustiel-Overlay-Updater')
        $script:releaseClient.Headers.Add('Accept','application/vnd.github+json')
        $script:releaseClient.Add_DownloadStringCompleted({
            param($sender,$e)
            try {
                if($null -ne $e.Error){ throw $e.Error }
                $remote=([string]$e.Result | ConvertFrom-Json)
                $latestVersion=[Version]([string]$remote.tag_name -replace '^[vV]','')
                $file=@($remote.assets | Where-Object {$_.name -eq 'AION2_Yustiel_Overlay_Update.zip'}) | Select-Object -First 1
                if($latestVersion -gt $script:version -and $null -ne $file -and [string]$file.digest -match '^sha256:[0-9a-fA-F]{64}$'){
                    Set-AvailableRelease $remote
                    if(-not $script:lastUpdateNotice -or $script:lastUpdateNotice -ne $remote.tag_name) {
                        $script:lastUpdateNotice=[string]$remote.tag_name
                        $script:notify.ShowBalloonTip(6000,'AION2 업데이트',('새 버전 '+$remote.tag_name+'을 설치할 수 있습니다. 오버레이의 [업데이트] 버튼을 누르세요.'),[System.Windows.Forms.ToolTipIcon]::Info)
                    }
                    if($script:updateUI -and $script:updateUI.Page -and -not $script:updateUI.Page.IsDisposed) {
                        $script:updateUI.Status.Text='새 버전 '+$remote.tag_name+' 사용 가능 · [업데이트 설치]를 누르세요.'
                        $script:updateUI.Install.Enabled=$true
                    }
                } else {
                    Set-AvailableRelease $null
                    if($script:updateUI -and $script:updateUI.Page -and -not $script:updateUI.Page.IsDisposed){$script:updateUI.Install.Enabled=$false}
                }
            }catch{}finally{
                $script:releaseCheckBusy=$false
                try{$sender.Dispose()}catch{}
            }
        })
        $uri=[Uri]('https://api.github.com/repos/'+$repo+'/releases/latest')
        $script:releaseClient.DownloadStringAsync($uri)
    }catch{$script:releaseCheckBusy=$false}
}
function Get-LatestRelease([string]$repo) {
    if($repo -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,38}/[A-Za-z0-9_.-]{1,100}$'){throw 'GitHub 저장소 형식 오류'}
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $uri='https://api.github.com/repos/'+$repo+'/releases/latest'
    return (Invoke-RestMethod -Uri $uri -Headers @{'User-Agent'='AION2-Yustiel-Overlay-Updater';'Accept'='application/vnd.github+json'} -TimeoutSec 15)
}
function Download-ReleaseAsset($asset,[string]$path) {
    $url=[string]$asset.browser_download_url
    if(-not $url.StartsWith('https://github.com/')){throw 'GitHub 외부 다운로드 링크는 허용되지 않습니다.'}
    $expected=([string]$asset.digest).Substring(7).ToLowerInvariant()
    [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
    try {
        Invoke-WebRequest -Uri $url -UseBasicParsing -OutFile $path -TimeoutSec 90
        $actual=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if($actual -ne $expected){throw '다운로드 파일 SHA-256 불일치. 설치를 중단합니다.'}
    } catch {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        throw
    }
}
# Only user-initiated UI actions call this function; background check never installs.
function Install-AvailableRelease {
    $temp = $null
    try {
        if($null -eq $script:latestRelease){throw '현재 확인된 새 버전이 없습니다. 업데이트 확인을 다시 실행하세요.'}
        $remote = $script:latestRelease
        $asset = @($remote.assets | Where-Object { $_.name -eq 'AION2_Yustiel_Overlay_Update.zip' }) | Select-Object -First 1
        if($null -eq $asset){throw '업데이트 ZIP이 Release에 없습니다.'}
        if(([string]$asset.digest) -notmatch '^sha256:[0-9a-fA-F]{64}$'){throw '검증 가능한 SHA-256 정보가 없습니다. 다운로드를 중단합니다.'}
        $newVersion=[Version]([string]$remote.tag_name -replace '^[vV]','')
        if($newVersion -le $script:version){throw '현재 버전보다 새로운 버전이 아닙니다.'}
        $answer=[System.Windows.Forms.MessageBox]::Show(('새 버전 v'+$newVersion.ToString()+'을(를) 설치할까요?'+[Environment]::NewLine+'다운로드 후 자동으로 프로그램을 재시작합니다.'),'AION2 업데이트',[System.Windows.Forms.MessageBoxButtons]::YesNo,[System.Windows.Forms.MessageBoxIcon]::Question)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){return}
        $script:updateLabel.Enabled=$false
        $script:updateLabel.Text='다운로드 · 무결성 검사 중...'
        $script:updateLabel.Refresh()
        if($script:updateUI -and $script:updateUI.Page -and -not $script:updateUI.Page.IsDisposed){
            $script:updateUI.Install.Enabled=$false
            $script:updateUI.Status.Text='다운로드 및 SHA-256 검사 중...'
            $script:updateUI.Page.Refresh()
        }
        $temp=Join-Path ([System.IO.Path]::GetTempPath()) ('AION2_update_'+[Guid]::NewGuid().ToString('N')+'.zip')
        Download-ReleaseAsset $asset $temp
        $updater=Join-Path $script:root 'update_helper.ps1'
        if(-not(Test-Path -LiteralPath $updater)){throw 'update_helper.ps1 파일을 찾지 못했습니다.'}
        $powershell=Join-Path $PSHOME 'powershell.exe'
        $arguments='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -ZipPath "{1}" -InstallDir "{2}" -ParentPid {3}' -f $updater,$temp,$script:root,$PID
        $helperProcess=Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden -PassThru
        if($null -eq $helperProcess){throw '업데이트 실행기를 시작하지 못했습니다.'}
        $temp=$null  # helper owns cleanup after successful hand-off
        $script:quit=$true
        Save-Prefs
        $script:timer.Stop()
        $script:notify.Visible=$false
        $script:notify.Dispose()
        if($script:settingsForm -and -not $script:settingsForm.IsDisposed){$script:settingsForm.Close()}
        $script:form.Dispose()
        $script:context.ExitThread()
    } catch {
        if($temp){Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue}
        $script:updateLabel.Enabled=$true
        if($script:latestRelease){$script:updateLabel.Text='새 버전 '+([string]$script:latestRelease.tag_name)+'  ·  업데이트 ›'}
        if($script:updateUI -and $script:updateUI.Page -and -not $script:updateUI.Page.IsDisposed){
            $script:updateUI.Status.Text='업데이트 오류: '+$_.Exception.Message
            $script:updateUI.Install.Enabled=$true
        }
        [System.Windows.Forms.MessageBox]::Show('업데이트를 설치하지 못했습니다.'+[Environment]::NewLine+$_.Exception.Message,'AION2 업데이트 오류',[System.Windows.Forms.MessageBoxButtons]::OK,[System.Windows.Forms.MessageBoxIcon]::Error)|Out-Null
    }
}
# Called by automatic and manual release checks, never performs an installation.
function Set-AvailableRelease($release) {
    $script:latestRelease=$release
    if($null -ne $release){
        $script:updateLabel.Text='새 버전 '+([string]$release.tag_name)+'  ·  업데이트 ›'
    } else {
        $script:updateLabel.Text='새 업데이트 · 설치 ›'
    }
    $script:updateLabel.Enabled=$true
    $script:dayRendered=''
    Redraw (Now-KST)
}

function Update-PlatinumResults {
    if($null -eq $script:platinumUI){return}
    $silver=[double]$script:platinumUI.Silver.Value
    $gold=[double]$script:platinumUI.Gold.Value
    $expectedGold=$silver*0.20
    $direct=$silver*0.03
    $fromGold=($gold+$expectedGold)*0.26
    $total=$direct+$fromGold
    $kina=$silver*150000+($gold+$expectedGold)*200000
    $r=$script:platinumUI.Results
    $r['ExpectedGold'].Text=('{0:N3}개' -f $expectedGold)
    $r['DirectPlat'].Text=('{0:N3}개' -f $direct)
    $r['FromGold'].Text=('{0:N3}개' -f $fromGold)
    $r['TotalPlat'].Text=('{0:N3}개' -f $total)
    $r['TotalKina'].Text=('{0:N0} 키나' -f $kina)
    $r['UnitCost'].Text=$(if($total -gt 0){'{0:N0} 키나' -f ($kina/$total)}else{'-'})
}
function Show-Settings {
    if($null -ne $script:settingsForm -and -not $script:settingsForm.IsDisposed) {
        $script:settingsForm.Show(); $script:settingsForm.BringToFront(); $script:settingsForm.Activate(); return
    }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = 'AION2 유스티엘 · 상세설정'
    $dialog.Size = [System.Drawing.Size]::new(910,700)
    $dialog.MinimumSize = [System.Drawing.Size]::new(910,700)
    $dialog.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
    $dialog.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#0F172A')
    $dialog.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#E8F3FF')
    $dialog.Font = [System.Drawing.Font]::new('Malgun Gothic',[single]9)
    $dialog.ShowInTaskbar = $true
    $dialog.TopMost = $true
    $script:settingsForm = $dialog
    $dialog.Add_FormClosed({
        # Restore last saved opacity if the user closed without saving.
        try { $script:form.Opacity = [Math]::Min(1.0,[Math]::Max(0.2,[int]$script:config.OpacityPercent / 100.0)) } catch { }
        $script:settingsForm = $null
    })
    $heading = New-Label 'AION2 / 유스티엘     상세설정' 22 14 790 40 17 '#E9F4FF' $true
    $info = New-Label '주요 보스·요일 일정 · 알림 · 다음 일정 강조 · 프로그램 실행' 23 52 790 27 9 '#96A9BF'
    [void]$dialog.Controls.Add($heading); [void]$dialog.Controls.Add($info)
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.SetBounds(22,93,844,477)
    $tabs.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
    $tabs.Font = [System.Drawing.Font]::new('Malgun Gothic',[single]10,[System.Drawing.FontStyle]::Bold)
    [void]$dialog.Controls.Add($tabs)
    $pageAlarm = New-Object System.Windows.Forms.TabPage
    $pageAlarm.Text = '알림 · 사운드';$pageAlarm.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#0F172A')
    $pageSchedule = New-Object System.Windows.Forms.TabPage
    $pageSchedule.Text = '콘텐츠 · 시간표';$pageSchedule.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#0F172A')
    $pageProgram = New-Object System.Windows.Forms.TabPage
    $pageProgram.Text = '프로그램';$pageProgram.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#0F172A')
    $pagePlatinum = New-Object System.Windows.Forms.TabPage
    $pagePlatinum.Text = '백금공 계산기';$pagePlatinum.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#0F172A')
    $pageArgo = New-Object System.Windows.Forms.TabPage
    $pageArgo.Text = '아그로 일정';$pageArgo.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#0F172A')
    foreach($p in @($pageAlarm,$pageSchedule,$pageProgram,$pagePlatinum,$pageArgo)){ [void]$tabs.TabPages.Add($p) }
    $ink = [System.Drawing.ColorTranslator]::FromHtml('#E8F3FF')
    $mutedInk = [System.Drawing.ColorTranslator]::FromHtml('#9CACBF')
    $script:settingsChecks = @{}
    function Make-SettingsCheck($parent,$key,$caption,$x,$y,$w,$checked) {
        $cb = New-Object System.Windows.Forms.CheckBox
        $cb.Text = $caption;$cb.SetBounds($x,$y,$w,30)
        $cb.Checked = [bool]$checked;$cb.ForeColor = [System.Drawing.ColorTranslator]::FromHtml('#E8F3FF');$cb.BackColor = [System.Drawing.Color]::Transparent
        $cb.Font = [System.Drawing.Font]::new('Malgun Gothic',[single]9)
        [void]$parent.Controls.Add($cb)
        $script:settingsChecks[$key] = $cb
    }
    [void]$pageAlarm.Controls.Add((New-Label '알림 설정' 24 19 290 32 13 '#E8F3FF' $true))
    [void]$pageAlarm.Controls.Add((New-Label '게임을 꺼도 프로그램이 트레이에서 실행 중이면 알림을 받을 수 있습니다.' 24 52 760 25 9 '#9CACBF'))
    Make-SettingsCheck $pageAlarm 'AlertOn' '주요 콘텐츠 알림 사용' 26 105 360 $script:config.AlertOn
    Make-SettingsCheck $pageAlarm 'SoundOn' '알림음 사용' 26 149 360 $script:config.SoundOn
    Make-SettingsCheck $pageAlarm 'PopupOn' 'Windows 알림 배너 표시' 26 193 360 $script:config.PopupOn
    Make-SettingsCheck $pageAlarm 'StartAlertOn' '콘텐츠 시작 시에도 알림' 26 237 360 $script:config.StartAlertOn
    Make-SettingsCheck $pageAlarm 'AlertWhenGameClosed' '아이온2 종료 후에도 백그라운드 알림' 26 281 410 $script:config.AlertWhenGameClosed
    [void]$pageAlarm.Controls.Add((New-Label '사전 알림' 447 100 160 28 10 '#E8F3FF' $true))
    $leadSelect = New-Object System.Windows.Forms.ComboBox
    $leadSelect.DropDownStyle = 'DropDownList';$leadSelect.SetBounds(450,131,178,31)
    foreach($min in @(5,10,15,20,30,60)){[void]$leadSelect.Items.Add("${min}분 전")}
    $leadValues = @(5,10,15,20,30,60)
    $selectedLead = [Array]::IndexOf($leadValues,[int]$script:config.Lead)
    $leadSelect.SelectedIndex = if($selectedLead -ge 0){$selectedLead}else{1}
    [void]$pageAlarm.Controls.Add($leadSelect)
    [void]$pageAlarm.Controls.Add((New-Label '알림음 종류' 447 181 160 28 10 '#E8F3FF' $true))
    $melodySelect = New-Object System.Windows.Forms.ComboBox
    $melodySelect.DropDownStyle = 'DropDownList';$melodySelect.SetBounds(450,212,240,31)
    foreach($name in @('짧은 한 음','기본 3음 멜로디','긴 6음 멜로디')){[void]$melodySelect.Items.Add($name)}
    $melodySelect.SelectedIndex = [Math]::Min(2,[Math]::Max(0,[int]$script:config.Melody))
    [void]$pageAlarm.Controls.Add($melodySelect)
    [void]$pageAlarm.Controls.Add((New-Label '소리 크기' 447 265 160 28 10 '#E8F3FF' $true))
    $volSlider = New-Object System.Windows.Forms.TrackBar
    $volSlider.SetBounds(442,292,245,55);$volSlider.Minimum=0;$volSlider.Maximum=100
    $volSlider.TickFrequency=10;$volSlider.Value=[Math]::Min(100,[Math]::Max(0,[int]$script:config.Volume))
    $volSlider.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#0F172A')
    [void]$pageAlarm.Controls.Add($volSlider)
    $volInfo = New-Label ("$($volSlider.Value)%") 697 289 70 32 10 '#5FE0CC' $true
    $volSlider.Add_Scroll({ $script:detailUI.VolumeInfo.Text = "$($script:detailUI.Volume.Value)%" })
    [void]$pageAlarm.Controls.Add($volInfo)
    [void]$pageAlarm.Controls.Add((New-Label '소리·배너를 확인하려면 아래 [알림 테스트]를 누르세요.' 28 401 760 28 9 '#9CACBF'))
    [void]$pageSchedule.Controls.Add((New-Label '개별 콘텐츠 시간 변경 · 끄기/켜기 · 다음 일정 자동 강조' 20 16 790 31 12 '#E8F3FF' $true))
    [void]$pageSchedule.Controls.Add((New-Label '시간은 1그룹 기준입니다. 그룹별 보스는 2그룹 +30분 / 3그룹 +60분 적용됩니다.' 21 46 785 26 9 '#9CACBF'))
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.SetBounds(16,82,807,340)
    $grid.Anchor = [System.Windows.Forms.AnchorStyles]'Top,Bottom,Left,Right'
    $grid.AllowUserToAddRows=$false;$grid.AllowUserToDeleteRows=$false;$grid.RowHeadersVisible=$false
    $grid.AutoSizeRowsMode='None';$grid.RowTemplate.Height=29
    $grid.BackgroundColor=[System.Drawing.ColorTranslator]::FromHtml('#192538')
    $grid.EnableHeadersVisualStyles=$false;$grid.BorderStyle='None'
    $grid.ColumnHeadersHeight=35
    $grid.ColumnHeadersDefaultCellStyle.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#29405A')
    $grid.ColumnHeadersDefaultCellStyle.ForeColor=[System.Drawing.Color]::White
    $grid.DefaultCellStyle.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#192538')
    $grid.DefaultCellStyle.ForeColor=[System.Drawing.Color]::White
    $grid.DefaultCellStyle.SelectionBackColor=[System.Drawing.ColorTranslator]::FromHtml('#32616A')
    $grid.DefaultCellStyle.SelectionForeColor=[System.Drawing.Color]::White
    $idCol = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $idCol.Name='ID';$idCol.HeaderText='ID';$idCol.Visible=$false;[void]$grid.Columns.Add($idCol)
    $enabledCol=New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
    $enabledCol.Name='Enabled';$enabledCol.HeaderText='사용';$enabledCol.Width=52;[void]$grid.Columns.Add($enabledCol)
    foreach($c in @(@('Day','요일',68),@('Time','시각',80),@('Name','콘텐츠',240),@('Group','그룹',66),@('Note','설명',245))){
        $col=New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $col.Name=$c[0];$col.HeaderText=$c[1];$col.Width=[int]$c[2]
        if($c[0] -ne 'Time'){$col.ReadOnly=$true}
        [void]$grid.Columns.Add($col)
    }
    $weekdayNames=@('일','월','화','수','목','금','토')
    foreach($ev in @($script:events | Sort-Object @{Expression={if($_.Day -eq 'Sunday'){7}else{[int][Enum]::Parse([System.DayOfWeek],$_.Day)}}},Time)) {
        $dayIndex=[int][Enum]::Parse([System.DayOfWeek],$ev.Day)
        [void]$grid.Rows.Add($ev.Id,($ev.Enabled -eq '1'),$weekdayNames[$dayIndex],$ev.Time,$ev.Name, $(if($ev.GroupShift -eq '1'){'적용'}else{'공통'}), $(if($ev.GroupShift -eq '1'){'그룹별 30분 간격'}else{'전체 그룹 공통'}))
    }
    [void]$pageSchedule.Controls.Add($grid)
    $resetSchedule=New-Object System.Windows.Forms.Button
    $resetSchedule.Text='콘텐츠 기본 시각 복원';$resetSchedule.SetBounds(16,427,191,31)
    $resetSchedule.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#29405A')
    $resetSchedule.ForeColor=[System.Drawing.Color]::White;$resetSchedule.FlatStyle='Flat'
    $resetSchedule.Add_Click({
        $answer=[System.Windows.Forms.MessageBox]::Show('콘텐츠 사용 여부와 시작 시각을 기본값으로 바꿀까요? 저장 후 적용 버튼을 눌러야 반영됩니다.','기본 시각 복원',[System.Windows.Forms.MessageBoxButtons]::YesNo)
        if($answer -ne [System.Windows.Forms.DialogResult]::Yes){ return }
        try {
            $base=@{}
            foreach($entry in @(Import-Csv -LiteralPath $script:csvFile -Encoding UTF8)){$base[$entry.Id]=$entry}
            foreach($r in $script:detailUI.Grid.Rows){
                $id=[string]$r.Cells['ID'].Value
                if($base.ContainsKey($id)){
                    $r.Cells['Time'].Value=$base[$id].Time
                    $r.Cells['Enabled'].Value=($base[$id].Enabled -eq '1')
                }
            }
        } catch { [System.Windows.Forms.MessageBox]::Show('기본 일정 파일 읽기 오류: ' + $_.Exception.Message,'AION2') | Out-Null }
    })
    [void]$pageSchedule.Controls.Add($resetSchedule)
    [void]$pageProgram.Controls.Add((New-Label '유스티엘 매칭 그룹' 26 27 330 34 12 '#E8F3FF' $true))
    $groupSelect=New-Object System.Windows.Forms.ComboBox
    $groupSelect.DropDownStyle='DropDownList';$groupSelect.SetBounds(27,69,270,31)
    foreach($g in @('1그룹 · 유스티엘 기본값','2그룹 · +30분','3그룹 · +60분')){[void]$groupSelect.Items.Add($g)}
    $groupSelect.SelectedIndex = [Math]::Min(2,[Math]::Max(0,[int]$script:config.Group-1))
    [void]$pageProgram.Controls.Add($groupSelect)
    [void]$pageProgram.Controls.Add((New-Label '그룹 편성은 변경될 수 있으므로 게임 내 안내를 먼저 확인하세요.' 27 113 775 28 9 '#9CACBF'))
    [void]$pageProgram.Controls.Add((New-Label '화면 표시 · 시작 옵션' 26 166 450 32 12 '#E8F3FF' $true))
    Make-SettingsCheck $pageProgram 'AutoDetect' '아이온2 실행 시 오버레이 자동 표시' 28 215 470 $script:config.AutoDetect
    Make-SettingsCheck $pageProgram 'Pinned' '아이온2 종료 후에도 오버레이 표시' 28 259 470 $script:config.Pinned
    Make-SettingsCheck $pageProgram 'StartWithWindows' 'Windows 시작 시 프로그램 자동 실행' 28 303 490 $script:config.StartWithWindows
    [void]$pageProgram.Controls.Add((New-Label '오버레이 창 불투명도' 28 345 275 28 10 '#E8F3FF' $true))
    $opacitySlider = New-Object System.Windows.Forms.TrackBar
    $opacitySlider.SetBounds(24,374,347,49)
    $opacitySlider.Minimum = 20
    $opacitySlider.Maximum = 100
    $opacitySlider.TickFrequency = 10
    $opacitySlider.SmallChange = 1
    $opacitySlider.LargeChange = 10
    $opacitySlider.Value = [Math]::Min(100,[Math]::Max(20,[int]$script:config.OpacityPercent))
    $opacitySlider.BackColor = [System.Drawing.ColorTranslator]::FromHtml('#0F172A')
    [void]$pageProgram.Controls.Add($opacitySlider)
    $opacityInfo = New-Label ("$($opacitySlider.Value)%") 391 374 128 32 11 '#5FE0CC' $true
    [void]$pageProgram.Controls.Add($opacityInfo)
    $opacitySlider.Add_ValueChanged({
        if($null -ne $script:detailUI -and $null -ne $script:detailUI.OpacityInfo) {
            $script:detailUI.OpacityInfo.Text = ("$($script:detailUI.Opacity.Value)%")
        }
        if(-not $script:form.IsDisposed -and $null -ne $script:detailUI -and $null -ne $script:detailUI.Opacity) { $script:form.Opacity = $script:detailUI.Opacity.Value / 100.0 }
    })
    [void]$pageProgram.Controls.Add((New-Label '20% = 매우 투명  ·  100% = 불투명  ·  오버레이에 실시간 미리보기' 28 422 775 24 9 '#9CACBF'))
    # Platinum craft calculator: same mutually exclusive 77%/20%/3% model as the user's original HTML calculator.
    [void]$pagePlatinum.Controls.Add((New-Label '백금공 기댓값 계산기' 24 22 500 34 15 '#E8F3FF' $true))
    [void]$pagePlatinum.Controls.Add((New-Label '보유한 은공과 금공을 모두 제작에 사용한다고 가정합니다. 기대값은 실제 획득 보장이 아닙니다.' 25 65 789 27 9 '#9CACBF'))
    [void]$pagePlatinum.Controls.Add((New-Label '은공 개수' 25 117 220 27 11 '#E8F3FF' $true))
    [void]$pagePlatinum.Controls.Add((New-Label '금공 개수' 335 117 220 27 11 '#E8F3FF' $true))
    $silverInput = New-Object System.Windows.Forms.NumericUpDown
    $silverInput.SetBounds(25,148,247,35);$silverInput.Minimum=0;$silverInput.Maximum=100000000;$silverInput.ThousandsSeparator=$true
    $silverInput.Font=[System.Drawing.Font]::new('Malgun Gothic',[single]13,[System.Drawing.FontStyle]::Bold)
    $silverInput.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#192538');$silverInput.ForeColor=$ink
    [void]$pagePlatinum.Controls.Add($silverInput)
    $goldInput = New-Object System.Windows.Forms.NumericUpDown
    $goldInput.SetBounds(335,148,247,35);$goldInput.Minimum=0;$goldInput.Maximum=100000000;$goldInput.ThousandsSeparator=$true
    $goldInput.Font=[System.Drawing.Font]::new('Malgun Gothic',[single]13,[System.Drawing.FontStyle]::Bold)
    $goldInput.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#192538');$goldInput.ForeColor=$ink
    [void]$pagePlatinum.Controls.Add($goldInput)
    $calcLabels = @{}
    $results = @(
        @('TotalPlat',   '최종 백금공 기대값',  26, 218),
        @('TotalKina',   '총 예상 소모 키나',   438, 218),
        @('DirectPlat',  '은공에서 직접 백금공', 26, 287),
        @('FromGold',    '금공 → 백금공 기대값',438, 287),
        @('ExpectedGold','은공 제작 후 기대 금공',26, 356),
        @('UnitCost',    '백금공 1개당 기대비용',438,356)
    )
    foreach($item in $results) {
        [void]$pagePlatinum.Controls.Add((New-Label $item[1] ([int]$item[2]) ([int]$item[3]) 355 24 9 '#9CACBF'))
        $label = New-Label '-' ([int]$item[2]) ([int]$item[3]+26) 365 34 14 '#5FE0CC' $true
        [void]$pagePlatinum.Controls.Add($label)
        $calcLabels[$item[0]]=$label
    }
    $script:platinumUI = @{Silver=$silverInput;Gold=$goldInput;Results=$calcLabels}
    $silverInput.Add_ValueChanged({ Update-PlatinumResults })
    $goldInput.Add_ValueChanged({ Update-PlatinumResults })
    Update-PlatinumResults
    [void]$pagePlatinum.Controls.Add((New-Label '확률: 실패 77% / 성공 20% / 대성공 3% (서로 배타적)' 25 431 776 25 9 '#9CACBF'))
    [void]$pagePlatinum.Controls.Add((New-Label '은공 → 백금공 0.082개/개 · 금공 → 백금공 0.26개/개 (기대값)' 25 451 776 24 9 '#9CACBF'))

    # Fixed-time Argo schedule. Times are also independently configurable in the schedule tab.
    [void]$pageArgo.Controls.Add((New-Label '정령왕 아그로 · 고정 출현' 24 26 770 40 15 '#E8F3FF' $true))
    [void]$pageArgo.Controls.Add((New-Label '2026년 10월 28일 패치부터 처치 후 리젠이 아니라 매일 고정 시각에 등장합니다.' 25 80 785 33 10 '#9CACBF'))
    [void]$pageArgo.Controls.Add((New-Label '09:00   오전 9시' 36 150 720 50 20 '#5FE0CC' $true))
    [void]$pageArgo.Controls.Add((New-Label '21:00   오후 9시' 36 218 720 50 20 '#5FE0CC' $true))
    [void]$pageArgo.Controls.Add((New-Label '개별 출현 알림은 [콘텐츠 · 시간표] 탭에서 켜거나 끌 수 있습니다.' 25 314 785 32 10 '#B2C4D8'))
    [void]$pageArgo.Controls.Add((New-Label '기존 수동 타이머와 길드 공유 기능은 더 이상 필요하지 않아 제거했습니다.' 25 356 785 33 9 '#9CACBF'))
    [void]$pageArgo.Controls.Add((New-Label '정기 점검 직후에는 추가 출현하지 않으며 이후 지정 시각에 출현합니다.' 25 399 785 27 9 '#9CACBF'))

    $test = New-Object System.Windows.Forms.Button
    $test.Text='♪ 알림 테스트';$test.SetBounds(26,589,165,38)
    $test.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#29405A');$test.ForeColor=$ink;$test.FlatStyle='Flat'
    $test.Anchor = [System.Windows.Forms.AnchorStyles]'Bottom,Left'
    $test.Add_Click({
        if($script:settingsChecks['SoundOn'].Checked) { Play-Alert ([int]$script:detailUI.Volume.Value) ([int]$script:detailUI.Melody.SelectedIndex) }
        $script:notify.ShowBalloonTip(4500,'AION2 유스티엘','설정창 알림 미리보기입니다.',[System.Windows.Forms.ToolTipIcon]::Info)
    })
    [void]$dialog.Controls.Add($test)
    $saved = New-Label '변경 후 [저장 후 적용]을 누르세요.' 211 588 380 40 8.5 '#9CACBF'
    $saved.Anchor=[System.Windows.Forms.AnchorStyles]'Bottom,Left,Right'
    [void]$dialog.Controls.Add($saved)
    $apply = New-Object System.Windows.Forms.Button
    $apply.Text='저장 후 적용';$apply.SetBounds(608,589,131,38)
    $apply.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#357D73');$apply.ForeColor=[System.Drawing.Color]::White;$apply.FlatStyle='Flat'
    $apply.Anchor=[System.Windows.Forms.AnchorStyles]'Bottom,Right'
    $apply.Add_Click({
        try {
            [void]$script:detailUI.Grid.EndEdit()
            foreach($r in $script:detailUI.Grid.Rows) {
                $value = [string]$r.Cells['Time'].Value
                if($value -notmatch '^([01][0-9]|2[0-3]):[0-5][0-9]$') {
                    $script:detailUI.Tabs.SelectedTab=$script:detailUI.SchedulePage
                    $script:detailUI.Grid.CurrentCell=$r.Cells['Time']
                    [System.Windows.Forms.MessageBox]::Show("HH:mm 시각을 확인하세요: $value",'시간 입력 오류') | Out-Null
                    return
                }
            }
            foreach($e in $script:events) {
                foreach($r in $script:detailUI.Grid.Rows) {
                    if($e.Id -eq [string]$r.Cells['ID'].Value) {
                        $e.Time=[string]$r.Cells['Time'].Value
                        $e.Enabled= if($r.Cells['Enabled'].Value -eq $true){'1'}else{'0'}
                        break
                    }
                }
            }
            Save-Overrides
            foreach($key in @('AlertOn','SoundOn','PopupOn','StartAlertOn','AlertWhenGameClosed','AutoDetect','Pinned')) {
                $script:config[$key]=[bool]$script:settingsChecks[$key].Checked
            }
            $script:config.Lead=@(5,10,15,20,30,60)[$script:detailUI.Lead.SelectedIndex]
            $script:config.Volume=[int]$script:detailUI.Volume.Value
            $script:config.Melody=[int]$script:detailUI.Melody.SelectedIndex
            $script:config.OpacityPercent=[int]$script:detailUI.Opacity.Value
            $script:form.Opacity = [int]$script:config.OpacityPercent / 100.0
            $script:config.Group=[int]$script:detailUI.Group.SelectedIndex + 1
            if([bool]$script:settingsChecks['StartWithWindows'].Checked -ne [bool]$script:config.StartWithWindows) {
                $enable=[bool]$script:settingsChecks['StartWithWindows'].Checked
                try {
                    $runKey='HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
                    if($enable) {
                        $wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
                        $command='"{0}" "{1}"' -f $wscript,(Join-Path $script:root 'AION2_start.vbs')
                        New-ItemProperty -Path $runKey -Name 'AION2YustielOverlayPS' -Value $command -PropertyType String -Force | Out-Null
                    } else { Remove-ItemProperty -Path $runKey -Name 'AION2YustielOverlayPS' -ErrorAction SilentlyContinue }
                    $script:config.StartWithWindows=$enable
                } catch { [System.Windows.Forms.MessageBox]::Show('자동 실행 설정 실패: ' + $_.Exception.Message,'AION2') | Out-Null }
            }
            $script:seen.Clear()
            $script:dayRendered=''
            $script:suppressed=$false
            Save-Prefs
            Update-Visibility; Refresh-Menu; Redraw (Now-KST)
            $script:detailUI.Status.Text='설정 저장 완료 · 오버레이에 즉시 반영됐습니다.'
            $script:detailUI.Status.ForeColor=[System.Drawing.ColorTranslator]::FromHtml('#5FE0CC')
        } catch { [System.Windows.Forms.MessageBox]::Show('설정 적용 오류: ' + $_.Exception.ToString(),'AION2') | Out-Null }
    })
    [void]$dialog.Controls.Add($apply)
    $close = New-Object System.Windows.Forms.Button
    $close.Text='닫기';$close.SetBounds(747,589,112,38)
    $close.BackColor=[System.Drawing.ColorTranslator]::FromHtml('#29405A');$close.ForeColor=$ink;$close.FlatStyle='Flat'
    $close.Anchor=[System.Windows.Forms.AnchorStyles]'Bottom,Right'
    $close.Add_Click({ $script:settingsForm.Close() })
    [void]$dialog.Controls.Add($close)
    $script:detailUI = @{ Dialog=$dialog; Tabs=$tabs; Lead=$leadSelect; Melody=$melodySelect; Volume=$volSlider; VolumeInfo=$volInfo; Opacity=$opacitySlider; OpacityInfo=$opacityInfo; Grid=$grid; Group=$groupSelect; Status=$saved; SchedulePage=$pageSchedule }
    $dialog.Show()
    $dialog.BringToFront();$dialog.Activate()
}
$script:notify.Add_DoubleClick({ $script:config.Pinned = -not $script:config.Pinned; $script:suppressed = $false; Save-Prefs; Update-Visibility; Refresh-Menu })
Refresh-Menu
$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 1000
$script:timer.Add_Tick({ try { Tick-App } catch { $script:timer.Stop(); $script:notify.ShowBalloonTip(5000,'AION2 오류',$_.Exception.Message,[System.Windows.Forms.ToolTipIcon]::Error) } })
$script:timer.Start()
try { Tick-App } catch { throw ('AION2 initial timer error: ' + $_.Exception.ToString()) }
$script:context = New-Object System.Windows.Forms.ApplicationContext
try { [System.Windows.Forms.Application]::Run($script:context) }
finally { try {$script:timer.Stop();$script:notify.Visible=$false;$script:notify.Dispose();$script:form.Dispose()}catch{} }
