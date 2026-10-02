[CmdletBinding()]
param([string]$RemoteName, [string]$PrUrl, [string[]]$GitHubHost = @())
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'ReviewProvider.ps1')
$root = Invoke-ReviewGit @('rev-parse', '--show-toplevel')
$branch = Invoke-ReviewGit @('-C', $root, 'branch', '--show-current')
if (!$branch) { throw 'Detached HEAD is not supported.' }
$head = Invoke-ReviewGit @('-C', $root, 'rev-parse', 'HEAD')
$remoteNames = @( (Invoke-ReviewGit @('-C', $root, 'remote')) -split '\r?\n' | Where-Object { $_ })
$trackingRemote = Invoke-ReviewGit @('-C', $root, 'config', '--get', "branch.$branch.remote") -Optional
$trackingRef = Invoke-ReviewGit @('-C', $root, 'config', '--get', "branch.$branch.merge") -Optional
$remotes = @(
    foreach ($name in $remoteNames) {
        $url = Get-ReviewRemoteUrl -RepositoryRoot $root -RemoteName $name -GitHubHost $GitHubHost
        $identity = Get-ReviewRemoteIdentity $url $GitHubHost
        $identity | Add-Member -NotePropertyName remote_name -NotePropertyValue $name
        $identity
    }
)
$origin = @($remotes | Where-Object remote_name -eq 'origin' | Select-Object -First 1)
$tracking = @($remotes | Where-Object remote_name -eq $trackingRemote | Select-Object -First 1)
$source = $tracking
if ($trackingRemote -and $trackingRemote -ne '.' -and !$source.Count) {
    # gh pr checkout can track a fork URL without adding a named fork remote.
    # Keep that source identity while selecting a configured target remote.
    $trackingIdentity = Get-ReviewRemoteIdentity $trackingRemote $GitHubHost
    if ($trackingIdentity.provider -notin @('github', 'azure_devops')) {
        $trackingUrl = Invoke-ReviewGit @('-C', $root, 'ls-remote', '--get-url', '--', $trackingRemote)
        $trackingIdentity = Get-ReviewRemoteIdentity $trackingUrl $GitHubHost
    }
    $source = @($trackingIdentity)
    $tracking = @($remotes | Where-Object { $_.provider -eq $trackingIdentity.provider -and $_.url -eq $trackingIdentity.url } |
        Sort-Object remote_name | Select-Object -First 1)
    if (!$remotes.Count) { throw 'URL-valued branch tracking requires a configured target remote.' }
}
if (!$source.Count) { $source = $origin }
$selected = @()
if ($PrUrl) {
    $pr = Get-ReviewPrUrl $PrUrl
    $selected = @($remotes | Where-Object { $_.provider -eq 'github' -and $_.host -eq $pr.host -and $_.full_name -eq $pr.full_name })
    if (!$selected.Count) { throw 'PR URL repository does not match any recognized local GitHub remote.' }
    if ($RemoteName) { $selected = @($selected | Where-Object remote_name -eq $RemoteName) }
    if ($selected.Count -gt 1) { $selected = @($selected | Sort-Object remote_name | Select-Object -First 1) }
} elseif ($RemoteName) {
    $selected = @($remotes | Where-Object remote_name -eq $RemoteName)
} elseif ($tracking.Count) {
    $selected = $tracking
} elseif ($origin.Count) { $selected = $origin }
elseif ($remotes.Count -eq 1) { $selected = $remotes }
elseif ($remotes.Count -gt 1) { throw 'Multiple remotes are ambiguous; configure branch tracking or supply a PR URL/RemoteName.' }
if (($RemoteName -or $PrUrl) -and !$selected.Count) { throw 'Selected remote does not exist or does not match the PR URL.' }
if (!$selected.Count) { $selected = @(Get-ReviewRemoteIdentity '') }
$remote = $selected[0]
if (!$source.Count) { $source = @($remote) }

# Keep the existing Azure/local IDs verbatim, including root fingerprints.
$legacy = & (Join-Path $PSScriptRoot 'Resolve-AdoPr.ps1') -LocalOnly -RemoteName $(if ($remote.remote_name) { $remote.remote_name } else { 'origin' }) | ConvertFrom-Json
$id = $legacy.repository_id; $name = $legacy.repository_name
if ($remote.provider -eq 'github') {
    $id = "github://$($remote.host)/$($remote.full_name.ToLowerInvariant())"; $name = $remote.name
}
$defaultRef = ''
if ($remote.remote_name) {
    $defaultRef = Invoke-ReviewGit @('-C', $root, 'symbolic-ref', "refs/remotes/$($remote.remote_name)/HEAD") -Optional
}
[ordered]@{
    operation = 'local_identity'; found = $false; repository_root = $root
    provider = $remote.provider; provider_host = $remote.host; remote_name = $remote.remote_name
    repository_id = $id; repository_name = $name; repository_url = $remote.url
    repository_owner = $remote.owner; repository_full_name = $remote.full_name
    project_id = $legacy.project_id; project_name = $legacy.project_name; organization_url = $legacy.organization_url
    local_branch = $branch; local_head_commit = $head; local_origin_url = Get-ReviewSafeUrl $legacy.local_origin_url
    local_repository_name = $legacy.local_repository_name; local_project_name = $legacy.local_project_name
    source_repository_full_name = $source[0].full_name; source_repository_host = $source[0].host
    source_branch = if ($trackingRef -like 'refs/heads/*') { $trackingRef.Substring(11) } else { $branch }
    default_ref = $defaultRef; metadata_source = 'not_used'; remotes = $remotes
} | ConvertTo-Json -Depth 8 -Compress
