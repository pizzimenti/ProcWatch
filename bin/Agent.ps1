<#
  Agent.ps1 - runs in the interactive USER session via Scheduled Task at logon.
  Watches the notify queue and raises interactive toasts (BurntToast) with
  Kill / Whitelist / Ignore buttons that fire procwatch:// protocol URIs.

  Params:
    -MaxIterations N  stop after N poll cycles (0 = forever; used by tests)
    -PollSeconds N    queue poll interval (default 2)
#>
param(
    [int]$MaxIterations = 0,
    [int]$PollSeconds = 2
)

Import-Module (Join-Path $PSScriptRoot 'ProcWatch.psm1') -Force
Initialize-PWDirs

function ALog { param([string]$m,[string]$lvl='INFO') Write-PWLog $m $lvl 'agent' }

# single instance per session
$mutex = New-Object System.Threading.Mutex($false, 'Local\ProcWatchAgent')
if (-not $mutex.WaitOne(0)) { ALog 'agent already running in this session; exiting' 'WARN'; return }

$script:HasBurntToast = $false
try {
    Import-Module BurntToast -ErrorAction Stop
    $script:HasBurntToast = $true
    ALog 'agent started (BurntToast available)'
} catch {
    ALog 'BurntToast not available; falling back to msg.exe (non-interactive)' 'WARN'
}

function Show-Fallback {
    param([string]$Text)
    # basic, non-interactive message box to the active session
    try { & "$env:WINDIR\System32\msg.exe" * /TIME:60 $Text 2>$null } catch { }
}

function Show-BreachToast {
    param($n)
    $title = 'ProcWatch — sustained high CPU'
    $body  = "{0} (pid {1}) at {2}% for {3}s" -f $n.name, $n.pid, $n.rate, $n.sustained
    if (-not $script:HasBurntToast) { Show-Fallback "$title`n$body"; return }

    $btnKill  = New-BTButton -Content 'Kill'      -Arguments ("procwatch://kill/{0}"      -f $n.pid)  -ActivationType Protocol
    $btnWhite = New-BTButton -Content 'Whitelist' -Arguments ("procwatch://whitelist/{0}" -f $n.name) -ActivationType Protocol
    $btnIgnr  = New-BTButton -Content 'Ignore'    -Arguments ("procwatch://ignorepid/{0}" -f $n.pid)  -ActivationType Protocol
    New-BurntToastNotification -Text $title, $body -Button $btnKill, $btnWhite, $btnIgnr `
        -UniqueIdentifier ("procwatch-{0}" -f $n.pid)
}

function Show-RestartToast {
    param($n)
    $title = 'ProcWatch — auto-restarted shell'
    $body  = "Restarted {0} (was {1}% sustained)" -f $n.name, $n.rate
    if (-not $script:HasBurntToast) { Show-Fallback "$title`n$body"; return }
    $btnWhite = New-BTButton -Content 'Stop auto-restarting' -Arguments ("procwatch://whitelist/{0}" -f $n.name) -ActivationType Protocol
    New-BurntToastNotification -Text $title, $body -Button $btnWhite
}

$iter = 0
try {
    while ($true) {
        foreach ($f in Get-PWNotifyFiles) {
            $n = $null
            try { $n = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { }
            Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
            if (-not $n) { continue }
            try {
                switch ($n.kind) {
                    'breach'    { Show-BreachToast  $n; ALog "toast: breach $($n.name) pid $($n.pid)" }
                    'restarted' { Show-RestartToast $n; ALog "toast: restarted $($n.name)" }
                    default     { ALog "unknown notify kind '$($n.kind)'" 'WARN' }
                }
            } catch {
                ALog "toast failed: $($_.Exception.Message)" 'ERROR'
            }
        }
        $iter++
        if ($MaxIterations -gt 0 -and $iter -ge $MaxIterations) { break }
        Start-Sleep -Seconds $PollSeconds
    }
}
finally {
    $mutex.ReleaseMutex(); $mutex.Dispose()
    ALog 'agent stopped'
}
