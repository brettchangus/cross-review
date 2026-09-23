[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Claude', 'Codex')]
    [string]$HostApp,

    # The complete destination skill directory, not its parent.
    [Parameter()]
    [string]$DestinationPath
)

$ErrorActionPreference = 'Stop'
$hostDirectory = $HostApp.ToLowerInvariant()
$sourceDirectory = Join-Path $PSScriptRoot "skills/$hostDirectory/cross-review"
$sharedDirectory = Join-Path $PSScriptRoot 'shared'

if (-not (Test-Path -LiteralPath (Join-Path $sourceDirectory 'SKILL.md') -PathType Leaf)) {
    throw "The $HostApp implementation is not available: '$sourceDirectory'. No installation was created."
}

# Build the complete file map before writing. Shared and host-specific files
# must not silently overwrite each other.
$files = @{}
foreach ($directory in @($sharedDirectory, $sourceDirectory)) {
    foreach ($file in Get-ChildItem -LiteralPath $directory -File -Recurse -Force) {
        $relativePath = $file.FullName.Substring($directory.Length).TrimStart('\', '/')
        if ($files.ContainsKey($relativePath)) {
            throw "Shared and host-specific resources collide at '$relativePath'."
        }
        $files[$relativePath] = $file.FullName
    }
}

if ([string]::IsNullOrWhiteSpace($DestinationPath)) {
    $userDirectory = [Environment]::GetFolderPath('UserProfile')
    $skillsDirectory = if ($HostApp -eq 'Claude') { '.claude/skills' } else { '.agents/skills' }
    $DestinationPath = Join-Path (Join-Path $userDirectory $skillsDirectory) 'cross-review'
}
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($DestinationPath)
$destination = $destination.TrimEnd('\', '/')

# Only replace a directory that is recognizably an existing cross-review
# installation, so a mistyped -DestinationPath cannot delete unrelated files.
$replacing = Test-Path -LiteralPath $destination
if ($replacing) {
    $existingSkill = Join-Path $destination 'SKILL.md'
    if (-not (Test-Path -LiteralPath $destination -PathType Container) -or
        -not (Test-Path -LiteralPath $existingSkill -PathType Leaf) -or
        -not (Select-String -LiteralPath $existingSkill -Pattern '^name:\s*cross-review\s*$' -Quiet)) {
        throw "Destination exists but is not a cross-review installation: '$destination'. No changes were made."
    }
}

# Build the new installation beside the destination, then swap it in, so a
# failed copy never leaves a partial or mixed installation behind.
$parentDirectory = Split-Path -Parent $destination
$leafName = Split-Path -Leaf $destination
$suffix = [Guid]::NewGuid().ToString('N')
$stagingPath = Join-Path $parentDirectory ".$leafName.install-$suffix"
$previousPath = Join-Path $parentDirectory ".$leafName.previous-$suffix"

New-Item -ItemType Directory -Path $stagingPath -Force | Out-Null
try {
    foreach ($relativePath in ($files.Keys | Sort-Object)) {
        $targetPath = Join-Path $stagingPath $relativePath
        $parentPath = Split-Path -Parent $targetPath
        if (-not (Test-Path -LiteralPath $parentPath)) {
            New-Item -ItemType Directory -Path $parentPath | Out-Null
        }
        Copy-Item -LiteralPath $files[$relativePath] -Destination $targetPath
    }

    if ($replacing) {
        Move-Item -LiteralPath $destination -Destination $previousPath
        try { Move-Item -LiteralPath $stagingPath -Destination $destination }
        catch {
            Move-Item -LiteralPath $previousPath -Destination $destination
            throw
        }
        Remove-Item -LiteralPath $previousPath -Recurse -Force
    } else {
        Move-Item -LiteralPath $stagingPath -Destination $destination
    }
} finally {
    if (Test-Path -LiteralPath $stagingPath) {
        Remove-Item -LiteralPath $stagingPath -Recurse -Force
    }
}

[pscustomobject]@{
    host_app = $HostApp
    destination = $destination
    file_count = $files.Count
    replaced = $replacing
}
