[CmdletBinding()]
param(
    [Parameter(Mandatory)]$RepositoryContext,
    [ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
    [switch]$AllowNoMatch, [string]$MetadataPath
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'ReviewProvider.ps1')
$c = $RepositoryContext
$hostName = $c.provider_host; $fullName = $c.repository_full_name
$transport = if ($MetadataPath) { 'mcp' } else { 'cli' }
if ($MetadataPath) {
    $pr = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json
} else {
    if (!$PullRequestId) {
        # REST head filtering includes the fork owner, unlike gh pr list --head.
        $sourceParts = $c.source_repository_full_name -split '/'
        $pages = Invoke-ReviewGhJson @('api', '--hostname', $hostName, '--method', 'GET', '--paginate', '--slurp',
            "repos/$fullName/pulls", '-f', 'state=open', '-f', "head=$($sourceParts[0]):$($c.source_branch)", '-f', 'per_page=100')
        if ($pages -isnot [array] -or !$pages.Count) { throw 'GitHub PR discovery response is incomplete.' }
        $matches = @(
            foreach ($page in $pages) {
                if ($page -isnot [array]) { throw 'GitHub PR discovery response contains a malformed page.' }
                foreach ($candidate in $page) {
                    if (!$candidate.number -or !$candidate.head.repo.full_name -or !$candidate.head.ref) { throw 'GitHub PR discovery response omits required metadata.' }
                    if ($candidate.head.repo.full_name -eq $c.source_repository_full_name -and $candidate.head.ref -ceq $c.source_branch) { $candidate }
                }
            }
        )
        if (!$matches.Count) {
            if (!$AllowNoMatch) { throw 'No open GitHub PR matches the local source repository and branch.' }
            $c.operation = 'pr_lookup'; $c.metadata_source = 'github_cli_no_match'
            $c | Add-Member -NotePropertyName metadata_transport -NotePropertyValue 'cli'
            $c | ConvertTo-Json -Depth 8 -Compress; return
        }
        if ($matches.Count -ne 1) { throw 'Multiple open GitHub PRs match; specify pr <number> or a PR URL.' }
        $PullRequestId = $matches[0].number
    }
    $pr = Invoke-ReviewGhJson @('api', '--hostname', $hostName, "repos/$fullName/pulls/$PullRequestId")
}
# CLI and MCP use the complete REST-shaped PR record, never synthesized fields.
if (!$pr.number -or !$pr.base.repo.full_name -or !$pr.head.repo.full_name -or !$pr.html_url) { throw 'GitHub metadata omits required PR/repository fields.' }
$number = 0
if (![int]::TryParse([string]$pr.number, [ref]$number) -or $number -le 0) { throw 'Invalid GitHub PR number.' }
if ($PullRequestId -and $PullRequestId -ne $number) { throw 'Requested PR number does not match metadata.' }
$url = Get-ReviewPrUrl $pr.html_url
if ($url.host -ne $hostName -or $url.full_name -ne $fullName -or $url.number -ne $number -or $pr.base.repo.full_name -ne $fullName) { throw 'Repository safety check failed for GitHub PR.' }
if ($pr.state -ne 'open') { throw 'GitHub PR is not open.' }
if ($pr.head.repo.full_name -ne $c.source_repository_full_name -or $c.source_repository_host -ne $hostName) { throw 'Source repository safety check failed for GitHub PR.' }
if ($pr.head.ref -cne $c.local_branch) { throw 'Branch safety check failed for GitHub PR.' }
$sourceRef = Assert-ReviewBranchRef "refs/heads/$($pr.head.ref)"
$targetRef = Assert-ReviewBranchRef "refs/heads/$($pr.base.ref)"
foreach ($sha in @($pr.head.sha, $pr.base.sha)) {
    if ([string]$sha -notmatch '^[0-9a-fA-F]{40}$') { throw 'GitHub PR metadata contains an invalid commit SHA.' }
}
[ordered]@{
    operation = 'pr_lookup'; found = $true; provider = 'github'; provider_host = $hostName
    metadata_source = "github_$transport"; metadata_transport = $transport
    pull_request_id = $number; title = [string]$pr.title; status = 'active'; draft = [bool]$pr.draft
    pull_request_url = "https://$hostName/$fullName/pull/$number"
    repository_root = $c.repository_root; remote_name = $c.remote_name
    repository_id = "github://$hostName/$($fullName.ToLowerInvariant())"
    repository_name = $c.repository_name; repository_owner = $c.repository_owner
    repository_full_name = $fullName; repository_url = "https://$hostName/$fullName"
    project_id = ''; project_name = ''; organization_url = ''
    source_repository = [string]$pr.head.repo.full_name; target_repository = $fullName
    source_ref = $sourceRef; target_ref = $targetRef
    source_commit = [string]$pr.head.sha; target_commit = [string]$pr.base.sha
    source_fetch_ref = "refs/pull/$number/head"
    local_branch = $c.local_branch; local_head_commit = $c.local_head_commit
    local_origin_url = $c.local_origin_url; local_repository_name = $c.local_repository_name
} | ConvertTo-Json -Depth 8 -Compress
