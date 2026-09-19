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
if (Test-Path -LiteralPath $destination) {
    throw "Destination already exists: '$destination'. Move the existing installation aside or choose a new -DestinationPath."
}

New-Item -ItemType Directory -Path $destination | Out-Null
foreach ($relativePath in ($files.Keys | Sort-Object)) {
    $targetPath = Join-Path $destination $relativePath
    $parentPath = Split-Path -Parent $targetPath
    if (-not (Test-Path -LiteralPath $parentPath)) {
        New-Item -ItemType Directory -Path $parentPath | Out-Null
    }
    Copy-Item -LiteralPath $files[$relativePath] -Destination $targetPath
}

[pscustomobject]@{
    host_app = $HostApp
    destination = $destination
    file_count = $files.Count
}
