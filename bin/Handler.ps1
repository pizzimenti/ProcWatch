<#
  Handler.ps1 - registered handler for the procwatch:// protocol.
  Invoked by toast buttons as:  pwsh -File Handler.ps1 "procwatch://kill/1234"
  Translates the URI into a command file that the SYSTEM engine consumes.

  URI forms:
    procwatch://kill/<pid>
    procwatch://whitelist/<name>
    procwatch://ignorepid/<pid>
#>
param([Parameter(Position=0)][string]$Uri)

Import-Module (Join-Path $PSScriptRoot 'ProcWatch.psm1') -Force

function HLog { param([string]$m,[string]$lvl='INFO') Write-PWLog $m $lvl 'handler' }

if ([string]::IsNullOrWhiteSpace($Uri)) { HLog 'invoked with empty URI' 'WARN'; return }

try {
    # strip scheme, split verb / argument
    $rest  = $Uri -replace '(?i)^procwatch:[/]*', ''
    $parts = $rest.Trim('/').Split('/', 2)
    $verb  = $parts[0].ToLowerInvariant()
    $arg   = if ($parts.Count -gt 1) { [uri]::UnescapeDataString($parts[1]) } else { '' }

    switch ($verb) {
        'kill' {
            $procId = 0
            if ([int]::TryParse($arg, [ref]$procId)) {
                New-PWCommand @{ type='kill'; pid=$procId } | Out-Null
                HLog "queued kill for pid $procId" 'ACTION'
            } else { HLog "kill: bad pid '$arg'" 'WARN' }
        }
        'whitelist' {
            if ($arg) {
                New-PWCommand @{ type='whitelist'; name=$arg } | Out-Null
                HLog "queued whitelist for '$arg'" 'ACTION'
            } else { HLog 'whitelist: empty name' 'WARN' }
        }
        'ignorepid' {
            $procId = 0
            if ([int]::TryParse($arg, [ref]$procId)) {
                New-PWCommand @{ type='ignorepid'; pid=$procId } | Out-Null
                HLog "queued ignorepid for pid $procId" 'ACTION'
            } else { HLog "ignorepid: bad pid '$arg'" 'WARN' }
        }
        default { HLog "unknown verb '$verb' in '$Uri'" 'WARN' }
    }
} catch {
    HLog "handler error on '$Uri': $($_.Exception.Message)" 'ERROR'
}
