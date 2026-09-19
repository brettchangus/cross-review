[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$BaseRef,

    [Parameter()]
    [string]$HeadRef = 'HEAD',

    [Parameter()]
    [ValidateSet('pull_request', 'uncommitted', 'branch')]
    [string]$ReviewMode = 'pull_request',

    [Parameter()]
    [string]$HistoryPath = '.reviews/history.jsonl',

    [Parameter()]
    [string]$GlobalHistoryPath,

    [Parameter()]
    [string]$RepositoryId,

    [Parameter()]
    [string]$RepositoryName,

    [Parameter()]
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$maximumHistoricalDurationSeconds = 14400
$maximumLogSizeDistance = 2.0
$binaryProbeByteCount = 8192
$maximumExactUntrackedBytes = 5MB
$assumedBytesPerLine = 80

function Get-Median {
    param([double[]]$Values)
    if ($Values.Count -eq 0) { return $null }
    $sorted = @($Values | Sort-Object)
    $middle = [int][Math]::Floor($sorted.Count / 2)
    if (($sorted.Count % 2) -eq 1) { return [double]$sorted[$middle] }
    return ([double]$sorted[$middle - 1] + [double]$sorted[$middle]) / 2.0
}

function Invoke-GitText {
    param([string[]]$Arguments, [string]$FailureMessage)
    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage $($output -join [Environment]::NewLine)"
    }
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    return (($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Resolve-RepositoryPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$RepositoryRoot)

    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $RepositoryRoot $Path))
}

function Measure-UntrackedFile {
    param([Parameter(Mandatory)][string]$Path)

    $fileInfo = Get-Item -LiteralPath $Path
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $probeLength = [int][Math]::Min([int64]$binaryProbeByteCount, $fileInfo.Length)
        $probe = [byte[]]::new($probeLength)
        $probeRead = 0
        while ($probeRead -lt $probeLength) {
            $read = $stream.Read($probe, $probeRead, $probeLength - $probeRead)
            if ($read -eq 0) { break }
            $probeRead += $read
        }
        for ($index = 0; $index -lt $probeRead; $index++) {
            if ($probe[$index] -eq 0) {
                return [pscustomobject]@{ binary = $true; oversized = $false; line_count = 0 }
            }
        }

        if ($fileInfo.Length -gt $maximumExactUntrackedBytes) {
            return [pscustomobject]@{
                binary = $false
                oversized = $true
                line_count = [int64][Math]::Max(1, [Math]::Ceiling($fileInfo.Length / [double]$assumedBytesPerLine))
            }
        }

        $stream.Seek(0, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buffer = [byte[]]::new(65536)
        $lineCount = 0L
        $lastByte = -1
        while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            for ($index = 0; $index -lt $bytesRead; $index++) {
                if ($buffer[$index] -eq 10) { $lineCount++ }
                $lastByte = $buffer[$index]
            }
        }
        if ($fileInfo.Length -gt 0 -and $lastByte -ne 10) { $lineCount++ }
        return [pscustomobject]@{ binary = $false; oversized = $false; line_count = $lineCount }
    } finally {
        $stream.Dispose()
    }
}

