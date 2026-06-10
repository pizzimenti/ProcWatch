# ProcWatch.psm1 - shared helpers for the ProcWatch process monitor.
# Imported by Engine.ps1 (SYSTEM), Agent.ps1 (user), Handler.ps1 (protocol).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---- Version ---------------------------------------------------------------
# Single source of truth for the product version (shown in the tray's About box
# and stamped into the heartbeat). Keep in sync with the VERSION file and tags.
$script:Version = '0.2.0'
function Get-PWVersion { $script:Version }

# ---- Paths -----------------------------------------------------------------
$script:Root       = Join-Path $env:ProgramData 'ProcWatch'
$script:ConfigPath = Join-Path $script:Root 'config.json'
$script:StatusPath = Join-Path $script:Root 'status.json'   # engine heartbeat (engine writes, tray reads)
$script:QueueNotify   = Join-Path $script:Root 'queue\notify'
$script:QueueCommands = Join-Path $script:Root 'queue\commands'

function Get-PWRoot { $script:Root }

function Initialize-PWDirs {
    foreach ($d in @($script:Root, $script:QueueNotify, $script:QueueCommands, (Join-Path $script:Root 'bin'))) {
        if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    }
}

# ---- Config ----------------------------------------------------------------
function Get-PWDefaultConfig {
    [pscustomobject]@{
        intervalSeconds        = 5      # how often to sample
        thresholdPercent       = 25     # CPU breach level
        durationSeconds        = 120    # must stay over threshold this long to fire
        cpuBasis               = 'total' # 'total' = % of all cores; 'core' = % of one core
        graceSeconds           = 30     # ignore a freshly-seen PID for this long (startup bursts)
        renotifyCooldownSeconds= 600    # do not re-alert the same PID more often than this
        restartCooldownSeconds = 300    # min gap between auto-restarts of the same name
        maxRestartsPerHour     = 4      # circuit-breaker on restart loops
        restartAllowlist       = @('explorer')
        paused                 = $false # when true the engine samples but takes no action (tray Pause/Resume)
        ignoreNames            = @()    # never alert on these process names (managed via Whitelist button)
        protectNames           = @('System','Idle','Registry','Memory Compression','csrss','wininit',
                                    'services','lsass','smss','winlogon','fontdrvhost','dwm','MsMpEng')
        notify                 = [pscustomobject]@{ toast=$true; eventLog=$true; log=$true }
    }
}

function Get-PWConfig {
    if (Test-Path $script:ConfigPath) {
        try {
            $loaded = Get-Content $script:ConfigPath -Raw | ConvertFrom-Json
        } catch {
            Write-PWLog "config.json unreadable ($($_.Exception.Message)); using defaults" 'WARN' 'procwatch'
            return Get-PWDefaultConfig
        }
        # Merge: start from defaults, overlay any keys present in the file.
        $cfg = Get-PWDefaultConfig
        foreach ($p in $loaded.PSObject.Properties) {
            $cfg | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
        }
        return $cfg
    }
    $def = Get-PWDefaultConfig
    Save-PWConfig $def
    $def
}

function Save-PWConfig {
    param([Parameter(Mandatory)] $Config)
    Initialize-PWDirs
    $tmp = "$script:ConfigPath.tmp"
    $Config | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $script:ConfigPath -Force
    # The atomic replace gives config.json the tmp file's inherited ACL,
    # silently dropping the explicit Users:Modify ACE the installer grants
    # (needed by the tray's "Edit config") - re-assert it on every save.
    & icacls $script:ConfigPath /grant '*S-1-5-32-545:M' /Q | Out-Null
}

