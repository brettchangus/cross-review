#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputPath,
    [Parameter(Mandatory)][string]$ComparisonReportPath,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$inputData = Get-Content -LiteralPath $InputPath -Raw | ConvertFrom-Json

function Read-Milliseconds($Value, [string]$Name) {
    $number = 0L
    if (-not [long]::TryParse([string]$Value, [ref]$number) -or $number -le 0) {
        throw "$Name must be positive Unix milliseconds."
    }
    return $number
}
function Unavailable([string]$Reason) {
    return [ordered]@{ status = 'unavailable'; started_at_unix_ms = $null; completed_at_unix_ms = $null; duration_seconds = $null; reason = $Reason }
}
function Read-Interval($Value, [string]$Name) {
    if ($null -eq $Value) { return (Unavailable 'No measured interval was captured.') }
    if ($Value.status -eq 'unavailable') {
        if ([string]::IsNullOrWhiteSpace([string]$Value.reason)) { throw "$Name needs an unavailable reason." }
        return (Unavailable ([string]$Value.reason))
    }
    if ($Value.status -eq 'skipped') {
        if ($Name -ne 'pr_discussion' -or [string]::IsNullOrWhiteSpace([string]$Value.reason)) { throw "Only pr_discussion may be skipped, with a reason." }
        return [ordered]@{ status = 'skipped'; started_at_unix_ms = $null; completed_at_unix_ms = $null; duration_seconds = $null; reason = [string]$Value.reason }
    }
    if ($Value.status -and $Value.status -ne 'measured') { throw "$Name has an invalid timing status." }
    $start = Read-Milliseconds $Value.started_at_unix_ms "$Name.started_at_unix_ms"
    $end = Read-Milliseconds $Value.completed_at_unix_ms "$Name.completed_at_unix_ms"
    if ($end -lt $start -or $start -lt $runStart -or $end -gt $reportAt) { throw "$Name interval is outside the run or reversed." }
    return [ordered]@{ status = 'measured'; started_at_unix_ms = $start; completed_at_unix_ms = $end; duration_seconds = ($end - $start) / 1000.0 }
}
function Format-Duration($Seconds) {
    if ($null -eq $Seconds) { return 'unavailable' }
    $secondsRounded = [long][Math]::Round([double]$Seconds, 0, [MidpointRounding]::AwayFromZero)
    $hours = [long][Math]::Floor($secondsRounded / 3600)
    $minutes = [long][Math]::Floor(($secondsRounded % 3600) / 60)
    $secondsPart = $secondsRounded % 60
    if ($hours -gt 0) { return ('{0}h {1:00}m {2:00}s' -f $hours, $minutes, $secondsPart) }
    if ($minutes -gt 0) { return ('{0}m {1:00}s' -f $minutes, $secondsPart) }
    return "${secondsPart}s"
}
function Stage-Text($Stage) {
    if ($Stage.status -eq 'measured') { return (Format-Duration $Stage.duration_seconds) }
    return "$($Stage.status) ($($Stage.reason))"
}

$runStart = Read-Milliseconds $inputData.started_at_unix_ms 'started_at_unix_ms'
$reportAt = Read-Milliseconds $inputData.report_at_unix_ms 'report_at_unix_ms'
if ($reportAt -lt $runStart) { throw 'Report cutoff precedes run start.' }
$stages = [ordered]@{}
foreach ($name in @('preparation', 'claude_review', 'codex_review', 'pr_discussion', 'comparison', 'adjudication_reporting')) {
    $stages[$name] = Read-Interval $inputData.stages.$name $name
}
# The child stays read-only: it returns observed clock readings in its final report.
$reuse = Unavailable 'Comparison report has no unique Reuse timing record.'
$report = [string](Get-Content -LiteralPath $ComparisonReportPath -Raw)
# Models may render the record as a list item, bold text, or inline code.
$records = [regex]::Matches($report, '(?m)^[ \t>*_`-]*Reuse timing:[*_` \t]*([^\r\n]*?)[*_` \t]*\r?$')
if ($records.Count -eq 1) {
    try {
        $reuse = Read-Interval ($records[0].Groups[1].Value | ConvertFrom-Json) 'reuse_check'
        if ($reuse.status -ne 'measured') { throw 'Reuse timing did not contain a measured interval.' }
        $parent = $stages.comparison
        if ($parent.status -ne 'measured' -or $reuse.started_at_unix_ms -lt $parent.started_at_unix_ms -or
            $reuse.completed_at_unix_ms -gt $parent.completed_at_unix_ms) { throw 'Reuse interval is not contained in comparison.' }
    } catch {
        $reuse = Unavailable ('Invalid reuse timing: ' + $_.Exception.Message)
    }
}
$stages['reuse_check'] = $reuse

