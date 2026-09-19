[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$LedgerPath,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$validSeverities = @('high', 'medium', 'low')
$validDispositions = @('confirmed', 'rejected', 'uncertain')
$validReviewModes = @('pull_request', 'uncommitted', 'branch')

function Assert-Text {
    param($Value, [string]$Name)
    if ([string]::IsNullOrWhiteSpace([string]$Value)) {
        throw "Missing required value: $Name"
    }
}

function Get-RequiredArray {
    param($Object, [string]$PropertyName)
    $property = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $property) { throw "Missing required array: $PropertyName" }
    if ($null -eq $property.Value -or -not ($property.Value -is [System.Array])) {
        throw "Property '$PropertyName' must be a JSON array; use [] when it is empty."
    }
    return @($property.Value)
}

function New-SeverityCounts {
    param([object[]]$Items, [string]$PropertyName)
    $counts = [ordered]@{ high = 0; medium = 0; low = 0; total = 0 }
    foreach ($item in $Items) {
        $severity = ([string]$item.$PropertyName).ToLowerInvariant()
        if ($severity -notin $validSeverities) { throw "Invalid severity '$severity'." }
        $counts[$severity]++
        $counts.total++
    }
    return $counts
}

function Divide-OrNull {
    param([double]$Numerator, [double]$Denominator)
    if ($Denominator -eq 0) { return $null }
    return ($Numerator / $Denominator)
}

if (-not (Test-Path -LiteralPath $LedgerPath -PathType Leaf)) { throw "Ledger not found: $LedgerPath" }
$ledger = Get-Content -LiteralPath $LedgerPath -Raw | ConvertFrom-Json

$schemaVersion = [int]$ledger.schema_version
if ($schemaVersion -notin @(3, 4)) { throw 'Ledger schema_version must be 3 or 4.' }
Assert-Text $ledger.review_id 'review_id'
if ([string]$ledger.status -ne 'complete') { throw "Ledger status must be 'complete'." }
$reviewMode = ([string]$ledger.review_mode).ToLowerInvariant()
if ($reviewMode -notin $validReviewModes) { throw "Ledger review_mode must be pull_request, uncommitted, or branch." }
Assert-Text $ledger.repository.id 'repository.id'
Assert-Text $ledger.repository.name 'repository.name'
if ($reviewMode -eq 'pull_request') {
    Assert-Text $ledger.repository.url 'repository.url'
    if ([string]::IsNullOrWhiteSpace([string]$ledger.repository.project_id) -and [string]::IsNullOrWhiteSpace([string]$ledger.repository.project_name)) {
        throw 'At least one of repository.project_id or repository.project_name is required.'
    }
}
Assert-Text $ledger.pull_request.source_ref 'pull_request.source_ref'
Assert-Text $ledger.pull_request.target_ref 'pull_request.target_ref'
Assert-Text $ledger.pull_request.source_commit 'pull_request.source_commit'
Assert-Text $ledger.pull_request.target_commit 'pull_request.target_commit'
Assert-Text $ledger.local.branch 'local.branch'
Assert-Text $ledger.local.head_commit 'local.head_commit'

$pullRequestId = [string]$ledger.pull_request.id
$expectedSource = "refs/heads/$($ledger.local.branch)"
if ($reviewMode -eq 'pull_request') {
    Assert-Text $pullRequestId 'pull_request.id'
    $parsedPullRequestId = 0
    if (-not [int]::TryParse($pullRequestId, [ref]$parsedPullRequestId) -or $parsedPullRequestId -le 0) { throw 'pull_request.id must be a positive integer.' }
} elseif (-not [string]::IsNullOrWhiteSpace($pullRequestId)) {
    throw "pull_request.id must be null or empty for review_mode '$reviewMode'."
}

if ($reviewMode -eq 'uncommitted') {
    if ([string]$ledger.pull_request.source_ref -ne 'WORKTREE' -or [string]$ledger.pull_request.target_ref -ne 'HEAD') {
        throw "Uncommitted review scope must use source_ref 'WORKTREE' and target_ref 'HEAD'."
    }
} elseif (-not [string]::Equals([string]$ledger.pull_request.source_ref, $expectedSource, [System.StringComparison]::Ordinal)) {
    throw "Branch guard failed in ledger: source_ref '$($ledger.pull_request.source_ref)' does not equal '$expectedSource'."
}
if ($reviewMode -eq 'branch' -and [string]$ledger.pull_request.target_ref -notmatch '^(?:refs/heads/|refs/remotes/origin/|origin/)?(?:main|master)$') {
    throw "Branch review target_ref must identify main or master."
}

