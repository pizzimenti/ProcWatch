<#
  Tray.ps1 - ProcWatch system-tray app. Runs in the interactive USER session via
  Scheduled Task at logon, under Windows PowerShell 5.1 with -STA (NotifyIcon needs
  an STA message pump; 5.1 is STA by default and is BurntToast's native host).

  Responsibilities (it replaces the old headless Agent.ps1):
    1. Show a tray icon whose colour reflects live engine state, read from the
       engine's status.json heartbeat (green=monitoring, amber=paused/recent breach,
       grey=engine down/stale).
    2. Offer a context menu: Pause/Resume, open config, open logs, recent activity,
       About, Exit.
    3. Drain the notify queue and raise interactive BurntToast toasts (Kill /
       Whitelist / Ignore) - the same actionable notifications as before.

  All privileged actions (kill, whitelist, pause) are performed by the SYSTEM
  engine; the tray only ever enqueues command files via the shared module.

  Params:
    -PollSeconds N  heartbeat/queue poll cadence (default 2)
#>
param([int]$PollSeconds = 2)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ProcWatch.psm1') -Force
Initialize-PWDirs
Add-Type -AssemblyName System.Windows.Forms, System.Drawing

function TLog { param([string]$m, [string]$lvl = 'INFO') Write-PWLog $m $lvl 'tray' }

# ---- single instance per session ------------------------------------------
$mutex = New-Object System.Threading.Mutex($false, 'Local\ProcWatchTray')
if (-not $mutex.WaitOne(0)) { TLog 'tray already running in this session; exiting' 'WARN'; return }

# ---- BurntToast (optional; degrade to balloon tips if missing) -------------
$script:HasBT = $false
try { Import-Module BurntToast -ErrorAction Stop; $script:HasBT = $true; TLog 'tray started (BurntToast available)' }
catch { TLog 'BurntToast unavailable; using balloon tips' 'WARN' }

$RepoUrl = 'https://github.com/pizzimenti/ProcWatch'

# ---- icon factory: a filled dot of a given colour --------------------------
# Drawn at runtime so the repo carries no binary .ico assets. The three icons are
# created once and live for the process lifetime (the GDI handle leak is bounded).
function New-DotIcon {
    param([System.Drawing.Color]$Color)
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $Color
    $g.FillEllipse($brush, 2, 2, 11, 11)
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(90, 0, 0, 0)), 1
    $g.DrawEllipse($pen, 2, 2, 11, 11)
    $g.Dispose(); $brush.Dispose(); $pen.Dispose()
    $icon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    $bmp.Dispose()
    $icon
}
$icoGreen = New-DotIcon ([System.Drawing.Color]::FromArgb(46, 204, 113))   # monitoring
$icoAmber = New-DotIcon ([System.Drawing.Color]::FromArgb(241, 196, 15))   # paused / recent breach
$icoGray  = New-DotIcon ([System.Drawing.Color]::FromArgb(149, 165, 166))  # engine down / stale

# ---- toasts (folded in from the old Agent.ps1) -----------------------------
function Show-BreachToast {
    param($n)
    $title = 'ProcWatch - sustained high CPU'
    $body  = "{0} (pid {1}) at {2}% for {3}s" -f $n.name, $n.pid, $n.rate, $n.sustained
    if (-not $script:HasBT) { $script:Ni.ShowBalloonTip(8000, $title, $body, 'Warning'); return }
    $btnKill  = New-BTButton -Content 'Kill'      -Arguments ("procwatch://kill/{0}"      -f $n.pid)  -ActivationType Protocol
    $btnWhite = New-BTButton -Content 'Whitelist' -Arguments ("procwatch://whitelist/{0}" -f $n.name) -ActivationType Protocol
    $btnIgnr  = New-BTButton -Content 'Ignore'    -Arguments ("procwatch://ignorepid/{0}" -f $n.pid)  -ActivationType Protocol
    New-BurntToastNotification -Text $title, $body -Button $btnKill, $btnWhite, $btnIgnr -UniqueIdentifier ("procwatch-{0}" -f $n.pid)
}
function Show-RestartToast {
    param($n)
    $title = 'ProcWatch - auto-restarted shell'
    $body  = "Restarted {0} (was {1}% sustained)" -f $n.name, $n.rate
    if (-not $script:HasBT) { $script:Ni.ShowBalloonTip(8000, $title, $body, 'Info'); return }
    $btnWhite = New-BTButton -Content 'Stop auto-restarting' -Arguments ("procwatch://whitelist/{0}" -f $n.name) -ActivationType Protocol
    New-BurntToastNotification -Text $title, $body -Button $btnWhite
}

# ---- tray UI ---------------------------------------------------------------
$ni = New-Object System.Windows.Forms.NotifyIcon
$script:Ni = $ni
$ni.Icon = $icoGray
$ni.Text = 'ProcWatch (starting...)'
$ni.Visible = $true

