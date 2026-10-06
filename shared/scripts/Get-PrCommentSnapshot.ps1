[CmdletBinding()]
param(
    [ValidateSet('azure_devops', 'github')][string]$Provider = 'azure_devops',
    [string]$HostName = 'github.com',
    [string]$RepositoryFullName,
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
    [string]$OrganizationUrl,
    [string]$Project,
    [string]$RepositoryId,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$RawResponsePath,
    [string]$UnavailableReason
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

# When neither MCP nor CLI can capture the discussion, record that explicitly
# (complete = false, with the reason) so the run can continue without the gap
# being mistaken for a PR with no comments.
if ($PSBoundParameters.ContainsKey('UnavailableReason')) {
    if ([string]::IsNullOrWhiteSpace($UnavailableReason)) { throw 'UnavailableReason must describe what failed.' }
    if ($RawResponsePath) { throw 'UnavailableReason cannot be combined with RawResponsePath.' }
    $providerHost = if ($Provider -eq 'github') { $HostName } else {
        if ([string]::IsNullOrWhiteSpace($OrganizationUrl)) { throw 'Azure discussion requires organization URL.' }
        ([Uri]$OrganizationUrl).Host
    }
    $unavailable = [ordered]@{
        schema_version = 1
        provider = $Provider
        provider_host = $providerHost
        capabilities = [ordered]@{ complete = $false }
        unavailable_reason = $UnavailableReason.Trim()
        pull_request_id = $PullRequestId
        captured_at = (Get-Date).ToUniversalTime().ToString('o')
        source = 'unavailable'
        threads = @()
    }
    if ($Provider -eq 'github') { $unavailable.repository_full_name = $RepositoryFullName }
    $outputDirectory = Split-Path -Parent $OutputPath
    if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) { throw 'OutputPath parent directory does not exist.' }
    [System.IO.File]::WriteAllText($OutputPath, ($unavailable | ConvertTo-Json -Depth 5), [System.Text.UTF8Encoding]::new($false))
    $unavailable | ConvertTo-Json -Depth 5 -Compress
    return
}

# The Azure DevOps MCP serializes REST enums as numbers (commentType 1 = text),
# while the Azure CLI returns names. Normalize both, and fail on anything
# unrecognized so a format change cannot silently empty the discussion.
function ConvertTo-AdoEnumName {
    param($Value, [string[]]$Names, [string]$Label)
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    $text = ([string]$Value).Trim()
    $index = 0
    if ([int]::TryParse($text, [ref]$index)) {
        if ($index -ge 0 -and $index -lt $Names.Count) { return $Names[$index] }
    } else {
        foreach ($name in $Names) {
            if ([string]::Equals($name, $text, [System.StringComparison]::OrdinalIgnoreCase)) { return $name }
        }
    }
    throw "Unrecognized Azure DevOps $Label '$text'."
}
$commentTypeNames = @('unknown', 'text', 'codeChange', 'system')
$threadStatusNames = @('unknown', 'active', 'fixed', 'wontFix', 'closed', 'byDesign', 'pending')

if ($Provider -eq 'github') {
    & (Join-Path $PSScriptRoot 'Get-GitHubPrCommentSnapshot.ps1') -PullRequestId $PullRequestId -HostName $HostName -RepositoryFullName $RepositoryFullName -OutputPath $OutputPath -RawResponsePath $RawResponsePath
    return
}
foreach ($value in @($OrganizationUrl, $Project, $RepositoryId)) {
    if ([string]::IsNullOrWhiteSpace($value)) { throw 'Azure discussion requires organization, project, and repository ID.' }
}

if ($RawResponsePath) {
    if (-not (Test-Path -LiteralPath $RawResponsePath -PathType Leaf)) { throw 'RawResponsePath must be an existing file.' }
    $raw = Get-Content -LiteralPath $RawResponsePath -Raw
    $source = 'azure_devops_mcp'
} else {
    $response = @(& az devops invoke --area git --resource pullRequestThreads `
        --route-parameters "project=$Project" "repositoryId=$RepositoryId" "pullRequestId=$PullRequestId" `
        --organization $OrganizationUrl --api-version 7.1 --http-method GET --output json --only-show-errors 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI could not list comments for PR #${PullRequestId}: $($response -join [Environment]::NewLine)" }
    $raw = $response -join [Environment]::NewLine
    $source = 'azure_cli_fallback'
}

if ([string]::IsNullOrWhiteSpace($raw)) { throw 'PR comment response is empty.' }
# Wrap the JSON so a raw thread array survives parsing: ConvertFrom-Json
# enumerates top-level arrays, turning [] into null and [x] into x.
try { $payload = ('{"payload":' + $raw + '}' | ConvertFrom-Json).payload }
catch { throw "PR comment response is not valid JSON: $($_.Exception.Message)" }
if ($null -eq $payload) { throw 'PR comment response is empty.' }
if ($payload -is [array]) {
    $allThreads = @($payload)
} elseif ($payload.PSObject.Properties.Name -contains 'value' -and $payload.value -is [array]) {
    $allThreads = @($payload.value)
    if ($payload.PSObject.Properties.Name -contains 'count' -and [int]$payload.count -ne $allThreads.Count) {
        throw 'PR comment response count does not match its thread array.'
    }
} else {
    throw 'PR comment response must contain a thread array.'
}

$threads = @(
    foreach ($thread in $allThreads) {
        if ($null -eq $thread -or $thread.isDeleted -eq $true) { continue }
        if ($null -eq $thread.id) { throw 'A PR comment thread has no ID.' }
        $comments = @(
            foreach ($comment in @($thread.comments)) {
                if ($null -eq $comment -or $comment.isDeleted -eq $true) { continue }
                if ($null -eq $comment.id) { throw "Thread $($thread.id) has a comment without an ID." }
                $commentType = ConvertTo-AdoEnumName $comment.commentType $commentTypeNames 'comment type'
                if ($null -eq $commentType) { throw "Thread $($thread.id) comment $($comment.id) has no comment type." }
                if ($commentType -ne 'text') { continue }
                if ($null -eq $comment.content) { throw "Thread $($thread.id) comment $($comment.id) has no content." }
                [ordered]@{
                    id = $comment.id
                    parent_comment_id = $comment.parentCommentId
                    author = [string]$comment.author.displayName
                    content = [string]$comment.content
                    published_at = $comment.publishedDate
                    updated_at = $comment.lastUpdatedDate
                    type = $commentType
                }
            }
        )
        if ($comments.Count -eq 0) { continue }
        [ordered]@{
            id = $thread.id
            status = [string](ConvertTo-AdoEnumName $thread.status $threadStatusNames 'thread status')
            published_at = $thread.publishedDate
            updated_at = $thread.lastUpdatedDate
            context = $thread.threadContext
            pull_request_context = $thread.pullRequestThreadContext
            comments = $comments
        }
    }
)

$snapshot = [ordered]@{
    schema_version = 1
    provider = 'azure_devops'
    provider_host = ([Uri]$OrganizationUrl).Host
    capabilities = [ordered]@{ complete = $true; inline_threads = $true; thread_resolution = $true; iteration_context = $true }
    pull_request_id = $PullRequestId
    captured_at = (Get-Date).ToUniversalTime().ToString('o')
    source = $source
    threads = $threads
}
$outputDirectory = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $outputDirectory -PathType Container)) { throw 'OutputPath parent directory does not exist.' }
[System.IO.File]::WriteAllText($OutputPath, ($snapshot | ConvertTo-Json -Depth 30), [System.Text.UTF8Encoding]::new($false))
$snapshot | ConvertTo-Json -Depth 30 -Compress
