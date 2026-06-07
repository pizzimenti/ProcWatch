# ProcWatch

A background watchdog that monitors **every process** (including system ones like
`explorer`) for **sustained** high CPU — a process must stay over a threshold for a
continuous duration before it fires, so transient spikes (e.g. a shell's startup
burst) are ignored.

Built after `explorer.exe` wedged into a blank-taskbar paint loop (3,122 CPU-seconds);
ProcWatch would have caught and auto-restarted it.

## Architecture

Two cooperating processes joined by a file queue under `%ProgramData%\ProcWatch`,
because Windows **session 0 isolation** stops a SYSTEM service from drawing UI in
your desktop session:

| Component | Runs as | Trigger | Job |
|-----------|---------|---------|-----|
| `Engine.ps1` | **SYSTEM** | at startup | sample CPU rates, detect sustained breaches, auto-restart allowlisted procs, execute queued kill/whitelist commands |
| `Agent.ps1`  | **you** (interactive) | at logon | turn notify-queue entries into interactive BurntToast toasts |
| `Handler.ps1`| you | `procwatch://` protocol | translate toast-button clicks into command files |

```
%ProgramData%\ProcWatch\
  config.json            thresholds, allowlists, whitelist (engine owns writes)
  procwatch.log          engine log (rotates at 5 MB)   agent.log / handler.log
  queue\notify\          engine -> agent
  queue\commands\        handler/agent -> engine  (kill / whitelist / ignorepid)
  bin\  *.ps1  ProcWatch.psm1
```

### Why a file queue and not a direct kill from the toast
The toast runs as you; killing another session's or a SYSTEM-owned process would
need elevation. Instead the button only *writes a request*; the privileged SYSTEM
engine performs the kill. No UAC prompts, one privileged code path.

### How CPU is measured
Per process: `ΔTotalProcessorTime / (Δwallclock × coreCount) × 100` = "% of whole
machine" (`cpuBasis: total`), or omit the core divisor for "% of one core"
(`cpuBasis: core`). A breach must persist `durationSeconds` continuously; a single
sub-threshold sample resets the timer. PID reuse is guarded by matching process
`StartTime`.

## config.json (defaults)

| Key | Default | Meaning |
|-----|---------|---------|
| `intervalSeconds` | 5 | sampling cadence |
| `thresholdPercent` | 25 | breach level |
| `durationSeconds` | 120 | must stay over threshold this long |
| `cpuBasis` | `total` | `total` = % of all cores, `core` = % of one |
| `graceSeconds` | 30 | ignore freshly-started PIDs (startup bursts) |
| `renotifyCooldownSeconds` | 600 | min gap between repeat alerts for a PID |
| `restartCooldownSeconds` | 300 | min gap between auto-restarts of a name |
| `maxRestartsPerHour` | 4 | restart circuit-breaker |
| `restartAllowlist` | `["explorer"]` | names auto-restarted on breach |
| `ignoreNames` | `[]` | never alert (grows via the Whitelist button) |
| `protectNames` | system criticals | never killable, even by command |

Edits apply live — the engine reloads config every loop.

## Manage

```powershell
# status (read-only)
pwsh -File C:\ProgramData\ProcWatch\bin\Status.ps1

# change a setting (engine picks it up within one interval)
$c = Get-Content C:\ProgramData\ProcWatch\config.json -Raw | ConvertFrom-Json
$c.thresholdPercent = 40; $c.durationSeconds = 180
$c | ConvertTo-Json -Depth 6 | Set-Content C:\ProgramData\ProcWatch\config.json

# stop / start
Stop-ScheduledTask  -TaskName ProcWatch-Engine
Start-ScheduledTask -TaskName ProcWatch-Engine

# events
Get-WinEvent -FilterHashtable @{LogName='Application';ProviderName='ProcWatch'} -MaxEvents 20
```

## Install / Uninstall / Test (run elevated)

```powershell
pwsh -File <src>\bin\Install.ps1            # deploy + register tasks + start
pwsh -File <src>\bin\Uninstall.ps1          # remove tasks/protocol/source, keep logs
pwsh -File <src>\bin\Uninstall.ps1 -Purge   # also delete %ProgramData%\ProcWatch
pwsh -File <src>\test\Run-Tests.ps1         # 11 isolated tests (sandboxed ProgramData)
```

Source: `C:\Users\user\Code\ProcWatch`  •  Deployed: `C:\ProgramData\ProcWatch`
