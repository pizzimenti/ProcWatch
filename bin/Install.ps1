<#
  Install.ps1 - deploy ProcWatch. MUST run elevated (admin).
  - copies binaries to %ProgramData%\ProcWatch\bin
  - sets queue ACLs so the user-session agent/handler can read+write
  - registers the Application event-log source
  - installs BurntToast into Windows PowerShell 5.1 (the tray's host) - best effort
  - registers the procwatch:// protocol handler (HKLM)
  - creates two scheduled tasks: ProcWatch-Engine (SYSTEM @boot), ProcWatch-Tray (user @logon)
#>
[CmdletBinding()]
param([switch]$NoStart)

$ErrorActionPreference = 'Stop'

function Assert-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        throw 'Install.ps1 must be run from an elevated (Administrator) session.'
    }
}
Assert-Admin

# ---- interpreters ----------------------------------------------------------
# Engine + protocol handler run on pwsh 7 (SYSTEM-launchable, machine-wide path).
# The tray runs on Windows PowerShell 5.1 with -STA: NotifyIcon needs an STA
# message pump (pwsh is MTA), and 5.1 is BurntToast's native host.
$pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
$Interp     = if (Test-Path $pwsh) { $pwsh } else { "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
$TrayInterp = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
Write-Host "Engine interpreter: $Interp"
Write-Host "Tray interpreter:   $TrayInterp (-STA)"

$Root    = Join-Path $env:ProgramData 'ProcWatch'
$BinDst  = Join-Path $Root 'bin'
$BinSrc  = $PSScriptRoot
$Queue   = Join-Path $Root 'queue'

# ---- stop any running instances (upgrade path) ------------------------------
# The engine holds a single-instance mutex: if an old engine survives the
# install, the freshly started new one exits immediately and the upgrade only
# takes effect at next reboot. A surviving pre-0.2.0 Agent.ps1 would also
# compete with the tray for the notify queue. So stop them all first.
Get-CimInstance Win32_Process -Filter "Name='pwsh.exe' OR Name='powershell.exe'" |
    Where-Object { $_.CommandLine -match 'ProcWatch\\bin\\(Engine|Tray|Agent)\.ps1' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                     Write-Host "Stopped running instance pid $($_.ProcessId)" }

# ---- deploy files ----------------------------------------------------------
New-Item -ItemType Directory -Force -Path $BinDst, (Join-Path $Queue 'notify'), (Join-Path $Queue 'commands') | Out-Null
Copy-Item (Join-Path $BinSrc '*.ps*') -Destination $BinDst -Force
Remove-Item (Join-Path $BinDst 'Agent.ps1') -Force -ErrorAction SilentlyContinue  # superseded in 0.2.0
Write-Host "Copied binaries to $BinDst"

# import the just-deployed module for helpers
Import-Module (Join-Path $BinDst 'ProcWatch.psm1') -Force
Initialize-PWDirs
Get-PWConfig | Out-Null   # writes default config.json if missing
Write-Host "Config: $(Join-Path $Root 'config.json')"

# ---- ACLs: let BUILTIN\Users modify the queue (write commands, delete notifies) ----
# S-1-5-32-545 = BUILTIN\Users (locale-independent)
& icacls "$Queue" /grant '*S-1-5-32-545:(OI)(CI)M' /T /Q | Out-Null
Write-Host "Granted Users:Modify on $Queue"

# config.json too, so the tray's "Edit config" can save without elevation.
# (Users can already steer the engine through the command queue, so this adds
# no privilege they don't effectively have.)
& icacls (Join-Path $Root 'config.json') /grant '*S-1-5-32-545:M' /Q | Out-Null
Write-Host "Granted Users:Modify on config.json"

# ---- event-log source ------------------------------------------------------
try { Register-PWEventSource; Write-Host 'Registered event source ProcWatch (Application log)' }
catch { Write-Warning "Event source registration failed: $($_.Exception.Message)" }

# ---- BurntToast for the tray's host (Windows PowerShell 5.1) ----------------
# The tray runs under 5.1, so BurntToast must be on 5.1's AllUsers module path.
# 5.1's own Install-Module first bootstraps the NuGet provider, which has proven
# slow and hang-prone - so when pwsh 7 is available we let its PowerShellGet
# download the module straight into 5.1's path instead. Best effort either way;
# the tray degrades to balloon tips if the module is missing.
try {
    & $TrayInterp -NoProfile -Command "exit [int](-not (Get-Module -ListAvailable BurntToast))"
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Installing BurntToast for Windows PowerShell 5.1...'
        $btDst = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'   # 5.1 AllUsers module path
        if (Test-Path $pwsh) {
            & $pwsh -NoProfile -Command "Save-Module BurntToast -Path '$btDst' -Force"
        } else {
            & $TrayInterp -NoProfile -Command @'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
}
Install-Module BurntToast -Scope AllUsers -Force -AllowClobber
'@
        }
        Write-Host 'BurntToast installed for 5.1.'
    } else { Write-Host 'BurntToast already present on 5.1.' }
} catch {
    Write-Warning "BurntToast install failed ($($_.Exception.Message)); tray will use balloon tips."
}

