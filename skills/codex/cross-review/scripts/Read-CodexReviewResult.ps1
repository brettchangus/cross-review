#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TranscriptPath,
    [Parameter(Mandatory)][string]$ReportPath
)

$ErrorActionPreference = 'Stop'
$events = [Collections.Generic.List[object]]::new()
$lineNumber = 0
foreach ($line in [IO.File]::ReadLines((Resolve-Path -LiteralPath $TranscriptPath).ProviderPath)) {
    $lineNumber++
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try { $events.Add(($line | ConvertFrom-Json -Depth 100)) }
    catch { throw "Invalid Codex JSONL at line $lineNumber in '$TranscriptPath': $($_.Exception.Message)" }
}

if ($events.Count -eq 0) { throw "Codex transcript is empty: '$TranscriptPath'." }
$failedTurn = @($events | Where-Object { $_.type -eq 'turn.failed' })
if ($failedTurn.Count -gt 0) { throw "Codex review reported turn.failed; see '$TranscriptPath'." }
$completedTurn = @($events | Where-Object { $_.type -eq 'turn.completed' })
if ($completedTurn.Count -eq 0) { throw "Codex review did not report turn.completed; see '$TranscriptPath'." }

if (-not (Test-Path -LiteralPath $ReportPath -PathType Leaf)) {
    throw "Codex did not write its final report: '$ReportPath'."
}
$report = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $ReportPath).ProviderPath)
if ([string]::IsNullOrWhiteSpace($report)) { throw "Codex final report is empty: '$ReportPath'." }

$denialPatterns = @(
    '(?im)^\s*failed in sandbox(?:\s|:)',
    '(?im)^\s*execution error:.*\b(?:windows|linux|macos)\s+sandbox:',
    '(?im)^\s*(?:approval|permission)\s+(?:denied|rejected|blocked)\b',
    '(?im)^\s*(?:sandbox|policy)\s+(?:denied|rejected|blocked)\b'
)
$denials = [Collections.Generic.List[object]]::new()
foreach ($event in $events) {
    if ($event.type -ne 'item.completed' -or $event.item.type -ne 'command_execution' -or $event.item.status -ne 'failed') { continue }
    $message = [string]$event.item.aggregated_output
    if (-not ($denialPatterns | Where-Object { $message -match $_ } | Select-Object -First 1)) { continue }
    $trimmed = $message.Trim()
    if ($trimmed.Length -gt 2000) { $trimmed = $trimmed.Substring(0, 2000) + '…' }
    $denials.Add([ordered]@{
        command = [string]$event.item.command
        exit_code = $event.item.exit_code
        message = $trimmed
    })
}

[ordered]@{
    schema_version = 1
    report_path = (Resolve-Path -LiteralPath $ReportPath).ProviderPath
    turn_completed = $true
    permission_denial_count = $denials.Count
    permission_denials = @($denials)
} | ConvertTo-Json -Depth 8
