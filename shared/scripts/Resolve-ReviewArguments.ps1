[CmdletBinding()]
param([string[]]$ReviewArguments = @())

$ErrorActionPreference = 'Stop'
$effort = 'medium'
$effortSeen = $false
$pullRequestId = $null
$prUrl = $null
. (Join-Path $PSScriptRoot 'ReviewProvider.ps1')
for ($index = 0; $index -lt $ReviewArguments.Count; $index++) {
    $token = $ReviewArguments[$index]
    switch ($token) {
        'pr' {
            if ($null -ne $pullRequestId -or $index + 1 -ge $ReviewArguments.Count) { throw 'Expected exactly one positive PR ID after pr.' }
            $index++
            $value = $ReviewArguments[$index]
            if ($value -match '^https://') {
                $url = Get-ReviewPrUrl $value
                $prUrl = $value
                $pullRequestId = $url.number
            } else {
                $parsedId = 0
                if (-not [int]::TryParse($value, [ref]$parsedId) -or $parsedId -le 0) { throw 'PR ID must be a positive integer or GitHub PR URL.' }
                $pullRequestId = $parsedId
            }
        }
        '--effort' {
            if ($effortSeen -or $index + 1 -ge $ReviewArguments.Count) { throw 'Expected exactly one value after --effort.' }
            $index++
            $candidate = $ReviewArguments[$index].ToLowerInvariant()
            if ($candidate -notin @('low', 'medium', 'high', 'xhigh')) { throw 'Effort must be low, medium, high, or xhigh.' }
            $effort = $candidate
            $effortSeen = $true
        }
        default { throw "Unknown cross-review argument: $token" }
    }
}
[ordered]@{ pull_request_id = $pullRequestId; pr_url = $prUrl; effort = $effort; effort_source = 'explicit' } | ConvertTo-Json -Compress
