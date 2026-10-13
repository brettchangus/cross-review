[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepositoryPath,
    [Parameter(Mandatory)][string]$WorktreePath,
    [Parameter(Mandatory)][string]$SourceCommit
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'ReviewProvider.ps1')
$root = Invoke-ReviewGit @('-C', $RepositoryPath, 'rev-parse', '--show-toplevel') -FailureMessage 'Cannot resolve repository.'
$head = Invoke-ReviewGit @('-C', $root, 'rev-parse', 'HEAD') -FailureMessage 'Cannot resolve HEAD.'
if ($SourceCommit -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$' -or $head -ne $SourceCommit) {
    throw 'Combined review source must equal the approved local HEAD.'
}
$destination = [IO.Path]::GetFullPath($WorktreePath)
if (Test-Path -LiteralPath $destination) { throw 'Review worktree path must not already exist.' }
$indexPath = Invoke-ReviewGit @('-C', $root, 'rev-parse', '--path-format=absolute', '--git-path', 'index') -FailureMessage 'Cannot resolve index.'
$temporaryIndex = Join-Path ([IO.Path]::GetTempPath()) ('cross-review-index-' + [Guid]::NewGuid().ToString('N'))
$pathspecFile = "$temporaryIndex.paths"
$previousIndex = $env:GIT_INDEX_FILE
try {
    # Preserve force-added ignored files without ever staging in the user's index.
    Copy-Item -LiteralPath $indexPath -Destination $temporaryIndex
    $env:GIT_INDEX_FILE = $temporaryIndex
    # PowerShell 7.4+ preserves native bytes on redirection. NUL pathspecs handle
    # spaces/newlines and avoid explicitly selecting ignored bookkeeping dirs.
    & git -C $root ls-files -z --cached --others --exclude-standard -- . ':(top,exclude).reviews' ':(top,exclude).claude/worktrees' > $pathspecFile
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate snapshot files.' }
    if ((Get-Item -LiteralPath $pathspecFile).Length -gt 0) {
        Invoke-ReviewGit @('-C', $root, 'add', '-A', "--pathspec-from-file=$pathspecFile", '--pathspec-file-nul') -FailureMessage 'Cannot snapshot local files.' | Out-Null
    }
    $tree = Invoke-ReviewGit @('-C', $root, 'write-tree') -FailureMessage 'Cannot freeze local tree (resolve conflicts first).'
} finally {
    $env:GIT_INDEX_FILE = $previousIndex
    foreach ($path in @($temporaryIndex, "$temporaryIndex.lock", $pathspecFile)) {
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
    }
}
Invoke-ReviewGit @('-C', $root, 'worktree', 'add', '--detach', $destination, $SourceCommit) -FailureMessage 'Cannot create review worktree.' | Out-Null
# HEAD retains the branch history; the frozen local tree is staged in this worktree.
# Native --base review sees the merge-base-to-workspace diff, including new files.
Invoke-ReviewGit @('-C', $destination, 'read-tree', '--reset', '-u', $tree) -FailureMessage 'Cannot materialize local snapshot; preserve the worktree for cleanup.' | Out-Null
[ordered]@{ working_directory = $destination; source_commit = $SourceCommit; local_tree = $tree; includes_local_changes = $true } | ConvertTo-Json -Compress