if ($ReviewMode -eq 'uncommitted' -and $PSBoundParameters.ContainsKey('HeadRef') -and
    -not [string]::Equals($HeadRef, 'HEAD', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Uncommitted reviews always use HEAD; HeadRef '$HeadRef' is not allowed."
}

$repositoryRoot = Invoke-GitText @('rev-parse', '--show-toplevel') 'Cannot resolve the repository root.'
$effectiveHeadRef = if ($ReviewMode -eq 'uncommitted') { 'HEAD' } else { $HeadRef }
$headCommit = Invoke-GitText @('-C', $repositoryRoot, 'rev-parse', '--verify', "$effectiveHeadRef^{commit}") "Cannot resolve review source '$effectiveHeadRef'."
$baseCommit = if ($ReviewMode -eq 'uncommitted') {
    $headCommit
} else {
    Invoke-GitText @('-C', $repositoryRoot, 'rev-parse', '--verify', "$BaseRef^{commit}") "Cannot resolve review base '$BaseRef'."
}

$diffArguments = if ($ReviewMode -eq 'uncommitted') {
    @('-C', $repositoryRoot, 'diff', '--numstat', 'HEAD', '--', '.', ':(exclude).reviews/**')
} else {
    @('-C', $repositoryRoot, 'diff', '--numstat', "$baseCommit...$headCommit", '--', '.', ':(exclude).reviews/**')
}
$numstatOutput = @(& git @diffArguments 2>&1)
if ($LASTEXITCODE -ne 0) {
    throw "Cannot measure the $ReviewMode diff against '$BaseRef': $($numstatOutput -join [Environment]::NewLine)"
}
$numstat = @($numstatOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })

$changedFiles = 0
$linesAdded = 0
$linesDeleted = 0
$binaryFiles = 0
$oversizedUntrackedFiles = 0
foreach ($line in $numstat) {
    if ([string]::IsNullOrWhiteSpace([string]$line)) { continue }
    $parts = ([string]$line) -split "`t", 3
    if ($parts.Count -lt 3) { throw "Unexpected git numstat output: $line" }
    $changedFiles++
    if ($parts[0] -eq '-' -or $parts[1] -eq '-') {
        $binaryFiles++
        continue
    }
    $linesAdded += [int64]$parts[0]
    $linesDeleted += [int64]$parts[1]
}

if ($ReviewMode -eq 'uncommitted') {
    $untrackedOutput = @(& git -C $repositoryRoot -c core.quotepath=false ls-files --full-name --others --exclude-standard -- '.' ':(exclude).reviews/**' 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot enumerate untracked files: $($untrackedOutput -join [Environment]::NewLine)"
    }
    $untrackedPaths = @($untrackedOutput | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] } | ForEach-Object { [string]$_ })
    foreach ($untrackedPath in $untrackedPaths) {
        if ([string]::IsNullOrWhiteSpace($untrackedPath)) { continue }
        $fullUntrackedPath = Join-Path $repositoryRoot $untrackedPath
        if (-not (Test-Path -LiteralPath $fullUntrackedPath -PathType Leaf)) { continue }
        $measurement = Measure-UntrackedFile -Path $fullUntrackedPath
        $changedFiles++
        if ($measurement.binary) {
            $binaryFiles++
            continue
        }
        if ($measurement.oversized) { $oversizedUntrackedFiles++ }
        $linesAdded += [int64]$measurement.line_count
    }
}

$commitCount = 0
if ($ReviewMode -ne 'uncommitted') {
    $commitText = Invoke-GitText @('-C', $repositoryRoot, 'rev-list', '--count', "$baseCommit..$headCommit") "Cannot count commits between '$BaseRef' and '$effectiveHeadRef'."
    if (-not [int]::TryParse($commitText, [ref]$commitCount) -or $commitCount -lt 0) {
        throw "Git returned an invalid commit count: '$commitText'."
    }
}
$linesChanged = $linesAdded + $linesDeleted
$reviewUnits = [Math]::Max(1, $linesChanged + (25 * $changedFiles) + (15 * $commitCount) + (100 * $binaryFiles))
$sizeBand = if ($reviewUnits -le 300) { 'small' } elseif ($reviewUnits -le 1200) { 'medium' } elseif ($reviewUnits -le 4000) { 'large' } else { 'very_large' }

switch ($sizeBand) {
    'small' { $bootstrapSeconds = 240; $bootstrapLow = 120; $bootstrapHigh = 420 }
    'medium' { $bootstrapSeconds = 360; $bootstrapLow = 180; $bootstrapHigh = 600 }
    'large' { $bootstrapSeconds = 480; $bootstrapLow = 300; $bootstrapHigh = 780 }
    default { $bootstrapSeconds = 600; $bootstrapLow = 360; $bootstrapHigh = 1080 }
}

