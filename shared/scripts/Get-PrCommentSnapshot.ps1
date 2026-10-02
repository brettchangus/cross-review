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
    [string]$RawResponsePath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
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
                if ($null -eq $comment -or $comment.isDeleted -eq $true -or $comment.commentType -ne 'text') { continue }
                if ($null -eq $comment.id) { throw "Thread $($thread.id) has a comment without an ID." }
                [ordered]@{
                    id = $comment.id
                    parent_comment_id = $comment.parentCommentId
                    author = [string]$comment.author.displayName
                    content = [string]$comment.content
                    published_at = $comment.publishedDate
                    updated_at = $comment.lastUpdatedDate
                    type = [string]$comment.commentType
                }
            }
        )
        if ($comments.Count -eq 0) { continue }
        [ordered]@{
            id = $thread.id
            status = [string]$thread.status
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
