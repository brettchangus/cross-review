[CmdletBinding()]
param(
    [ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
    [switch]$AllowNoMatch, [switch]$LocalOnly, [string]$MetadataPath,
    [string]$PrUrl, [string]$RemoteName, [string[]]$GitHubHost = @()
)
$ErrorActionPreference = 'Stop'
$context = & (Join-Path $PSScriptRoot 'Get-ReviewRepository.ps1') -RemoteName $RemoteName -PrUrl $PrUrl -GitHubHost $GitHubHost | ConvertFrom-Json
if ($LocalOnly) { $context | ConvertTo-Json -Depth 8 -Compress; return }
if ($PrUrl) {
    . (Join-Path $PSScriptRoot 'ReviewProvider.ps1')
    $urlPr = Get-ReviewPrUrl $PrUrl
    if ($PullRequestId -and $PullRequestId -ne $urlPr.number) { throw 'PR URL and requested number disagree.' }
    $PullRequestId = $urlPr.number
}
$arguments = @{}
if ($PullRequestId) { $arguments.PullRequestId = $PullRequestId }
if ($AllowNoMatch) { $arguments.AllowNoMatch = $true }
if ($MetadataPath) { $arguments.MetadataPath = $MetadataPath }
switch ($context.provider) {
    'github' { & (Join-Path $PSScriptRoot 'Resolve-GitHubPr.ps1') -RepositoryContext $context @arguments }
    'azure_devops' {
        $arguments.RemoteName = $context.remote_name
        # The Azure validator and IDs remain unchanged for compatibility.
        if ($MetadataPath) { $arguments.Remove('PullRequestId'); $arguments.Remove('AllowNoMatch') }
        $result = & (Join-Path $PSScriptRoot 'Resolve-AdoPr.ps1') @arguments | ConvertFrom-Json
        if ($PullRequestId -and $result.found -and $result.pull_request_id -ne $PullRequestId) { throw 'Requested PR number does not match metadata.' }
        foreach ($field in @('provider', 'provider_host', 'remote_name', 'repository_root')) {
            $result | Add-Member -NotePropertyName $field -NotePropertyValue $context.$field -Force
        }
        $result.metadata_source = $result.metadata_source.Replace('-', '_')
        if (!$result.found) { $result.metadata_source += '_no_match' }
        $result | Add-Member -NotePropertyName metadata_transport -NotePropertyValue $(if ($MetadataPath) { 'mcp' } else { 'cli' })
        $result | ConvertTo-Json -Depth 8 -Compress
    }
    default { throw 'PR discovery requires a recognized Azure DevOps or GitHub remote.' }
}