$independent = Unavailable 'Both independent review intervals are required.'
$overlap = $null
if ($stages.claude_review.status -eq 'measured' -and $stages.codex_review.status -eq 'measured') {
    $first = [Math]::Min($stages.claude_review.started_at_unix_ms, $stages.codex_review.started_at_unix_ms)
    $last = [Math]::Max($stages.claude_review.completed_at_unix_ms, $stages.codex_review.completed_at_unix_ms)
    $independent = Read-Interval ([pscustomobject]@{ started_at_unix_ms = $first; completed_at_unix_ms = $last }) 'independent_reviews'
    $overlap = [Math]::Max(0, [Math]::Min($stages.claude_review.completed_at_unix_ms, $stages.codex_review.completed_at_unix_ms) -
        [Math]::Max($stages.claude_review.started_at_unix_ms, $stages.codex_review.started_at_unix_ms)) / 1000.0
}
# These phases are serial; the two children above and reuse below are nested.
$phases = @($stages.preparation, $independent, $stages.pr_discussion, $stages.comparison, $stages.adjudication_reporting)
$previousEnd = $runStart
$phaseSeconds = 0.0
foreach ($phase in $phases) {
    if ($phase.status -ne 'measured') { continue }
    if ($phase.started_at_unix_ms -lt $previousEnd) { throw 'Serial stage intervals overlap or are out of order.' }
    $previousEnd = $phase.completed_at_unix_ms
    $phaseSeconds += $phase.duration_seconds
}
$total = ($reportAt - $runStart) / 1000.0
$other = $null
if (@($phases | Where-Object { $_.status -eq 'unavailable' }).Count -eq 0) { $other = [Math]::Round($total - $phaseSeconds, 3) }
$comparisonOther = $null
if ($reuse.status -eq 'measured') { $comparisonOther = $stages.comparison.duration_seconds - $reuse.duration_seconds }
$lines = @(
    "Total run time: $(Format-Duration $total)"
    "Preparation: $(Stage-Text $stages.preparation)"
    "Independent reviews (wall time): $(Stage-Text $independent)"
    "  Claude review: $(Stage-Text $stages.claude_review)"
    "  Codex review: $(Stage-Text $stages.codex_review)"
    "  Overlap: $(Format-Duration $overlap) (individual review times are not additive)"
    "PR discussion capture: $(Stage-Text $stages.pr_discussion)"
    "Comparison (includes reuse check): $(Stage-Text $stages.comparison)"
    "  Reuse check: $(Stage-Text $reuse)"
    "  Comparison excluding reuse check: $(Format-Duration $comparisonOther)"
    "Adjudication and report preparation: $(Stage-Text $stages.adjudication_reporting)"
    "Other orchestration: $(Format-Duration $other)"
)
$result = [ordered]@{
    schema_version = 1
    started_at_unix_ms = $runStart
    report_at_unix_ms = $reportAt
    total_seconds = $total
    stages = $stages
    independent_reviews = $independent
    independent_reviews_overlap_seconds = $overlap
    comparison_excluding_reuse_seconds = $comparisonOther
    other_seconds = $other
    report_text = $lines -join "`n"
}
$json = $result | ConvertTo-Json -Depth 8
[IO.File]::WriteAllText($OutputPath, $json, [Text.UTF8Encoding]::new($false))
$json