# ---- Status heartbeat (engine -> tray) -------------------------------------
# The tray runs as the logged-in user and cannot inspect the SYSTEM engine's
# memory, so the engine publishes a small heartbeat file each loop. The tray
# treats a stale heartbeat (older than a few intervals) as "engine down".
function Write-PWStatus {
    param([Parameter(Mandatory)][hashtable]$Status)
    Initialize-PWDirs
    $tmp = "$script:StatusPath.tmp"
    ($Status | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item -Path $tmp -Destination $script:StatusPath -Force
}

function Get-PWStatus {
    if (-not (Test-Path $script:StatusPath)) { return $null }
    try { Get-Content $script:StatusPath -Raw | ConvertFrom-Json } catch { $null }
}

# ---- Logging ---------------------------------------------------------------
function Write-PWLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','ACTION')][string]$Level = 'INFO',
        [string]$Component = 'procwatch'   # log file base name (procwatch / agent / handler)
    )
    Initialize-PWDirs
    $logPath = Join-Path $script:Root "$Component.log"
    # size-based rotation at 5 MB
    if (Test-Path $logPath) {
        $len = (Get-Item $logPath).Length
        if ($len -gt 5MB) {
            $bak = "$logPath.1"
            if (Test-Path $bak) { Remove-Item $bak -Force }
            Move-Item $logPath $bak -Force
        }
    }
    $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line  = "{0} [{1,-6}] {2}" -f $stamp, $Level, $Message
    # retry briefly on sharing violations
    for ($i=0; $i -lt 5; $i++) {
        try { Add-Content -Path $logPath -Value $line -Encoding UTF8; break }
        catch { Start-Sleep -Milliseconds 50 }
    }
}

# ---- Event Log -------------------------------------------------------------
$script:EvtSource = 'ProcWatch'
$script:EvtLog    = 'Application'

function Register-PWEventSource {
    # Requires admin; call from Install.ps1.
    if (-not [System.Diagnostics.EventLog]::SourceExists($script:EvtSource)) {
        [System.Diagnostics.EventLog]::CreateEventSource($script:EvtSource, $script:EvtLog)
    }
}

function Write-PWEvent {
    param(
        [Parameter(Mandatory)][string]$Message,
        [int]$EventId = 1000,
        [ValidateSet('Information','Warning','Error')][string]$EntryType = 'Information'
    )
    try {
        if ([System.Diagnostics.EventLog]::SourceExists($script:EvtSource)) {
            [System.Diagnostics.EventLog]::WriteEntry($script:EvtSource, $Message, $EntryType, $EventId)
        }
    } catch {
        # never let event-log issues break the loop
        Write-PWLog "event-log write failed: $($_.Exception.Message)" 'WARN'
    }
}

# ---- Queue: notify (engine -> agent) ---------------------------------------
function New-PWNotify {
    param([Parameter(Mandatory)][hashtable]$Data)
    Initialize-PWDirs
    $id   = [guid]::NewGuid().ToString('N')
    $file = Join-Path $script:QueueNotify "$id.json"
    $tmp  = "$file.tmp"
    ($Data | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item $tmp $file -Force
    $id
}

function Get-PWNotifyFiles {
    if (-not (Test-Path $script:QueueNotify)) { return @() }
    Get-ChildItem $script:QueueNotify -Filter '*.json' -File | Sort-Object LastWriteTime
}

# ---- Queue: commands (handler/agent -> engine) -----------------------------
function New-PWCommand {
    param([Parameter(Mandatory)][hashtable]$Data)
    Initialize-PWDirs
    $id   = [guid]::NewGuid().ToString('N')
    $file = Join-Path $script:QueueCommands "$id.json"
    $tmp  = "$file.tmp"
    ($Data | ConvertTo-Json -Depth 6) | Set-Content -Path $tmp -Encoding UTF8
    Move-Item $tmp $file -Force
    $id
}

function Get-PWCommandFiles {
    if (-not (Test-Path $script:QueueCommands)) { return @() }
    Get-ChildItem $script:QueueCommands -Filter '*.json' -File | Sort-Object LastWriteTime
}

Export-ModuleMember -Function Get-PWRoot, Get-PWVersion, Initialize-PWDirs, Get-PWDefaultConfig, Get-PWConfig,
    Save-PWConfig, Write-PWStatus, Get-PWStatus, Write-PWLog, Register-PWEventSource, Write-PWEvent,
    New-PWNotify, Get-PWNotifyFiles, New-PWCommand, Get-PWCommandFiles