$menu      = New-Object System.Windows.Forms.ContextMenuStrip
$miHeader  = $menu.Items.Add(("ProcWatch v{0}" -f (Get-PWVersion)));         $miHeader.Enabled = $false
$miStatus  = $menu.Items.Add('Status: ...');                                  $miStatus.Enabled = $false
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miPause   = $menu.Items.Add('Pause monitoring')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miConfig  = $menu.Items.Add('Edit config...')
$miLogs    = $menu.Items.Add('Open logs folder')
$miActivity= $menu.Items.Add('Recent activity...')
[void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
$miAbout   = $menu.Items.Add('About')
$miExit    = $menu.Items.Add('Exit tray')
$ni.ContextMenuStrip = $menu

# Pause/Resume: enqueue a command for the SYSTEM engine; never flips config here.
$miPause.add_Click({
    $st = Get-PWStatus
    if ($st -and $st.paused) { New-PWCommand @{ type = 'resume' } | Out-Null; TLog 'requested resume' 'ACTION' }
    else                     { New-PWCommand @{ type = 'pause'  } | Out-Null; TLog 'requested pause'  'ACTION' }
})
$miConfig.add_Click({
    # config.json is admin-writable only (it carries the engine's protection
    # policy), so editing elevates via UAC; declining the prompt is fine.
    try { Start-Process notepad.exe (Join-Path (Get-PWRoot) 'config.json') -Verb RunAs }
    catch { TLog 'config edit cancelled at UAC prompt' 'WARN' }
})
$miLogs.add_Click({ Start-Process explorer.exe (Get-PWRoot) })
$miActivity.add_Click({
    $log = Join-Path (Get-PWRoot) 'procwatch.log'
    $tail = if (Test-Path $log) { (Get-Content $log -Tail 12) -join "`n" } else { '(no log yet)' }
    [System.Windows.Forms.MessageBox]::Show($tail, 'ProcWatch - recent activity') | Out-Null
})
$miAbout.add_Click({
    [System.Windows.Forms.MessageBox]::Show(
        ("ProcWatch v{0}`nSustained-CPU process watchdog.`n`n{1}" -f (Get-PWVersion), $RepoUrl),
        'About ProcWatch') | Out-Null
})
$miExit.add_Click({ $script:Ni.Visible = $false; [System.Windows.Forms.Application]::Exit() })
# double-click opens the logs folder
$ni.add_MouseDoubleClick({ Start-Process explorer.exe (Get-PWRoot) })

# ---- top-processes popup (left-click) ---------------------------------------
# A small borderless flyout listing the top consumers over the engine's rolling
# window (heartbeat 'top'). Rows for processes that burned CPU in the window but
# have since exited render muted grey. Hides on focus loss, click, or timeout.
$popup = New-Object System.Windows.Forms.Form
$popup.FormBorderStyle = 'None'
$popup.ShowInTaskbar   = $false
$popup.TopMost         = $true
$popup.StartPosition   = 'Manual'
$popup.BackColor       = [System.Drawing.Color]::FromArgb(32, 32, 32)
$popup.Size            = New-Object System.Drawing.Size 300, 112

$popTitle = New-Object System.Windows.Forms.Label
$popTitle.AutoSize = $false
$popTitle.SetBounds(12, 8, 276, 18)
$popTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 8.5, [System.Drawing.FontStyle]::Bold)
$popTitle.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
$popup.Controls.Add($popTitle)

$popRows = @(0, 1, 2 | ForEach-Object {
    $l = New-Object System.Windows.Forms.Label
    $l.AutoSize = $false
    $l.SetBounds(12, 30 + $_ * 25, 276, 20)
    $l.Font = New-Object System.Drawing.Font('Segoe UI', 9.5)
    $popup.Controls.Add($l)
    $l
})

$popupHide = New-Object System.Windows.Forms.Timer
$popupHide.Interval = 8000
$popupHide.add_Tick({ $popupHide.Stop(); $popup.Hide() })
$popup.add_Deactivate({ $popupHide.Stop(); $popup.Hide() })
$popup.add_Click({ $popupHide.Stop(); $popup.Hide() })

