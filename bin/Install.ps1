<#
  Install.ps1 - deploy ProcWatch. MUST run elevated (admin).
  - copies binaries to %ProgramData%\ProcWatch\bin
  - sets queue ACLs so the user-session agent/handler can read+write
  - registers the Application event-log source
  - installs BurntToast (best effort)
  - registers the procwatch:// protocol handler (HKLM)
  - creates two scheduled tasks: ProcWatch-Engine (SYSTEM @boot), ProcWatch-Agent (user @logon)
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

# ---- choose an interpreter SYSTEM can launch -------------------------------
$pwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
$Interp = if (Test-Path $pwsh) { $pwsh } else { "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" }
Write-Host "Interpreter: $Interp"

$Root    = Join-Path $env:ProgramData 'ProcWatch'
$BinDst  = Join-Path $Root 'bin'
$BinSrc  = $PSScriptRoot
$Queue   = Join-Path $Root 'queue'

# ---- deploy files ----------------------------------------------------------
New-Item -ItemType Directory -Force -Path $BinDst, (Join-Path $Queue 'notify'), (Join-Path $Queue 'commands') | Out-Null
Copy-Item (Join-Path $BinSrc '*.ps*') -Destination $BinDst -Force
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

# ---- event-log source ------------------------------------------------------
try { Register-PWEventSource; Write-Host 'Registered event source ProcWatch (Application log)' }
catch { Write-Warning "Event source registration failed: $($_.Exception.Message)" }

# ---- BurntToast (best effort) ----------------------------------------------
try {
    if (-not (Get-Module -ListAvailable BurntToast)) {
        Write-Host 'Installing BurntToast (AllUsers)...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
        }
        Install-Module BurntToast -Scope AllUsers -Force -AllowClobber
        Write-Host 'BurntToast installed.'
    } else { Write-Host 'BurntToast already present.' }
} catch {
    Write-Warning "BurntToast install failed ($($_.Exception.Message)); agent will fall back to msg.exe."
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
$agentName  = 'ProcWatch-Agent'
foreach ($t in $engineName, $agentName) {
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

# Agent: interactive Users group, at logon
$agentAction = New-ScheduledTaskAction -Execute $Interp `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $BinDst 'Agent.ps1'))
$agentTrigger = New-ScheduledTaskTrigger -AtLogOn
$agentSettings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit ([TimeSpan]::Zero) -Hidden
$agentPrincipal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
Register-ScheduledTask -TaskName $agentName -Action $agentAction -Trigger $agentTrigger `
    -Settings $agentSettings -Principal $agentPrincipal `
    -Description 'ProcWatch user-session notifier (interactive toasts).' | Out-Null
Write-Host "Registered task: $agentName (Users, at logon)"

# ---- start now -------------------------------------------------------------
if (-not $NoStart) {
    Start-ScheduledTask -TaskName $engineName
    Start-ScheduledTask -TaskName $agentName
    Start-Sleep -Seconds 2
    Write-Host "`nStarted both tasks."
}

Write-Host "`nInstall complete." -ForegroundColor Green
Get-ScheduledTask -TaskName $engineName, $agentName |
    Select-Object TaskName, State | Format-Table -AutoSize
