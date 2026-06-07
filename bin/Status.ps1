<#
  Status.ps1 - read-only health view of ProcWatch.
    -Lines N   tail this many engine-log lines (default 15)
#>
param([int]$Lines = 15)

Import-Module (Join-Path $PSScriptRoot 'ProcWatch.psm1') -Force
$root = Get-PWRoot

Write-Host "== Scheduled tasks ==" -ForegroundColor Cyan
Get-ScheduledTask -TaskName 'ProcWatch-Engine','ProcWatch-Agent' -ErrorAction SilentlyContinue |
    ForEach-Object {
        $info = $_ | Get-ScheduledTaskInfo
        [pscustomobject]@{ Task=$_.TaskName; State=$_.State; LastRun=$info.LastRunTime; LastResult=('0x{0:X}' -f $info.LastTaskResult) }
    } | Format-Table -AutoSize

Write-Host "== Running processes ==" -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'ProcWatch\\bin\\(Engine|Agent)\.ps1' } |
    ForEach-Object {
        $m = if ($_.CommandLine -match 'Engine') { 'Engine' } else { 'Agent' }
        [pscustomobject]@{ Role=$m; PID=$_.ProcessId }
    } | Format-Table -AutoSize

Write-Host "== Config ==" -ForegroundColor Cyan
$c = Get-PWConfig
[pscustomobject]@{
    threshold   = "$($c.thresholdPercent)% ($($c.cpuBasis))"
    duration    = "$($c.durationSeconds)s"
    interval    = "$($c.intervalSeconds)s"
    restartList = ($c.restartAllowlist -join ', ')
    whitelist   = (($c.ignoreNames -join ', ') -replace '^$','(none)')
} | Format-List

Write-Host "== Queue ==" -ForegroundColor Cyan
"  pending notifies: $((Get-PWNotifyFiles).Count)   pending commands: $((Get-PWCommandFiles).Count)"

Write-Host "`n== Recent events (ProcWatch) ==" -ForegroundColor Cyan
try {
    Get-WinEvent -FilterHashtable @{ LogName='Application'; ProviderName='ProcWatch' } -MaxEvents 8 -ErrorAction Stop |
        Select-Object TimeCreated, Id, LevelDisplayName, @{n='Message';e={($_.Message -split "`n")[0]}} |
        Format-Table -AutoSize -Wrap
} catch { Write-Host '  (no events yet)' }

Write-Host "== Engine log (last $Lines) ==" -ForegroundColor Cyan
$log = Join-Path $root 'procwatch.log'
if (Test-Path $log) { Get-Content $log -Tail $Lines } else { Write-Host '  (no log yet)' }
