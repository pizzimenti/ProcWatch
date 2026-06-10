<#
  Engine.ps1 - ProcWatch monitor loop. Runs as SYSTEM via Scheduled Task at boot.
  Samples per-process CPU rate, fires on sustained breaches, executes queued commands.

  Params (for testing):
    -Console         also write log lines to stdout
    -MaxIterations N stop after N sample cycles (0 = run forever)
#>
param(
    [switch]$Console,
    [int]$MaxIterations = 0
)

Import-Module (Join-Path $PSScriptRoot 'ProcWatch.psm1') -Force
Initialize-PWDirs

$cores = [Environment]::ProcessorCount

function Log {
    param([string]$Msg, [string]$Level = 'INFO')
    Write-PWLog $Msg $Level 'procwatch'
    if ($Console) { Write-Host ("{0} [{1}] {2}" -f (Get-Date).ToString('HH:mm:ss'), $Level, $Msg) }
}

# ---- single-instance guard -------------------------------------------------
# The mutex name is derived from the data root, so it is unique per install. A
# sandboxed test engine (different %ProgramData%) therefore never collides with
# a deployed SYSTEM engine's mutex - which a non-SYSTEM process can't even open.
$mutexName = 'Global\ProcWatch-Engine-' + ((Get-PWRoot) -replace '[\\:]', '_')
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0)) {
    Log 'another engine instance is already running; exiting' 'WARN'
    return
}

Log "engine starting (cores=$cores, pid=$PID)" 'INFO'
Write-PWEvent "ProcWatch engine started (pid=$PID)" 1004 'Information'

# ---- runtime state ---------------------------------------------------------
$prev        = @{}   # pid -> @{ Cpu(ms); Time; Name; Start }
$state       = @{}   # pid -> @{ Name; FirstSeen; OverSince; LastNotify }
$restarts    = @{}   # name -> [datetime[]] recent restart times
$ignorePids  = New-Object System.Collections.Generic.HashSet[int]  # session-scoped "ignore this instance"
$lastBreach  = $null # most recent breach summary, surfaced in the heartbeat for the tray
$breachCount = 0     # breaches fired since this engine started
$lastStatus  = $null # last heartbeat written; re-published with stopped=true on exit

# Rolling per-process CPU window for the tray's "top processes" popup. Each
# entry is one sample cycle's usage; entries older than the window are dropped.
$TopWindowSeconds = 60
$TopCount         = 3
$cpuWindow = New-Object System.Collections.Generic.Queue[object]

function Get-Snapshot {
    $snap = @{}
    $captured = Get-Date
    foreach ($p in [System.Diagnostics.Process]::GetProcesses()) {
        try {
            $snap[$p.Id] = @{
                Cpu   = $p.TotalProcessorTime.TotalMilliseconds
                Name  = $p.ProcessName
                Start = $p.StartTime
                Time  = $captured
            }
        } catch {
            # System/Idle and protected procs deny TotalProcessorTime/StartTime - skip
        } finally {
            $p.Dispose()
        }
    }
    $snap
}

function Test-Protected {
    param([string]$Name, $Cfg)
    $Cfg.protectNames -contains $Name
}

# ---- command queue (kill / whitelist / ignorepid) --------------------------
function Invoke-Commands {
    param($Cfg)
    foreach ($f in Get-PWCommandFiles) {
        $cmd = $null
        try { $cmd = Get-Content $f.FullName -Raw | ConvertFrom-Json } catch { }
        Remove-Item $f.FullName -Force -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        switch ($cmd.type) {
            'kill' {
                $targetPid = [int]$cmd.pid
                $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
                if (-not $proc) { Log "kill: pid $targetPid no longer exists" 'WARN'; break }
                if (Test-Protected $proc.ProcessName $Cfg) {
                    Log "kill REFUSED: $($proc.ProcessName) (pid $targetPid) is protected" 'WARN'
                    Write-PWEvent "Refused kill of protected process $($proc.ProcessName) (pid $targetPid)" 1002 'Warning'
                    break
                }
                try {
                    Stop-Process -Id $targetPid -Force
                    Log "killed $($proc.ProcessName) (pid $targetPid) by user request" 'ACTION'
                    Write-PWEvent "Killed $($proc.ProcessName) (pid $targetPid) on user request" 1002 'Warning'
                    $state.Remove($targetPid) | Out-Null
                } catch {
                    Log "kill failed for pid $targetPid : $($_.Exception.Message)" 'ERROR'
                }
            }
            'whitelist' {
                $name = [string]$cmd.name
                if ($Cfg.ignoreNames -notcontains $name) {
                    $Cfg.ignoreNames = @($Cfg.ignoreNames + $name)
                    Save-PWConfig $Cfg
                    Log "whitelisted process name '$name' (added to ignoreNames)" 'ACTION'
                    Write-PWEvent "Whitelisted process name '$name'" 1003 'Information'
                }
            }
            'ignorepid' {
                $ip = [int]$cmd.pid
                [void]$ignorePids.Add($ip)
                Log "ignoring pid $ip for this session" 'ACTION'
            }
            'pause' {
                if (-not $Cfg.paused) {
                    $Cfg.paused = $true
                    Save-PWConfig $Cfg
                    Log 'monitoring PAUSED by user (tray)' 'ACTION'
                    Write-PWEvent 'Monitoring paused by user' 1005 'Information'
                }
            }
            'resume' {
                if ($Cfg.paused) {
                    $Cfg.paused = $false
                    Save-PWConfig $Cfg
                    Log 'monitoring RESUMED by user (tray)' 'ACTION'
                    Write-PWEvent 'Monitoring resumed by user' 1005 'Information'
                }
            }
            default { Log "unknown command type '$($cmd.type)'" 'WARN' }
        }
    }
}