function Show-TopPopup {
    $st  = Get-PWStatus
    $top = if ($st) { @($st.top) } else { @() }
    $win = if ($st -and $st.topWindow) { $st.topWindow } else { 60 }
    $popTitle.Text = "TOP CPU - LAST $win s (machine-wide)"
    for ($i = 0; $i -lt 3; $i++) {
        $l = $popRows[$i]
        if ($i -lt $top.Count -and $top[$i]) {
            $t = $top[$i]
            $name = if ($t.name.Length -gt 22) { $t.name.Substring(0, 21) + '…' } else { $t.name }
            $l.Text = "{0,5:n1}%  {1}  (pid {2}){3}" -f $t.pct, $name, $t.pid, $(if ($t.alive) { '' } else { '  - ended' })
            $l.ForeColor = if ($t.alive) { [System.Drawing.Color]::FromArgb(230, 230, 230) }
                           else          { [System.Drawing.Color]::FromArgb(120, 120, 120) }
        } else {
            $l.Text = if ($i -eq 0) { '(no data from engine yet)' } else { '' }
            $l.ForeColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
        }
    }
    # place near the cursor, clamped to the working area (above the taskbar)
    $pos = [System.Windows.Forms.Cursor]::Position
    $wa  = [System.Windows.Forms.Screen]::FromPoint($pos).WorkingArea
    $x = [int][math]::Min([math]::Max($pos.X - $popup.Width / 2, $wa.Left), $wa.Right - $popup.Width)
    $y = [int]$(if ($pos.Y -gt ($wa.Top + $wa.Bottom) / 2) { $pos.Y - $popup.Height - 12 } else { $pos.Y + 12 })
    $popup.Location = New-Object System.Drawing.Point $x, $y
    $popup.Show()
    $popup.Activate()
    $popupHide.Stop(); $popupHide.Start()
}

$ni.add_MouseClick({
    param($s, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        try { Show-TopPopup } catch { TLog "popup failed: $($_.Exception.Message)" 'ERROR' }
    }
})

# ---- live update + queue drain (on the timer tick) -------------------------
function Update-FromStatus {
    $st = Get-PWStatus
    $fresh = $false
    if ($st -and $st.heartbeat -and -not $st.stopped) {
        try {
            $hb = [datetime]::Parse($st.heartbeat, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
            $age = ([datetime]::Now - $hb).TotalSeconds
            $interval = if ($st.interval) { [double]$st.interval } else { 5 }
            $fresh = $age -le ([math]::Max($interval * 3, 15))   # stale after 3 missed beats
        } catch { $fresh = $false }
    }

    if (-not $fresh) {
        $ni.Icon = $icoGray
        $tip = 'ProcWatch: engine down'
        $miStatus.Text = 'Engine: not running (no heartbeat)'
        $miPause.Text  = 'Pause monitoring'
        $miPause.Enabled = $false
    }
    elseif ($st.paused) {
        $ni.Icon = $icoAmber
        $tip = 'ProcWatch: PAUSED'
        $miStatus.Text = ("Engine: PAUSED  -  watching {0} procs" -f $st.watching)
        $miPause.Text  = 'Resume monitoring'
        $miPause.Enabled = $true
    }
    else {
        # amber briefly after a breach, else green
        $recent = $false
        if ($st.lastBreach -and $st.lastBreach.at) {
            try { $recent = (([datetime]::Now) - [datetime]::Parse($st.lastBreach.at, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)).TotalSeconds -lt 60 } catch {}
        }
        $ni.Icon = if ($recent) { $icoAmber } else { $icoGreen }
        $tip = ("ProcWatch: monitoring ({0}% / {1}s)" -f $st.threshold, $st.duration)
        $lb = if ($st.lastBreach) { "  -  last: $($st.lastBreach.name) @ $($st.lastBreach.rate)%" } else { '' }
        $miStatus.Text = ("Engine: running  -  watching {0} procs  -  {1} breaches{2}" -f $st.watching, $st.breachCount, $lb)
        $miPause.Text  = 'Pause monitoring'
        $miPause.Enabled = $true
    }
    # NotifyIcon.Text is capped at 63 chars on .NET Framework
    if ($tip.Length -gt 63) { $tip = $tip.Substring(0, 63) }
    $ni.Text = $tip
}

function Drain-Notifications {
    foreach ($f in Get-PWNotifyFiles) {
        $n = $null
        try { $n = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch {}
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        if (-not $n) { continue }
        try {
            switch ($n.kind) {
                'breach'    { Show-BreachToast  $n; TLog "toast: breach $($n.name) pid $($n.pid)" }
                'restarted' { Show-RestartToast $n; TLog "toast: restarted $($n.name)" }
                default     { TLog "unknown notify kind '$($n.kind)'" 'WARN' }
            }
        } catch { TLog "toast failed: $($_.Exception.Message)" 'ERROR' }
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [math]::Max($PollSeconds, 1) * 1000
$timer.add_Tick({
    try { Update-FromStatus; Drain-Notifications }
    catch { TLog "tick error: $($_.Exception.Message)" 'ERROR' }
})
$timer.Start()
Update-FromStatus   # paint once immediately

# ---- run the message loop --------------------------------------------------
try {
    [System.Windows.Forms.Application]::Run()
}
finally {
    $timer.Stop(); $timer.Dispose()
    $popupHide.Stop(); $popupHide.Dispose(); $popup.Dispose()
    $ni.Visible = $false; $ni.Dispose()
    $mutex.ReleaseMutex(); $mutex.Dispose()
    TLog 'tray stopped'
}
