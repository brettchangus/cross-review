[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LedgerPath,
    [Parameter(Mandatory)][string]$MetricsPath,
    [Parameter(Mandatory)][string]$RunContextPath,
    [Parameter(Mandatory)][string]$FinalReportPath,
    [Parameter(Mandatory)][string]$HistoryPath,
    [Parameter()][string]$GlobalHistoryPath
)

$ErrorActionPreference = 'Stop'
$maximumActiveReviewDurationSeconds = 14400

function Open-HistoryFile {
    param([Parameter(Mandatory)][string]$Path)

    $attempts = 5
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            return [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            if ($attempt -eq $attempts) {
                throw "History '$Path' remained locked after $attempts attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (200 * $attempt)
        }
    }
}

function Add-HistoryEntry {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$JsonLine,
        [Parameter(Mandatory)][string]$ReviewId
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $fullPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }

    $encoding = [System.Text.UTF8Encoding]::new($false)
    $file = Open-HistoryFile -Path $fullPath
    try {
        $reader = [System.IO.StreamReader]::new($file, $encoding, $true, 1024, $true)
        try { $existingContent = $reader.ReadToEnd() }
        finally { $reader.Dispose() }

        $lineNumber = 0
        foreach ($existingLine in ($existingContent -split '\r?\n')) {
            $lineNumber++
            if ([string]::IsNullOrWhiteSpace($existingLine)) { continue }
            try { $existing = $existingLine | ConvertFrom-Json }
            catch { throw "History '$fullPath' contains invalid JSON at line $lineNumber; nothing was appended." }
            if ([string]$existing.review_id -eq $ReviewId) { return $false }
        }

        if ($file.Length -gt 0) {
            $file.Seek(-1, [System.IO.SeekOrigin]::End) | Out-Null
            $lastByte = $file.ReadByte()
            $file.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
            if ($lastByte -ne 10) {
                $separator = $encoding.GetBytes([Environment]::NewLine)
                $file.Write($separator, 0, $separator.Length)
            }
        }
        $bytes = $encoding.GetBytes($JsonLine + [Environment]::NewLine)
        $file.Write($bytes, 0, $bytes.Length)
        $file.Flush($true)
        return $true
    } finally {
        $file.Dispose()
    }
}

foreach ($requiredPath in @($LedgerPath, $MetricsPath, $RunContextPath, $FinalReportPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required completed-review artifact not found: $requiredPath"
    }
}
if ((Get-Item -LiteralPath $FinalReportPath).Length -eq 0) {
    throw 'Final report is empty; history was not appended.'
}

$ledger = Get-Content -LiteralPath $LedgerPath -Raw | ConvertFrom-Json
$metrics = Get-Content -LiteralPath $MetricsPath -Raw | ConvertFrom-Json
$runContext = Get-Content -LiteralPath $RunContextPath -Raw | ConvertFrom-Json
if ([string]$ledger.status -ne 'complete') { throw "Ledger status must be 'complete'; history was not appended." }
if ([string]::IsNullOrWhiteSpace([string]$ledger.review_id)) { throw 'Ledger review_id is required.' }
$schemaVersion = [int]$ledger.schema_version
if ($schemaVersion -notin @(3, 4) -or [int]$metrics.schema_version -ne $schemaVersion) { throw 'Ledger and metrics schema_version values must match and be 3 or 4.' }
if ([string]$metrics.review_id -ne [string]$ledger.review_id) { throw 'Ledger and metrics review_id values do not match.' }
if ([string]$runContext.review_id -ne [string]$ledger.review_id) { throw 'Ledger and run-context review_id values do not match.' }
if ([int]$runContext.schema_version -ne $schemaVersion) { throw 'Run context schema_version must match the ledger.' }
if ($schemaVersion -eq 4) {
    $adjudicator = [string]$ledger.adjudication.adjudicator
    $comparisonProvider = [string]$ledger.adjudication.comparison_provider
    if ($adjudicator -notin @('claude', 'codex') -or $comparisonProvider -notin @('claude', 'codex') -or $adjudicator -eq $comparisonProvider -or
        [string]$runContext.tooling.orchestrator -ne $adjudicator -or
        [string]$runContext.tooling.comparison_provider -ne $comparisonProvider -or
        [string]$metrics.adjudication.adjudicator -ne $adjudicator -or
        [string]$metrics.adjudication.comparison_provider -ne $comparisonProvider) {
        throw 'Ledger, metrics, and run context disagree on adjudication roles.'
    }
}
if ([string]$metrics.review_mode -ne [string]$ledger.review_mode -or [string]$runContext.review_mode -ne [string]$ledger.review_mode) {
    throw 'Ledger, metrics, and run-context review_mode values do not match.'
}
if ([double]$runContext.review_size.review_units -le 0) { throw 'Run context review_size.review_units must be positive.' }
if (-not [bool]$runContext.review_size.has_changes) { throw 'Run context review_size.has_changes must be true for a completed review.' }
if ([double]$runContext.estimate.seconds -le 0) { throw 'Run context estimate.seconds must be positive.' }

