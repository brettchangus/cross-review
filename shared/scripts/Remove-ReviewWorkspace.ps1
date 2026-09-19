[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$WorktreePath,

    [Parameter()]
    [string]$RepositoryPath = '.'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Invoke-GitText {
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$FailureMessage)

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage $($output -join [Environment]::NewLine)"
    }
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    return (($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Get-NormalizedPath {
    param([Parameter(Mandatory)][string]$Path)
    return [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
}

function Get-WorktreePaths {
    param([Parameter(Mandatory)][string]$GitDirectory)

    $listText = Invoke-GitText @('-C', $GitDirectory, 'worktree', 'list', '--porcelain') 'Cannot list Git worktrees.'
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($listText -split '\r?\n')) {
        if ($line -match '^worktree (.+)$') { $paths.Add((Get-NormalizedPath $Matches[1])) }
    }
    if ($paths.Count -eq 0) { throw 'Git reported no worktrees.' }
    return $paths
}

function Invoke-WorktreeRemove {
    param([Parameter(Mandatory)][string]$MainWorktree, [Parameter(Mandatory)][string]$Target, [switch]$Force)

    $arguments = @('-C', $MainWorktree, 'worktree', 'remove')
    if ($Force) { $arguments += '--force' }
    $arguments += $Target
    $output = @(& git @arguments 2>&1)
    return [pscustomobject]@{
        succeeded = ($LASTEXITCODE -eq 0)
        message = (($output | ForEach-Object { [string]$_ }) -join ' ').Trim()
    }
}

$target = Get-NormalizedPath $WorktreePath
# @() matters: PowerShell unrolls a single-element list into a bare string, and [0] would then
# return its first character.
$worktreePaths = @(Get-WorktreePaths -GitDirectory $RepositoryPath)
$mainWorktree = [string]$worktreePaths[0]

if ([string]::Equals($target, $mainWorktree, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to remove the main worktree: '$target'."
}

# Leave the target directory before deleting it. A process standing inside a worktree makes
# removal fail on Windows, and Git deregisters the worktree before that failure surfaces.
Set-Location -LiteralPath $mainWorktree

$warnings = [System.Collections.Generic.List[string]]::new()
$registered = $worktreePaths -contains $target
$removed = $true
$method = 'already_absent'

if ($registered) {
    $attempt = Invoke-WorktreeRemove -MainWorktree $mainWorktree -Target $target
    if ($attempt.succeeded) {
        $method = 'removed'
    } else {
        $warnings.Add("Removal needed a retry: $($attempt.message)")
        $forced = Invoke-WorktreeRemove -MainWorktree $mainWorktree -Target $target -Force
        if ($forced.succeeded) {
            $method = 'removed_forced'
        } else {
            $removed = $false
            $method = 'removal_failed'
            $warnings.Add("Forced removal also failed: $($forced.message)")
        }
    }
}

$stillRegistered = @(Get-WorktreePaths -GitDirectory $mainWorktree) -contains $target
$stillExists = Test-Path -LiteralPath $target

if ($stillRegistered) {
    $removed = $false
    if ($method -eq 'already_absent') { $method = 'removal_failed' }
    $warnings.Add("'$target' is still a registered worktree. Remove it manually with: git -C `"$mainWorktree`" worktree remove --force `"$target`"")
} elseif ($stillExists) {
    $isEmpty = @(Get-ChildItem -LiteralPath $target -Force -ErrorAction SilentlyContinue).Count -eq 0
    if ($isEmpty) {
        try {
            Remove-Item -LiteralPath $target -Force -Recurse
            $removed = $true
            $method = 'orphan_directory_removed'
        } catch {
            $removed = $false
            $warnings.Add("'$target' is no longer a registered worktree but the empty directory could not be deleted: $($_.Exception.Message)")
        }
    } else {
        $removed = $false
        if ($method -eq 'already_absent') { $method = 'unregistered_directory_kept' }
        $warnings.Add("'$target' is not a registered worktree and is not empty; nothing was deleted. Inspect and delete it manually.")
    }
}

& git -C $mainWorktree worktree prune 2>&1 | Out-Null

foreach ($warning in $warnings) { Write-Warning $warning }

[ordered]@{
    schema_version = 1
    removed = $removed
    method = $method
    worktree_path = $target
    repository_root = $mainWorktree
    registered_before = $registered
    warnings = @($warnings)
} | ConvertTo-Json -Depth 4 -Compress
