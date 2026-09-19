[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepositoryPath = '.',

    [Parameter(Mandatory)]
    [ValidateSet('claude-led', 'codex-led')]
    [string]$Variant,

    [Parameter(Mandatory)]
    [ValidateSet('pull_request', 'uncommitted', 'branch')]
    [string]$ReviewMode,

    [Parameter()]
    [int]$PullRequestId,

    # The local branch. Required for uncommitted and branch mode.
    [Parameter()]
    [string]$BranchName,

    [Parameter(Mandatory)]
    [string]$ReviewId,

    # The approved run start, as an ISO 8601 timestamp.
    [Parameter(Mandatory)]
    [string]$StartedAt
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$maximumSlugLength = 48

function Test-IsLinkOrReparsePoint {
    param([Parameter(Mandatory)]$Item)

    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    $linkType = $Item.PSObject.Properties['LinkType']
    return $null -ne $linkType -and -not [string]::IsNullOrWhiteSpace([string]$linkType.Value)
}

function Assert-CreatedDirectory {
    param([Parameter(Mandatory)][string]$Path)

    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer -or (Test-IsLinkOrReparsePoint $item)) {
        throw "Review storage must be a regular directory: '$Path'."
    }
}

# Branch names are untrusted. Reduce one to a single safe path segment.
function ConvertTo-Slug {
    param([string]$Value)

    $slug = [regex]::Replace([string]$Value, '[^A-Za-z0-9._-]', '-')
    $slug = [regex]::Replace($slug, '-{2,}', '-').Trim('-', '.')
    if ($slug.Length -gt $maximumSlugLength) {
        $slug = $slug.Substring(0, $maximumSlugLength).TrimEnd('-', '.')
    }
    if ([string]::IsNullOrEmpty($slug)) { return 'unnamed' }
    return $slug
}

$parsedReviewId = [Guid]::Empty
if (-not [Guid]::TryParse($ReviewId, [ref]$parsedReviewId)) {
    throw "ReviewId must be a UUID: '$ReviewId'."
}
$parsedStartedAt = [DateTimeOffset]::MinValue
if (-not [DateTimeOffset]::TryParse($StartedAt, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AssumeUniversal, [ref]$parsedStartedAt)) {
    throw "StartedAt must be an ISO 8601 timestamp: '$StartedAt'."
}

$scope = switch ($ReviewMode) {
    'pull_request' {
        if ($PullRequestId -le 0) { throw 'PullRequestId must be a positive integer in pull_request mode.' }
        "pr-$PullRequestId"
    }
    default {
        if ([string]::IsNullOrWhiteSpace($BranchName)) { throw "BranchName is required in $ReviewMode mode." }
        $prefix = if ($ReviewMode -eq 'branch') { 'branch' } else { 'uncommitted' }
        "$prefix-$(ConvertTo-Slug $BranchName)"
    }
}
$timestamp = $parsedStartedAt.UtcDateTime.ToString('yyyyMMdd''T''HHmmss''Z''', [System.Globalization.CultureInfo]::InvariantCulture)
$shortId = $parsedReviewId.ToString('N').Substring(0, 8)
$name = "${scope}_${timestamp}_${Variant}_${shortId}"

# Validate shared storage before creating anything.
$storage = & (Join-Path $PSScriptRoot 'Assert-ReviewStorageSafe.ps1') -RepositoryPath $RepositoryPath -Variant $Variant | ConvertFrom-Json
$storageRoot = Split-Path -Parent ([string]$storage.runs_directory)
$runsDirectory = [string]$storage.runs_directory

foreach ($directory in @($storageRoot, $runsDirectory)) {
    if (-not (Test-Path -LiteralPath $directory)) {
        New-Item -ItemType Directory -Path $directory | Out-Null
    }
    Assert-CreatedDirectory $directory
}

$runDirectory = Join-Path $runsDirectory $name
if (Test-Path -LiteralPath $runDirectory) {
    throw "Run directory already exists; a run folder is never reused: '$runDirectory'."
}
New-Item -ItemType Directory -Path $runDirectory | Out-Null
Assert-CreatedDirectory $runDirectory

[ordered]@{
    name = $name
    run_directory = $runDirectory
    run_directory_relative = ".reviews/runs/$name"
    history_path = [string]$storage.history_path
} | ConvertTo-Json -Depth 4 -Compress
