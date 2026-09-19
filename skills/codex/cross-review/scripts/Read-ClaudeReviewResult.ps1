[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TranscriptPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [switch]$RequireNativeReview
)

$ErrorActionPreference = 'Stop'
$nativeCalls = @{}
$nativeCompleted = $false
$result = $null
foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $TranscriptPath).ProviderPath)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $event = $line | ConvertFrom-Json
    foreach ($block in $event.message.content) {
        if ($block.type -eq 'tool_use' -and $block.name -eq 'Skill' -and
            $block.input.skill -eq 'code-review' -and [string]$block.input.args -match '^high(?:\s|$)') {
            $nativeCalls[[string]$block.id] = $true
        }
        if ($block.type -eq 'tool_result' -and $nativeCalls.ContainsKey([string]$block.tool_use_id) -and -not $block.is_error) {
            $nativeCompleted = $true
        }
    }
    if ($event.type -eq 'result') {
        if ($null -ne $result) { throw 'Claude returned multiple final result records.' }
        $result = $event
    }
}
if ($null -eq $result -or $result.subtype -ne 'success' -or $result.is_error -or [string]::IsNullOrWhiteSpace([string]$result.result)) {
    throw 'Claude did not return a successful, non-empty final report.'
}
$permissionDenials = if ($null -eq $result.permission_denials) { @() } else { @($result.permission_denials) }
if ($RequireNativeReview -and -not $nativeCompleted) { throw 'No successful native code-review high invocation was observed; refusing a generic review.' }
[IO.File]::WriteAllText($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath), [string]$result.result, [Text.UTF8Encoding]::new($false))
[ordered]@{
    report_path = $OutputPath
    native_review_observed = $nativeCompleted
    model_usage = $result.modelUsage
    permission_denial_count = $permissionDenials.Count
    permission_denials = $permissionDenials
} | ConvertTo-Json -Depth 12