foreach ($comparison in @(
    @('repository.id', [string]$ledger.repository.id, [string]$runContext.repository.id),
    @('repository.name', [string]$ledger.repository.name, [string]$runContext.repository.name),
    @('pull_request.source_ref', [string]$ledger.pull_request.source_ref, [string]$runContext.pull_request.source_ref),
    @('pull_request.target_ref', [string]$ledger.pull_request.target_ref, [string]$runContext.pull_request.target_ref),
    @('pull_request.source_commit', [string]$ledger.pull_request.source_commit, [string]$runContext.pull_request.source_commit),
    @('pull_request.target_commit', [string]$ledger.pull_request.target_commit, [string]$runContext.pull_request.target_commit),
    @('local.branch', [string]$ledger.local.branch, [string]$runContext.local.branch),
    @('local.head_commit', [string]$ledger.local.head_commit, [string]$runContext.local.head_commit)
)) {
    if ([string]::IsNullOrWhiteSpace($comparison[1]) -or -not [string]::Equals($comparison[1], $comparison[2], [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Ledger and run context disagree on $($comparison[0])."
    }
}
if (-not [string]::Equals([string]$ledger.repository.url, [string]$runContext.repository.url, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Ledger and run context disagree on repository.url.'
}

if ([string]$ledger.review_mode -eq 'pull_request') {
    if ([string]::IsNullOrWhiteSpace([string]$ledger.pull_request.id) -or [string]$ledger.pull_request.id -ne [string]$runContext.pull_request.id) {
        throw 'Ledger and run context disagree on pull_request.id.'
    }
} elseif (-not [string]::IsNullOrWhiteSpace([string]$ledger.pull_request.id) -or -not [string]::IsNullOrWhiteSpace([string]$runContext.pull_request.id)) {
    throw "Non-PR review histories must not contain a pull-request ID."
}

$startedAt = $null
$startedAtUnixMs = 0L
if ($null -ne $runContext.PSObject.Properties['started_at_unix_ms'] -and [int64]::TryParse([string]$runContext.started_at_unix_ms, [ref]$startedAtUnixMs) -and $startedAtUnixMs -gt 0) {
    $startedAt = [DateTimeOffset]::FromUnixTimeMilliseconds($startedAtUnixMs)
} else {
    if ([string]::IsNullOrWhiteSpace([string]$runContext.started_at)) { throw 'Run context start time is required.' }
    try {
        if ($runContext.started_at -is [DateTimeOffset]) {
            $startedAt = [DateTimeOffset]$runContext.started_at
        } elseif ($runContext.started_at -is [DateTime]) {
            $startedAt = [DateTimeOffset]([DateTime]$runContext.started_at)
        } else {
            $startedAt = [DateTimeOffset]::Parse([string]$runContext.started_at, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        }
        $startedAtUnixMs = $startedAt.ToUnixTimeMilliseconds()
    } catch {
        throw 'Run context started_at must be a valid ISO-8601 timestamp.'
    }
}

# Every completed review lives in a per-run folder, and its history entry must
# index that exact folder.
$declaredRunDirectory = $null
if ($null -ne $runContext.PSObject.Properties['run_directory'] -and -not [string]::IsNullOrWhiteSpace([string]$runContext.run_directory)) {
    $declaredRunDirectory = [string]$runContext.run_directory
}
$finalReportDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($FinalReportPath))
$runsDirectory = Split-Path -Parent $finalReportDirectory
$reviewsDirectory = Split-Path -Parent $runsDirectory
$usesRunFolder = -not [string]::IsNullOrWhiteSpace($reviewsDirectory) -and
    [string]::Equals((Split-Path -Leaf $runsDirectory), 'runs', [System.StringComparison]::OrdinalIgnoreCase) -and
    [string]::Equals((Split-Path -Leaf $reviewsDirectory), '.reviews', [System.StringComparison]::OrdinalIgnoreCase)

if (-not $usesRunFolder) {
    throw "Final report must be stored under a .reviews/runs/<run-name> folder: '$FinalReportPath'."
}
foreach ($artifactPath in @($LedgerPath, $MetricsPath, $RunContextPath)) {
    $artifactDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($artifactPath))
    if (-not [string]::Equals($artifactDirectory, $finalReportDirectory, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Ledger, metrics, and run context must be in the same run folder as the final report '$finalReportDirectory': '$artifactPath'."
    }
}
$expectedRunDirectory = ".reviews/runs/$(Split-Path -Leaf $finalReportDirectory)"
if ([string]::IsNullOrWhiteSpace($declaredRunDirectory)) {
    throw "Run context run_directory is required and must equal '$expectedRunDirectory'."
}
if (-not [string]::Equals($declaredRunDirectory, $expectedRunDirectory, [System.StringComparison]::Ordinal)) {
    throw "Run context run_directory '$declaredRunDirectory' does not match the completed report directory '$expectedRunDirectory'."
}
$runDirectory = $expectedRunDirectory

$completedAt = [DateTimeOffset]::UtcNow
$completedAtText = $completedAt.ToString('o')
$durationSeconds = [Math]::Round(($completedAt - $startedAt).TotalSeconds, 3)
if ($durationSeconds -lt 0) { throw 'Run context start time is in the future; history was not appended.' }
$plausibilityCeiling = $maximumActiveReviewDurationSeconds
$estimationEligible = $durationSeconds -le $plausibilityCeiling
$exclusionReason = if ($estimationEligible) { $null } else { 'duration_exceeded_plausibility_ceiling' }

$entry = [ordered]@{
    schema_version = $schemaVersion
    review_id = [string]$ledger.review_id
    review_mode = [string]$ledger.review_mode
    completed_at = $completedAtText
    run_directory = $runDirectory
    repository = $ledger.repository
    pull_request = $ledger.pull_request
    local = $ledger.local
    tooling = $runContext.tooling
    review_size = $runContext.review_size
    estimate = $runContext.estimate
    timing = [ordered]@{
        started_at = $startedAt.ToUniversalTime().ToString('o')
        started_at_unix_ms = $startedAtUnixMs
        completed_at = $completedAtText
        completed_at_unix_ms = $completedAt.ToUnixTimeMilliseconds()
        duration_seconds = $durationSeconds
        estimation_eligible = $estimationEligible
        exclusion_reason = $exclusionReason
        plausibility_ceiling_seconds = $plausibilityCeiling
    }
    initial = $metrics.initial
    final = $metrics.final
    resolution = $metrics.resolution
    metrics = $metrics.metrics
}
$line = $entry | ConvertTo-Json -Depth 12 -Compress

$localAppended = Add-HistoryEntry -Path $HistoryPath -JsonLine $line -ReviewId ([string]$ledger.review_id)
$globalAppended = $null
if (-not [string]::IsNullOrWhiteSpace($GlobalHistoryPath)) {
    $localFullPath = [System.IO.Path]::GetFullPath($HistoryPath)
    $globalFullPath = [System.IO.Path]::GetFullPath($GlobalHistoryPath)
    if (-not [string]::Equals($localFullPath, $globalFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        try {
            $globalAppended = Add-HistoryEntry -Path $GlobalHistoryPath -JsonLine $line -ReviewId ([string]$ledger.review_id)
        } catch {
            $localState = if ($localAppended) { 'was appended' } else { 'was already present' }
            throw "Local history $localState, but the global history append failed: $($_.Exception.Message) Re-running this same command is safe and will complete the missing append without duplicating the local entry."
        }
    }
}

if ($localAppended) { Write-Output "Appended review '$($ledger.review_id)' to '$([System.IO.Path]::GetFullPath($HistoryPath))'." }
else { Write-Output "Review '$($ledger.review_id)' is already present in local history; no duplicate was appended." }
if ($null -ne $globalAppended) {
    if ($globalAppended) { Write-Output "Appended review '$($ledger.review_id)' to '$([System.IO.Path]::GetFullPath($GlobalHistoryPath))'." }
    else { Write-Output "Review '$($ledger.review_id)' is already present in global history; no duplicate was appended." }
}
if (-not $estimationEligible) {
    Write-Warning "The completed review was recorded but excluded from future estimates because $durationSeconds seconds exceeded the $plausibilityCeiling-second plausibility ceiling."
}
