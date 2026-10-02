[CmdletBinding()]
param([Parameter(Mandatory)][string]$ContextPath, [string[]]$GitHubHost = @())
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'ReviewProvider.ps1')
$pr = Get-Content -LiteralPath $ContextPath -Raw | ConvertFrom-Json
if (!$pr.found -or $pr.provider -notin @('github', 'azure_devops')) { throw 'Scope requires a validated PR context.' }
$c = & (Join-Path $PSScriptRoot 'Get-ReviewRepository.ps1') -RemoteName $pr.remote_name -GitHubHost $GitHubHost | ConvertFrom-Json
if ($c.provider -ne $pr.provider -or $c.provider_host -ne $pr.provider_host -or $c.local_branch -cne $pr.local_branch -or
    ($c.repository_url -ne $pr.repository_url -and $pr.provider -eq 'github')) { throw 'Repository or branch moved since PR validation.' }
if ($pr.provider -eq 'github' -and $pr.source_repository -ne $c.source_repository_full_name) { throw 'Source repository moved since PR validation.' }
if ($pr.provider -eq 'azure_devops' -and (!$pr.organization_url -or $pr.organization_url.TrimEnd('/') -ne $c.organization_url.TrimEnd('/') -or
    $pr.repository_name -ne $c.repository_name -or $pr.project_name -ne $c.project_name)) { throw 'Azure organization/repository/project moved since PR validation.' }
$source = Assert-ReviewBranchRef $pr.source_ref
if ($source -cne "refs/heads/$($c.local_branch)") { throw 'Source branch does not match the current local branch.' }
$target = Assert-ReviewBranchRef $pr.target_ref
$number = 0
if (![int]::TryParse([string]$pr.pull_request_id, [ref]$number) -or $number -le 0) { throw 'Invalid PR number.' }
$sourceFetch = if ($pr.provider -eq 'github') { "refs/pull/$number/head" } else { $source }
$sourceLocal = "refs/cross-review/pr/$number/head"
$targetLocal = "refs/cross-review/pr/$number/base"
foreach ($pair in @(@($sourceFetch, $sourceLocal), @($target, $targetLocal))) {
    Invoke-ReviewGit @('-C', $c.repository_root, 'fetch', '--no-tags', '--', $c.remote_name, "+$($pair[0]):$($pair[1])") `
        -FailureMessage 'PR ref fetch failed; check Git authentication and repository access.' | Out-Null
}
$sourceCommit = Invoke-ReviewGit @('-C', $c.repository_root, 'rev-parse', "$sourceLocal^{commit}")
$targetCommit = Invoke-ReviewGit @('-C', $c.repository_root, 'rev-parse', "$targetLocal^{commit}")
# Only the reported source SHA is compared. Neither provider's reported base
# tracks the branch tip: GitHub's base.sha stays at the base as of the last
# head push, and Azure lastMergeTargetCommit can lag, so the fetched target
# tip is frozen instead.
if ($pr.source_commit -and $sourceCommit -ne $pr.source_commit) {
    throw 'PR moved during resolution; refresh metadata and retry before preflight.'
}
$pr.source_commit = $sourceCommit; $pr.target_commit = $targetCommit
$pr | Add-Member -NotePropertyName source_local_ref -NotePropertyValue $sourceLocal -Force
$pr | Add-Member -NotePropertyName target_local_ref -NotePropertyValue $targetLocal -Force
$pr | ConvertTo-Json -Depth 8 -Compress