function Invoke-RestartExplorerClass {
    param($Proc, $Cfg, [double]$Rate)
    $name = $Proc.Name
    # circuit breaker: count restarts in the last hour
    $hourAgo = (Get-Date).AddHours(-1)
    if (-not $restarts.ContainsKey($name)) { $restarts[$name] = @() }
    $restarts[$name] = @($restarts[$name] | Where-Object { $_ -gt $hourAgo })
    if ($restarts[$name].Count -ge $Cfg.maxRestartsPerHour) {
        Log "restart of $name SUPPRESSED: $($restarts[$name].Count) restarts in last hour (cap=$($Cfg.maxRestartsPerHour))" 'WARN'
        Write-PWEvent "Restart of $name suppressed by circuit breaker" 1001 'Warning'
        # fall back to alerting so the user knows
        return $false
    }
    # cooldown since last restart
    if ($restarts[$name].Count -gt 0) {
        $last = ($restarts[$name] | Measure-Object -Maximum).Maximum
        if ((Get-Date) -lt $last.AddSeconds($Cfg.restartCooldownSeconds)) {
            Log "restart of $name within cooldown; skipping this cycle" 'INFO'
            return $true   # treated as handled (don't also alert)
        }
    }
    try {
        Stop-Process -Name $name -Force
        $restarts[$name] += (Get-Date)
        Log ("auto-restarted {0} (was {1:n1}% sustained)" -f $name, $Rate) 'ACTION'
        Write-PWEvent ("Auto-restarted {0}; sustained CPU {1:n1}%" -f $name, $Rate) 1001 'Warning'
        New-PWNotify @{ kind='restarted'; name=$name; rate=[math]::Round($Rate,1) } | Out-Null
        return $true
    } catch {
        Log "auto-restart of $name failed: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

# ---- main loop -------------------------------------------------------------
$iter = 0
try {
    while ($true) {
        $cfg = Get-PWConfig
        Invoke-Commands $cfg

        $now  = Get-Date
        $curr = Get-Snapshot

        # accumulate this cycle's per-process CPU into the rolling top window.
        # Deliberately NOT gated on paused: the tray's top-processes popup stays
        # live even while detection is paused.
        $winUsage = @{}
        foreach ($procId in $curr.Keys) {
            if (-not $prev.ContainsKey($procId)) { continue }
            $c = $curr[$procId]; $p = $prev[$procId]
            if ($c.Start -ne $p.Start) { continue }   # PID reuse
            $ms = $c.Cpu - $p.Cpu
            if ($ms -gt 0) { $winUsage[$procId] = @{ Name = $c.Name; Ms = $ms } }
        }
        $cpuWindow.Enqueue(@{ Time = $now; Usage = $winUsage })
        while ($cpuWindow.Count -gt 0 -and ($now - $cpuWindow.Peek().Time).TotalSeconds -gt $TopWindowSeconds) {
            [void]$cpuWindow.Dequeue()
        }

        # When paused (via the tray) we still sample and publish a heartbeat, but
        # take no detection action — so resuming is instant and the tray stays live.
        if (-not $cfg.paused -and $prev.Count -gt 0) {
            foreach ($procId in $curr.Keys) {
                if (-not $prev.ContainsKey($procId)) { continue }
                $c = $curr[$procId]; $p = $prev[$procId]
                # guard against PID reuse: same start time
                if ($c.Start -ne $p.Start) { continue }

                $elapsedMs = ($now - $p.Time).TotalMilliseconds
                if ($elapsedMs -le 0) { continue }
                $cpuDelta  = $c.Cpu - $p.Cpu
                if ($cpuDelta -lt 0) { $cpuDelta = 0 }

                $rate = if ($cfg.cpuBasis -eq 'core') {
                    ($cpuDelta / $elapsedMs) * 100
                } else {
                    ($cpuDelta / ($elapsedMs * $cores)) * 100
                }

                # track first-seen for grace window
                if (-not $state.ContainsKey($procId)) {
                    $state[$procId] = @{ Name=$c.Name; FirstSeen=$now; OverSince=$null; LastNotify=$null }
                }
                $st = $state[$procId]

                if ($rate -ge $cfg.thresholdPercent) {
                    if (-not $st.OverSince) { $st.OverSince = $now }
                } else {
                    $st.OverSince = $null
                    continue
                }

                # grace: ignore freshly-started processes (startup bursts)
                if (($now - $st.FirstSeen).TotalSeconds -lt $cfg.graceSeconds) { continue }

                $sustained = ($now - $st.OverSince).TotalSeconds
                if ($sustained -lt $cfg.durationSeconds) { continue }

                # ---- breach confirmed ----
                if ($cfg.ignoreNames -contains $c.Name) { continue }
                if ($ignorePids.Contains($procId))      { continue }

                # renotify cooldown
                if ($st.LastNotify -and ($now -lt $st.LastNotify.AddSeconds($cfg.renotifyCooldownSeconds))) {
                    continue
                }

                Log ("BREACH {0} (pid {1}) at {2:n1}% for {3:n0}s (threshold {4}% / {5}s)" -f `
                        $c.Name, $procId, $rate, $sustained, $cfg.thresholdPercent, $cfg.durationSeconds) 'ACTION'
                Write-PWEvent ("Sustained CPU breach: {0} (pid {1}) {2:n1}% for {3:n0}s" -f `
                        $c.Name, $procId, $rate, $sustained) 1000 'Warning'

                # record for the heartbeat so the tray can surface "last breach"
                $breachCount++
                $lastBreach = @{
                    name = $c.Name; pid = $procId; rate = [math]::Round($rate,1)
                    at = $now.ToString('o')
                }

                $handled = $false
                if (($cfg.restartAllowlist -contains $c.Name) -and -not (Test-Protected $c.Name $cfg)) {
                    $handled = Invoke-RestartExplorerClass @{ Name=$c.Name } $cfg $rate
                }
                if (-not $handled) {
                    if ($cfg.notify.toast) {
                        New-PWNotify @{
                            kind='breach'; name=$c.Name; pid=$procId
                            rate=[math]::Round($rate,1); sustained=[math]::Round($sustained)
                            threshold=$cfg.thresholdPercent
                        } | Out-Null
                    }
                }
                $st.LastNotify = $now
                $st.OverSince  = $now   # reset window so we re-measure before re-firing
            }
        }

        # prune state for dead PIDs
        foreach ($deadId in @($state.Keys | Where-Object { -not $curr.ContainsKey($_) })) {
            $state.Remove($deadId) | Out-Null
        }

        # top processes over the rolling window, by total CPU time consumed.
        # pct is machine-wide ("overall compute"); alive=false marks a process
        # that burned CPU within the window but has since exited.
        $agg = @{}
        foreach ($entry in $cpuWindow) {
            foreach ($procId in $entry.Usage.Keys) {
                $u = $entry.Usage[$procId]
                if (-not $agg.ContainsKey($procId)) { $agg[$procId] = @{ Name = $u.Name; Ms = 0.0 } }
                $agg[$procId].Ms += $u.Ms
            }
        }
        $spanSec = [math]::Max(($now - $cpuWindow.Peek().Time).TotalSeconds, 1.0)
        $top = @($agg.GetEnumerator() | Sort-Object { $_.Value.Ms } -Descending |
            Select-Object -First $TopCount | ForEach-Object {
                @{
                    name  = $_.Value.Name
                    pid   = $_.Key
                    pct   = [math]::Round(($_.Value.Ms / ($spanSec * 1000.0 * $cores)) * 100, 1)
                    alive = $curr.ContainsKey($_.Key)
                }
            })

        # publish heartbeat for the tray (atomic write via the module)
        $lastStatus = @{
            version     = Get-PWVersion
            pid         = $PID
            heartbeat   = $now.ToString('o')        # tray compares against this for freshness
            paused      = [bool]$cfg.paused
            interval    = $cfg.intervalSeconds
            threshold   = $cfg.thresholdPercent
            basis       = $cfg.cpuBasis
            duration    = $cfg.durationSeconds
            watching    = $curr.Count               # processes seen this cycle
            breachCount = $breachCount
            lastBreach  = $lastBreach
            top         = $top
            topWindow   = $TopWindowSeconds
        }
        Write-PWStatus $lastStatus

        $prev = $curr
        $iter++
        if ($MaxIterations -gt 0 -and $iter -ge $MaxIterations) {
            Log "reached MaxIterations=$MaxIterations; exiting" 'INFO'
            break
        }
        Start-Sleep -Seconds $cfg.intervalSeconds
    }
}
catch {
    Log "FATAL: $($_.Exception.Message)`n$($_.ScriptStackTrace)" 'ERROR'
    Write-PWEvent "ProcWatch engine crashed: $($_.Exception.Message)" 1010 'Error'
    throw
}
finally {
    # final heartbeat marks a clean stop so the tray flips to "down" at once.
    # Re-publish the last full status (top processes, counts) with stopped=true
    # rather than a bare marker, so observers keep the last-known picture.
    try {
        $final = if ($lastStatus) { $lastStatus } else { @{ version = (Get-PWVersion); pid = $PID } }
        $final.stopped   = $true
        $final.heartbeat = (Get-Date).ToString('o')
        Write-PWStatus $final
    } catch { }
    $mutex.ReleaseMutex()
    $mutex.Dispose()
    Log 'engine stopped' 'INFO'
    Write-PWEvent 'ProcWatch engine stopped' 1004 'Information'
}