# ---- protocol handler (procwatch://) ---------------------------------------
$key = 'HKLM:\SOFTWARE\Classes\procwatch'
New-Item -Path $key -Force | Out-Null
New-ItemProperty -Path $key -Name '(default)'    -Value 'URL:ProcWatch Protocol' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $key -Name 'URL Protocol' -Value ''                       -PropertyType String -Force | Out-Null
$cmdKey = Join-Path $key 'shell\open\command'
New-Item -Path $cmdKey -Force | Out-Null
$handlerCmd = '"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{1}" "%1"' -f $Interp, (Join-Path $BinDst 'Handler.ps1')
New-ItemProperty -Path $cmdKey -Name '(default)' -Value $handlerCmd -PropertyType String -Force | Out-Null
Write-Host "Registered procwatch:// -> $handlerCmd"

# ---- scheduled tasks -------------------------------------------------------
$engineName = 'ProcWatch-Engine'
$trayName   = 'ProcWatch-Tray'
# also remove the pre-0.2.0 'ProcWatch-Agent' task on upgrade (superseded by the tray)
foreach ($t in $engineName, $trayName, 'ProcWatch-Agent') {
    Unregister-ScheduledTask -TaskName $t -Confirm:$false -ErrorAction SilentlyContinue
}

# Engine: SYSTEM, at startup, auto-restart on failure
$engineAction = New-ScheduledTaskAction -Execute $Interp `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $BinDst 'Engine.ps1'))
$engineTrigger = New-ScheduledTaskTrigger -AtStartup
$engineSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden `
    -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
$enginePrincipal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
Register-ScheduledTask -TaskName $engineName -Action $engineAction -Trigger $engineTrigger `
    -Settings $engineSettings -Principal $enginePrincipal `
    -Description 'ProcWatch monitor engine (sustained CPU watchdog).' | Out-Null
Write-Host "Registered task: $engineName (SYSTEM, at startup)"

# Tray: interactive Users group, at logon, under 5.1 with -STA (NotifyIcon host)
$trayAction = New-ScheduledTaskAction -Execute $TrayInterp `
    -Argument ('-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $BinDst 'Tray.ps1'))
$trayTrigger = New-ScheduledTaskTrigger -AtLogOn
$traySettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
$trayPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
Register-ScheduledTask -TaskName $trayName -Action $trayAction -Trigger $trayTrigger `
    -Settings $traySettings -Principal $trayPrincipal `
    -Description 'ProcWatch system-tray app (status icon + interactive toasts).' | Out-Null
Write-Host "Registered task: $trayName (Users, at logon)"

# ---- start now -------------------------------------------------------------
if (-not $NoStart) {
    Start-ScheduledTask -TaskName $engineName
    Start-ScheduledTask -TaskName $trayName
    Start-Sleep -Seconds 2
    Write-Host "`nStarted both tasks."
}

Write-Host "`nInstall complete." -ForegroundColor Green
Get-ScheduledTask -TaskName $engineName, $trayName |
    Select-Object TaskName, State | Format-Table -AutoSize
