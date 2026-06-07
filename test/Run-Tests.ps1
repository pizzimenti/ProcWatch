<#
  Run-Tests.ps1 - isolated tests for ProcWatch core logic.
  Redirects $env:ProgramData to a temp dir so nothing touches the real install
  and no admin rights are needed.
#>
$ErrorActionPreference = 'Stop'
$bin = Join-Path (Split-Path $PSScriptRoot -Parent) 'bin'

$pass = 0; $fail = 0
function Check {
    param([string]$Name, [scriptblock]$Test)
    try {
        $ok = & $Test
        if ($ok) { Write-Host "  PASS  $Name" -ForegroundColor Green; $script:pass++ }
        else     { Write-Host "  FAIL  $Name" -ForegroundColor Red;   $script:fail++ }
    } catch {
        Write-Host "  FAIL  $Name  ($($_.Exception.Message))" -ForegroundColor Red; $script:fail++
    }
}

# ---- isolated sandbox ------------------------------------------------------
$sandbox = Join-Path $env:TEMP ("procwatch-test-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $sandbox | Out-Null
$origPD = $env:ProgramData
$env:ProgramData = $sandbox
Write-Host "Sandbox ProgramData = $sandbox`n"

$hog = $null
try {
    Import-Module (Join-Path $bin 'ProcWatch.psm1') -Force
    Initialize-PWDirs
    $root = Get-PWRoot

    Write-Host "[1] Module + config"
    Check 'root is under sandbox' { $root -like "$sandbox*" }
    Check 'default config has expected keys' {
        $c = Get-PWDefaultConfig
        $c.thresholdPercent -and $c.durationSeconds -and ($c.restartAllowlist -contains 'explorer')
    }
    Check 'config round-trips and merges' {
        $c = Get-PWConfig            # writes defaults
        $c.thresholdPercent = 99
        Save-PWConfig $c
        (Get-PWConfig).thresholdPercent -eq 99
    }

    Write-Host "`n[2] Command queue + handler parsing"
    Check 'New-PWCommand writes a file' {
        New-PWCommand @{ type='kill'; pid=4242 } | Out-Null
        (Get-PWCommandFiles).Count -ge 1
    }
    Check 'handler parses kill URI into a command' {
        Get-PWCommandFiles | Remove-Item -Force
        & (Join-Path $bin 'Handler.ps1') 'procwatch://kill/1234'
        $cmds = Get-PWCommandFiles | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }
        ($cmds | Where-Object { $_.type -eq 'kill' -and $_.pid -eq 1234 }).Count -eq 1
    }
    Check 'handler parses whitelist URI' {
        Get-PWCommandFiles | Remove-Item -Force
        & (Join-Path $bin 'Handler.ps1') 'procwatch://whitelist/notepad'
        $cmds = Get-PWCommandFiles | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }
        ($cmds | Where-Object { $_.type -eq 'whitelist' -and $_.name -eq 'notepad' }).Count -eq 1
    }
    Get-PWCommandFiles | Remove-Item -Force -ErrorAction SilentlyContinue

    Write-Host "`n[3] End-to-end breach detection against a real CPU hog"
    # tight test config: core-basis, low duration, no grace
    $c = Get-PWConfig
    $c.intervalSeconds = 2; $c.durationSeconds = 4; $c.graceSeconds = 0
    $c.thresholdPercent = 50; $c.cpuBasis = 'core'
    Save-PWConfig $c

    $hog = Start-Process pwsh -ArgumentList '-NoProfile','-Command','while($true){ $x=1 }' -PassThru -WindowStyle Hidden
    Write-Host "    spawned CPU hog pid $($hog.Id); running engine for ~14s..."
    & (Join-Path $bin 'Engine.ps1') -MaxIterations 7 | Out-Null

    Check 'engine enqueued a breach notify for the hog' {
        $notifies = Get-PWNotifyFiles | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }
        ($notifies | Where-Object { $_.kind -eq 'breach' -and $_.pid -eq $hog.Id }).Count -ge 1
    }
    Check 'engine log recorded the BREACH line' {
        $log = Join-Path $root 'procwatch.log'
        (Test-Path $log) -and (Select-String -Path $log -Pattern 'BREACH' -Quiet)
    }

    Write-Host "`n[4] Whitelist suppresses alerts"
    Get-PWNotifyFiles | Remove-Item -Force -ErrorAction SilentlyContinue
    $c = Get-PWConfig
    $c.ignoreNames = @('pwsh')   # hog is a pwsh process
    Save-PWConfig $c
    & (Join-Path $bin 'Engine.ps1') -MaxIterations 7 | Out-Null
    Check 'no breach notify while whitelisted' {
        $notifies = Get-PWNotifyFiles | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }
        ($notifies | Where-Object { $_.kind -eq 'breach' -and $_.pid -eq $hog.Id }).Count -eq 0
    }

    Write-Host "`n[5] Auto-restart path (allowlisted process)"
    # Use Windows PowerShell (name 'powershell') as a uniquely-named restartable hog,
    # so Stop-Process -Name never touches the pwsh test runner/engine.
    $existing = @(Get-Process powershell -ErrorAction SilentlyContinue)
    if ($existing.Count -gt 0) {
        Write-Host "  SKIP  pre-existing powershell.exe present; not safe to test name-based restart" -ForegroundColor Yellow
    } else {
        Get-PWNotifyFiles | Remove-Item -Force -ErrorAction SilentlyContinue
        $c = Get-PWConfig
        $c.ignoreNames = @(); $c.restartAllowlist = @('powershell')
        $c.intervalSeconds = 2; $c.durationSeconds = 4; $c.graceSeconds = 0
        $c.thresholdPercent = 50; $c.cpuBasis = 'core'
        Save-PWConfig $c
        $rhog = Start-Process powershell -ArgumentList '-NoProfile','-Command','while($true){ $x=1 }' -PassThru -WindowStyle Hidden
        Write-Host "    spawned restartable hog (powershell) pid $($rhog.Id); running engine..."
        & (Join-Path $bin 'Engine.ps1') -MaxIterations 7 | Out-Null
        Check 'engine killed the allowlisted hog' {
            $null -eq (Get-Process -Id $rhog.Id -ErrorAction SilentlyContinue)
        }
        Check 'engine enqueued a "restarted" notify' {
            $notifies = Get-PWNotifyFiles | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json }
            ($notifies | Where-Object { $_.kind -eq 'restarted' -and $_.name -eq 'powershell' }).Count -ge 1
        }
        # safety net in case the engine somehow did not kill it
        Stop-Process -Id $rhog.Id -Force -ErrorAction SilentlyContinue
    }
}
finally {
    if ($hog) { Stop-Process -Id $hog.Id -Force -ErrorAction SilentlyContinue }
    $env:ProgramData = $origPD
    Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host "`n========================================"
Write-Host ("  RESULT: {0} passed, {1} failed" -f $pass, $fail) -ForegroundColor ($fail ? 'Red' : 'Green')
Write-Host "========================================"
exit $fail
