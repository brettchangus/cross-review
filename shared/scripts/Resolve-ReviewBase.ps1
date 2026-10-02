[CmdletBinding()]
param([string]$RemoteName, [string[]]$GitHubHost = @())
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'ReviewProvider.ps1')
$c = & (Join-Path $PSScriptRoot 'Get-ReviewRepository.ps1') -RemoteName $RemoteName -GitHubHost $GitHubHost | ConvertFrom-Json
$remote = $c.remote_name
$base = ''
if ($remote) {
    # ls-remote reads the actual default even when origin/HEAD is missing/stale.
    $advertisement = Invoke-ReviewGit @('-C', $c.repository_root, 'ls-remote', '--symref', '--', $remote, 'HEAD') `
        -FailureMessage "Cannot read the default branch from remote '$remote'; check network access and Git authentication."
    foreach ($line in $advertisement -split '\r?\n') {
        if ($line -match '^ref: (refs/heads/[^\s]+)\s+HEAD$') { $base = $Matches[1]; break }
    }
    if (!$base -and $c.default_ref -like "refs/remotes/$remote/*") {
        $base = 'refs/heads/' + $c.default_ref.Substring("refs/remotes/$remote/".Length)
    }
}
if (!$base) {
    foreach ($candidate in @('main', 'master')) {
        if (Invoke-ReviewGit @('-C', $c.repository_root, 'show-ref', '--verify', "refs/heads/$candidate") -Optional) {
            $base = "refs/heads/$candidate"; break
        }
    }
}
if (!$base) { throw 'Cannot resolve the repository default branch.' }
$base = Assert-ReviewBranchRef $base
$localRef = $base
if ($remote) {
    $localRef = "refs/remotes/$remote/$($base.Substring(11))"
    Invoke-ReviewGit @('-C', $c.repository_root, 'fetch', '--no-tags', '--', $remote, "+${base}:$localRef") `
        -FailureMessage 'Cannot fetch the repository default branch.' | Out-Null
}
[ordered]@{
    target_ref = $base; target_local_ref = $localRef
    target_commit = Invoke-ReviewGit @('-C', $c.repository_root, 'rev-parse', "$localRef^{commit}")
    is_default_branch = ($base -ceq "refs/heads/$($c.local_branch)")
    remote_name = $remote; provider = $c.provider; provider_host = $c.provider_host
} | ConvertTo-Json -Compress
