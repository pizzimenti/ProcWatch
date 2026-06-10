<#
  Uninstall.ps1 - remove ProcWatch. MUST run elevated.
    -Purge  also delete %ProgramData%\ProcWatch (config + logs). Default keeps them.
#>
param([switch]$Purge)
$ErrorActionPreference = 'Continue'

$p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    throw 'Uninstall.ps1 must be run elevated.'
}

# includes the pre-0.2.0 'ProcWatch-Agent' name so upgrades-then-uninstall stay clean
foreach ($t in 'ProcWatch-Engine','ProcWatch-Tray','ProcWatch-Agent') {
    if (Get-ScheduledTask -TaskName $t -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask  -TaskName $t -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "Removed task $t"
    }
}

# stop any still-running engine/tray/agent (mutex-held loops)
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'ProcWatch\\bin\\(Engine|Tray|Agent)\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host "Stopped pid $($_.ProcessId)" }

if (Test-Path 'HKLM:\SOFTWARE\Classes\procwatch') {
    Remove-Item 'HKLM:\SOFTWARE\Classes\procwatch' -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host 'Removed procwatch:// protocol'
}

try {
    if ([System.Diagnostics.EventLog]::SourceExists('ProcWatch')) {
        [System.Diagnostics.EventLog]::DeleteEventSource('ProcWatch')
        Write-Host 'Removed event source'
    }
} catch { Write-Warning "Event source removal: $($_.Exception.Message)" }

if ($Purge) {
    $root = Join-Path $env:ProgramData 'ProcWatch'
    Remove-Item $root -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Purged $root"
} else {
    Write-Host "Kept $(Join-Path $env:ProgramData 'ProcWatch') (config + logs). Use -Purge to delete."
}
Write-Host 'Uninstall complete.' -ForegroundColor Green
