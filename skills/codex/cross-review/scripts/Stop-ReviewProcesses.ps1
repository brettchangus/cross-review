#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateCount(1, 2)][string[]]$InvocationPath)

$ErrorActionPreference = 'Stop'
$paths = @($InvocationPath | ForEach-Object { (Resolve-Path -LiteralPath $_).ProviderPath })
# Mark every invocation first, including one the supervisor has not started yet.
foreach ($path in $paths) { [IO.File]::WriteAllText($path + '.cancel', 'cancelled') }
foreach ($path in $paths) {
    $identityPath = $path + '.process.json'
    if (-not (Test-Path -LiteralPath $identityPath)) { continue }
    $identity = Get-Content -LiteralPath $identityPath -Raw | ConvertFrom-Json
    $process = Get-Process -Id ([int]$identity.process_id) -ErrorAction SilentlyContinue
    if ($null -eq $process) { continue }
    try {
        if ($process.HasExited) { continue }
        # A reused PID must never target an unrelated process.
        if ($process.StartTime.ToUniversalTime().Ticks -ne [long]$identity.started_at_ticks) { continue }
        try { $process.Kill($true) }
        catch { if (-not $process.HasExited) { throw } }
        if (-not $process.WaitForExit(10000)) { throw "Reviewer PID $($identity.process_id) did not stop; preserve its workspace and run data." }
    } finally { $process.Dispose() }
}
Write-Output 'Cancellation requested. Wait for the supervisor to exit before removing its workspace or run data.'