$historyFiles = @()
foreach ($candidatePath in @($HistoryPath, $GlobalHistoryPath)) {
    if ([string]::IsNullOrWhiteSpace($candidatePath)) { continue }
    $fullCandidate = Resolve-RepositoryPath -Path $candidatePath -RepositoryRoot $repositoryRoot
    if ($historyFiles -notcontains $fullCandidate) { $historyFiles += $fullCandidate }
}

$historicalById = @{}
foreach ($historyFile in $historyFiles) {
    if (-not (Test-Path -LiteralPath $historyFile -PathType Leaf)) { continue }
    $lineNumber = 0
    foreach ($historyLine in [System.IO.File]::ReadLines($historyFile)) {
        $lineNumber++
        if ([string]::IsNullOrWhiteSpace($historyLine)) { continue }
        try { $entry = $historyLine | ConvertFrom-Json }
        catch {
            Write-Warning "Ignoring invalid history JSON at '$historyFile' line $lineNumber."
            continue
        }
        $reviewId = [string]$entry.review_id
        if ([string]::IsNullOrWhiteSpace($reviewId)) { $reviewId = "$historyFile`:$lineNumber" }
        if ($historicalById.ContainsKey($reviewId)) { continue }

        $historicalUnits = [double]$entry.review_size.review_units
        $durationSeconds = [double]$entry.timing.duration_seconds
        if ($historicalUnits -le 0 -or $durationSeconds -le 0) { continue }
        $historicalMode = if ($null -ne $entry.PSObject.Properties['review_mode'] -and -not [string]::IsNullOrWhiteSpace([string]$entry.review_mode)) {
            [string]$entry.review_mode
        } else {
            'pull_request'
        }
        if (-not [string]::Equals($historicalMode, $ReviewMode, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
        $eligibilityProperty = if ($null -ne $entry.timing) { $entry.timing.PSObject.Properties['estimation_eligible'] } else { $null }
        if ($null -ne $eligibilityProperty -and -not [bool]$eligibilityProperty.Value) { continue }
        if ($null -eq $eligibilityProperty -and $durationSeconds -gt $maximumHistoricalDurationSeconds) { continue }

        $sameRepository = $false
        if (-not [string]::IsNullOrWhiteSpace($RepositoryId) -and [string]$entry.repository.id -eq $RepositoryId) {
            $sameRepository = $true
        } elseif (-not [string]::IsNullOrWhiteSpace($RepositoryName) -and [string]$entry.repository.name -ieq $RepositoryName) {
            $sameRepository = $true
        }
        $distance = [Math]::Abs([Math]::Log(($reviewUnits + 1.0) / ($historicalUnits + 1.0)))
        $historicalById[$reviewId] = [pscustomobject]@{
            units = $historicalUnits
            duration_seconds = $durationSeconds
            distance = $distance
            same_repository = $sameRepository
        }
    }
}

$historical = @($historicalById.Values)
$comparableHistory = @($historical | Where-Object { $_.distance -le $maximumLogSizeDistance })
$sameRepositoryHistory = @($comparableHistory | Where-Object { $_.same_repository } | Sort-Object distance)
$crossRepositoryHistory = @($comparableHistory | Where-Object { -not $_.same_repository } | Sort-Object distance)
$nearest = @($sameRepositoryHistory | Select-Object -First 7)
if ($nearest.Count -lt 7) {
    $nearest += @($crossRepositoryHistory | Select-Object -First (7 - $nearest.Count))
}

$eligibleCount = $historical.Count
$availableCount = $comparableHistory.Count
$sameRepositoryAvailable = $sameRepositoryHistory.Count
if ($nearest.Count -eq 0) {
    $estimateSeconds = $bootstrapSeconds
    $lowSeconds = $bootstrapLow
    $highSeconds = $bootstrapHigh
    $method = 'bootstrap_heuristic'
    $usedCount = 0
    $sameRepositoryUsed = 0
    $historyWeight = 0.0
    $confidence = 'low'
} else {
    $scaled = @($nearest | ForEach-Object {
        [double]$_.duration_seconds * [Math]::Pow(($reviewUnits / [double]$_.units), 0.35)
    })
    $historicalEstimate = Get-Median $scaled
    $usedCount = $nearest.Count
    $sameRepositoryUsed = @($nearest | Where-Object { $_.same_repository }).Count
    $historyWeight = 0.8 * [Math]::Min(1.0, $usedCount / 7.0)
    $estimateSeconds = [Math]::Round(($bootstrapSeconds * (1.0 - $historyWeight)) + ($historicalEstimate * $historyWeight))
    $sortedScaled = @($scaled | Sort-Object)
    if ($scaled.Count -ge 4) {
        $lowIndex = [int][Math]::Floor(($scaled.Count - 1) * 0.25)
        $highIndex = [int][Math]::Ceiling(($scaled.Count - 1) * 0.75)
        $historicalLow = [double]$sortedScaled[$lowIndex] * 0.85
        $historicalHigh = [double]$sortedScaled[$highIndex] * 1.15
    } else {
        $historicalLow = [double]$historicalEstimate * 0.65
        $historicalHigh = [double]$historicalEstimate * 1.6
    }
    $lowSeconds = [Math]::Round(($bootstrapLow * (1.0 - $historyWeight)) + ($historicalLow * $historyWeight))
    $highSeconds = [Math]::Round(($bootstrapHigh * (1.0 - $historyWeight)) + ($historicalHigh * $historyWeight))
    $lowSeconds = [Math]::Max(60, [Math]::Min($estimateSeconds, $lowSeconds))
    $highSeconds = [Math]::Max($estimateSeconds, $highSeconds)
    $method = 'hybrid_history_blended_nearest_scaled'
    $confidence = if ($usedCount -ge 7 -and $sameRepositoryUsed -ge 3) {
        'high'
    } elseif (($usedCount -ge 4 -and $sameRepositoryUsed -ge 1) -or $usedCount -ge 7) {
        'medium'
    } else {
        'low'
    }
}

$result = [ordered]@{
    schema_version = 3
    review_mode = $ReviewMode
    measured_at = [DateTime]::UtcNow.ToString('o')
    base_ref = $BaseRef
    head_ref = $effectiveHeadRef
    base_commit = $baseCommit
    head_commit = $headCommit
    review_size = [ordered]@{
        changed_files = $changedFiles
        lines_added = $linesAdded
        lines_deleted = $linesDeleted
        lines_changed = $linesChanged
        binary_files = $binaryFiles
        oversized_untracked_files = $oversizedUntrackedFiles
        commit_count = $commitCount
        has_changes = ($changedFiles -gt 0)
        review_units = $reviewUnits
        size_band = $sizeBand
    }
    estimate = [ordered]@{
        seconds = [int64]$estimateSeconds
        low_seconds = [int64]$lowSeconds
        high_seconds = [int64]$highSeconds
        method = $method
        bootstrap_seconds = $bootstrapSeconds
        history_weight = [Math]::Round($historyWeight, 4)
        historical_runs_used = $usedCount
        historical_runs_available = $availableCount
        historical_runs_eligible = $eligibleCount
        same_repository_runs_used = $sameRepositoryUsed
        same_repository_runs_available = $sameRepositoryAvailable
        confidence = $confidence
    }
}

$json = $result | ConvertTo-Json -Depth 10
if ($PSBoundParameters.ContainsKey('OutputPath')) {
    $resolvedOutputPath = Resolve-RepositoryPath -Path $OutputPath -RepositoryRoot $repositoryRoot
    $parent = Split-Path -Parent $resolvedOutputPath
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    [System.IO.File]::WriteAllText($resolvedOutputPath, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}
$json
