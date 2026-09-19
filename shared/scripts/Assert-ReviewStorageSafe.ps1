[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepositoryPath = '.',

    # 'legacy' is the former name of 'claude-led' and is kept for older call sites.
    [ValidateSet('legacy', 'claude-led', 'codex-led')]
    [string]$Variant = 'claude-led',

    # A run folder under .reviews/runs/ to validate before writing into it.
    [Parameter()]
    [string]$RunDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
if ($Variant -eq 'legacy') { $Variant = 'claude-led' }

function Invoke-GitText {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Cannot resolve the repository root: $($output -join [Environment]::NewLine)"
    }
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    return (($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Test-IsLinkOrReparsePoint {
    param([Parameter(Mandatory)]$Item)

    if (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
    $linkType = $Item.PSObject.Properties['LinkType']
    return $null -ne $linkType -and -not [string]::IsNullOrWhiteSpace([string]$linkType.Value)
}

function Assert-RegularDirectory {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return }
    $item = Get-Item -LiteralPath $Path -Force
    if (-not $item.PSIsContainer) {
        throw "Review storage path is not a directory: '$Path'."
    }
    if (Test-IsLinkOrReparsePoint $item) {
        throw "Review storage must not be a symbolic link, junction, or reparse point: '$Path'."
    }
}

function Assert-RegularFiles {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string[]]$Names
    )

    if (-not (Test-Path -LiteralPath $Directory)) { return }
    foreach ($name in $Names) {
        $path = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $item = Get-Item -LiteralPath $path -Force
        if ($item.PSIsContainer -or (Test-IsLinkOrReparsePoint $item)) {
            throw "Managed review artifact must be a regular file: '$path'."
        }
    }
}

$repositoryRoot = Invoke-GitText @('-C', $RepositoryPath, 'rev-parse', '--show-toplevel')
$storageRoot = Join-Path $repositoryRoot '.reviews'
$runsDirectory = Join-Path $storageRoot 'runs'
# The history file is the only artifact shared between runs. Each variant keeps
# its own, so estimates never mix the two workflows.
$historyDirectory = if ($Variant -eq 'claude-led') { $storageRoot } else { Join-Path $storageRoot $Variant }
$sharedFiles = @('history.jsonl')
$runFiles = @(
    'run-context.json',
    'claude-review.md',
    'codex-independent.md',
    'codex-evaluation.md',
    'claude-evaluation.md',
    'adjudication.json',
    'metrics.json',
    'final.md'
)

foreach ($directory in @($storageRoot, $historyDirectory, $runsDirectory) | Select-Object -Unique) {
    Assert-RegularDirectory $directory
}
Assert-RegularFiles -Directory $historyDirectory -Names $sharedFiles
$checkedCount = $sharedFiles.Count

$resolvedRunDirectory = $null
if (-not [string]::IsNullOrWhiteSpace($RunDirectory)) {
    $resolvedRunDirectory = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($RunDirectory).TrimEnd('\', '/')
    $parent = Split-Path -Parent $resolvedRunDirectory
    if (-not [string]::Equals([System.IO.Path]::GetFullPath($runsDirectory).TrimEnd('\', '/'), [System.IO.Path]::GetFullPath($parent).TrimEnd('\', '/'), [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Run directory must sit directly under '$runsDirectory': '$resolvedRunDirectory'."
    }
    Assert-RegularDirectory $resolvedRunDirectory
    Assert-RegularFiles -Directory $resolvedRunDirectory -Names $runFiles
    $checkedCount += $runFiles.Count
}

[ordered]@{
    safe = $true
    repository_root = $repositoryRoot
    variant = $Variant
    history_directory = $historyDirectory
    history_path = Join-Path $historyDirectory 'history.jsonl'
    runs_directory = $runsDirectory
    run_directory = $resolvedRunDirectory
    managed_files_checked = $checkedCount
} | ConvertTo-Json -Depth 4 -Compress
