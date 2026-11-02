#requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][string]$InvocationPath)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'ReviewCliEnvironment.ps1')
$path = (Resolve-Path -LiteralPath $InvocationPath).ProviderPath
$invocation = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
$executable = [string]$invocation.executable
$null = Get-Command $executable -ErrorAction Stop
$arguments = @($invocation.arguments | ForEach-Object { [string]$_ })
$startedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
$exitCode = $null
$priorProcessDirectory = [Environment]::CurrentDirectory
$priorSearchPath = $env:PATH
$reviewProcessPath = Get-ReviewProcessPath -ToolDirectory (Join-Path (Split-Path -Parent $path) 'rg-tools')
Push-Location -LiteralPath ([string]$invocation.working_directory)
try {
    $env:PATH = $reviewProcessPath
    # Native stderr is reviewer progress; only the exit code decides failure.
    $ErrorActionPreference = 'Continue'
    if ($invocation.standard_input) {
        [string]$invocation.standard_input | & $executable @arguments
    } else {
        & $executable @arguments
    }
    $exitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($exitCode -ne 0) { throw "Review invocation exited $exitCode." }
} finally {
    $completedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $env:PATH = $priorSearchPath
    Pop-Location
    [Environment]::CurrentDirectory = $priorProcessDirectory
    $timing = [ordered]@{ started_at_unix_ms = $startedAt; completed_at_unix_ms = $completedAt; exit_code = $exitCode }
    # Lost timing renders as unavailable; it must not fail a finished review.
    try { [IO.File]::WriteAllText($path + '.timing.json', ($timing | ConvertTo-Json), [Text.UTF8Encoding]::new($false)) }
    catch { Write-Warning "Could not save review timing: $($_.Exception.Message)" }
}