if ($reviewMode -ne 'pull_request' -and -not [string]::Equals([string]$ledger.pull_request.source_commit, [string]$ledger.local.head_commit, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Review source commit must equal local.head_commit.'
}
if ($reviewMode -eq 'uncommitted' -and -not [string]::Equals([string]$ledger.pull_request.target_commit, [string]$ledger.local.head_commit, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'Uncommitted review target commit must equal local.head_commit.'
}

$findings = Get-RequiredArray $ledger 'findings'
$groups = Get-RequiredArray $ledger 'groups'
$findingById = @{}
foreach ($finding in $findings) {
    if ($null -eq $finding) { throw 'findings must not contain null entries.' }
    $id = [string]$finding.id
    if ($id -notmatch '^(C|X)-\d{3,}$') { throw "Invalid finding ID '$id'." }
    if ($findingById.ContainsKey($id)) { throw "Duplicate finding ID '$id'." }
    $reviewer = ([string]$finding.reviewer).ToLowerInvariant()
    $expectedReviewer = if ($id.StartsWith('C-')) { 'claude' } else { 'codex' }
    if ($reviewer -ne $expectedReviewer) { throw "Finding '$id' has reviewer '$reviewer'; expected '$expectedReviewer'." }
    $severity = ([string]$finding.severity).ToLowerInvariant()
    if ($severity -notin $validSeverities) { throw "Finding '$id' has invalid severity '$severity'." }
    $findingById[$id] = $finding
}

$seenSourceIds = @{}
$groupById = @{}
$confirmedSourceIds = @{}
$confirmedGroups = @()
$rejectedCount = 0
$uncertainCount = 0
foreach ($group in $groups) {
    if ($null -eq $group) { throw 'groups must not contain null entries.' }
    Assert-Text $group.id 'groups[].id'
    $groupId = [string]$group.id
    if ($groupById.ContainsKey($groupId)) { throw "Duplicate group ID '$groupId'." }
    $groupById[$groupId] = $group
    $sourceIds = Get-RequiredArray $group 'source_ids'
    if ($sourceIds.Count -eq 0) { throw "Group '$groupId' has no source_ids." }
    foreach ($sourceIdValue in $sourceIds) {
        $sourceId = [string]$sourceIdValue
        if (-not $findingById.ContainsKey($sourceId)) { throw "Group '$groupId' references unknown finding '$sourceId'." }
        if ($seenSourceIds.ContainsKey($sourceId)) { throw "Finding '$sourceId' appears in more than one group." }
        $seenSourceIds[$sourceId] = $true
    }
    $disposition = ([string]$group.disposition).ToLowerInvariant()
    if ($disposition -notin $validDispositions) { throw "Group '$groupId' has invalid disposition '$disposition'." }
    if ($disposition -eq 'confirmed') {
        $finalSeverity = ([string]$group.final_severity).ToLowerInvariant()
        if ($finalSeverity -notin $validSeverities) { throw "Confirmed group '$groupId' requires a valid final_severity." }
        foreach ($sourceIdValue in $sourceIds) { $confirmedSourceIds[[string]$sourceIdValue] = $true }
        $confirmedGroups += $group
    } else {
        if (-not [string]::IsNullOrWhiteSpace([string]$group.final_severity)) {
            throw "Non-confirmed group '$groupId' must not have final_severity."
        }
        if ($disposition -eq 'rejected') { $rejectedCount++ } else { $uncertainCount++ }
    }
}

foreach ($findingId in $findingById.Keys) {
    if (-not $seenSourceIds.ContainsKey($findingId)) { throw "Finding '$findingId' does not appear in any group." }
}

$adjudicationProperty = $ledger.PSObject.Properties['adjudication']
if ($null -eq $adjudicationProperty -or $null -eq $adjudicationProperty.Value) { throw 'Missing required object: adjudication' }
$overrideField = 'codex_disposition_overrides'
$proposalField = 'codex_disposition'
if ($schemaVersion -eq 4) {
    $adjudicator = [string]$ledger.adjudication.adjudicator
    $comparisonProvider = [string]$ledger.adjudication.comparison_provider
    if ($adjudicator -notin @('claude', 'codex') -or $comparisonProvider -notin @('claude', 'codex') -or $adjudicator -eq $comparisonProvider) {
        throw 'Version 4 requires distinct claude/codex adjudicator and comparison_provider values.'
    }
    if ($null -ne $ledger.adjudication.PSObject.Properties['codex_disposition_overrides']) {
        throw 'Version 4 uses comparison_disposition_overrides, not codex_disposition_overrides.'
    }
    $overrideField = 'comparison_disposition_overrides'
    $proposalField = 'comparison_disposition'
}
$overrides = @(Get-RequiredArray $ledger.adjudication $overrideField)
$seenOverrideGroups = @{}
foreach ($override in $overrides) {
    Assert-Text $override.group_id "adjudication.$overrideField[].group_id"
    Assert-Text $override.reason "adjudication.$overrideField[].reason"
    $groupId = [string]$override.group_id
    if (-not $groupById.ContainsKey($groupId)) { throw "Adjudication override references unknown group '$groupId'." }
    if ($seenOverrideGroups.ContainsKey($groupId)) { throw "Group '$groupId' has more than one adjudication override." }
    $seenOverrideGroups[$groupId] = $true
    $comparisonDisposition = ([string]$override.$proposalField).ToLowerInvariant()
    $finalDisposition = ([string]$override.final_disposition).ToLowerInvariant()
    if ($comparisonDisposition -notin $validDispositions -or $finalDisposition -notin $validDispositions) {
        throw "Adjudication override for '$groupId' has an invalid disposition."
    }
    if ($comparisonDisposition -eq $finalDisposition) { throw "Adjudication override for '$groupId' does not change the disposition." }
    if (([string]$groupById[$groupId].disposition).ToLowerInvariant() -ne $finalDisposition) {
        throw "Adjudication override for '$groupId' does not match the group's final disposition."
    }
}

$claudeFindings = @($findings | Where-Object { $_.reviewer -eq 'claude' })
$codexFindings = @($findings | Where-Object { $_.reviewer -eq 'codex' })
$initialClaude = New-SeverityCounts $claudeFindings 'severity'
$initialCodex = New-SeverityCounts $codexFindings 'severity'
$finalCounts = New-SeverityCounts $confirmedGroups 'final_severity'

$agreement = 0
$claudeOnly = 0
$codexOnly = 0
foreach ($group in $confirmedGroups) {
    $ids = @($group.source_ids | ForEach-Object { [string]$_ })
    $hasClaude = @($ids | Where-Object { $_.StartsWith('C-') }).Count -gt 0
    $hasCodex = @($ids | Where-Object { $_.StartsWith('X-') }).Count -gt 0
    if ($hasClaude -and $hasCodex) { $agreement++ }
    elseif ($hasClaude) { $claudeOnly++ }
    elseif ($hasCodex) { $codexOnly++ }
    else { throw "Confirmed group '$($group.id)' has no recognized provenance IDs." }
}

$confirmedClaudeIds = @($claudeFindings | Where-Object { $confirmedSourceIds.ContainsKey([string]$_.id) }).Count
$confirmedCodexIds = @($codexFindings | Where-Object { $confirmedSourceIds.ContainsKey([string]$_.id) }).Count
$initialUnique = $groups.Count
$mergedDuplicates = $findings.Count - $initialUnique
if ($mergedDuplicates -lt 0) { throw 'Issue-group count exceeds raw finding count.' }
if ($initialUnique -ne ($agreement + $claudeOnly + $codexOnly + $rejectedCount + $uncertainCount)) { throw 'Resolution accounting invariant failed.' }
if ($finalCounts.total -ne ($agreement + $claudeOnly + $codexOnly)) { throw 'Final finding accounting invariant failed.' }

$metrics = [ordered]@{
    schema_version = $schemaVersion
    review_id = [string]$ledger.review_id
    review_mode = $reviewMode
    initial = [ordered]@{ claude = $initialClaude; codex = $initialCodex }
    final = $finalCounts
    resolution = [ordered]@{
        agreement = $agreement
        claude_only_confirmed = $claudeOnly
        codex_only_confirmed = $codexOnly
        rejected_false_positives = $rejectedCount
        merged_duplicates = $mergedDuplicates
        uncertain_findings = $uncertainCount
        initial_unique_findings = $initialUnique
        adjudicator_overrides = $overrides.Count
    }
    metrics = [ordered]@{
        claude_precision = Divide-OrNull $confirmedClaudeIds $initialClaude.total
        codex_precision = Divide-OrNull $confirmedCodexIds $initialCodex.total
        codex_added_value = Divide-OrNull $codexOnly $finalCounts.total
        cross_review_reduction = if ($initialUnique -eq 0) { $null } else { 1.0 - ($finalCounts.total / [double]$initialUnique) }
    }
}

if ($schemaVersion -eq 4) {
    $metrics.adjudication = [ordered]@{ adjudicator = $adjudicator; comparison_provider = $comparisonProvider }
    $metrics.metrics.claude_added_value = Divide-OrNull $claudeOnly $finalCounts.total
}

$parent = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
$json = $metrics | ConvertTo-Json -Depth 12
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($OutputPath), $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
$json
