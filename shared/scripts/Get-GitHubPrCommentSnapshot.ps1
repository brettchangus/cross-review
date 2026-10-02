[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int]$PullRequestId,
    [Parameter(Mandatory)][string]$RepositoryFullName,
    [string]$HostName = 'github.com',
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$RawResponsePath
)
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'ReviewProvider.ps1')
if ($HostName -notmatch '^[A-Za-z0-9.-]+$' -or $RepositoryFullName -notmatch '^([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$') { throw 'Invalid GitHub repository identity.' }
$owner = $Matches[1]; $name = $Matches[2]
$commentFields = 'id body author { login } createdAt updatedAt url'
$threadFields = 'id isResolved isOutdated path line originalLine startLine originalStartLine diffSide startDiffSide resolvedBy { login }'
$replyFields = "$commentFields replyTo { id } commit { oid } originalCommit { oid }"

function Assert-CompleteConnection {
    param($Connection, [string]$Label)
    if ($null -eq $Connection -or $null -eq $Connection.nodes -or $Connection.nodes -isnot [array] -or
        $null -eq $Connection.pageInfo -or $Connection.pageInfo.hasNextPage -isnot [bool]) { throw "Missing or malformed GitHub $Label connection." }
    if ($Connection.pageInfo.hasNextPage) { throw "Incomplete GitHub $Label pagination." }
    if ($null -ne $Connection.totalCount -and $Connection.totalCount -ne @($Connection.nodes).Count) { throw "Incomplete GitHub $Label count." }
}

function Get-Connection {
    param([string]$Kind, [string]$Fields, [string]$ThreadId)
    $nodes = [System.Collections.Generic.List[object]]::new()
    $cursor = $null
    $seen = @{}
    do {
        if ($ThreadId) {
            $query = 'query($id:ID!,$endCursor:String) { node(id:$id) { ... on PullRequestReviewThread { comments(first:100,after:$endCursor) { nodes { ' + $Fields + ' } pageInfo { hasNextPage endCursor } } } } }'
            $args = @('api', 'graphql', '--hostname', $HostName, '-f', "query=$query", '-f', "id=$ThreadId")
        } else {
            $query = 'query($owner:String!,$name:String!,$number:Int!,$endCursor:String) { repository(owner:$owner,name:$name) { nameWithOwner url pullRequest(number:$number) { number ' + $Kind + '(first:100,after:$endCursor) { nodes { ' + $Fields + ' } pageInfo { hasNextPage endCursor } } } } }'
            $args = @('api', 'graphql', '--hostname', $HostName, '-f', "query=$query", '-f', "owner=$owner", '-f', "name=$name", '-F', "number=$PullRequestId")
        }
        if ($cursor) { $args += @('-f', "endCursor=$cursor") }
        $response = Invoke-ReviewGhJson $args
        if ($response.errors) { throw 'GitHub GraphQL returned errors; discussion capture is incomplete.' }
        if ($ThreadId) { $connection = $response.data.node.comments }
        else {
            $repository = $response.data.repository
            if ($repository.nameWithOwner -ne $RepositoryFullName -or $repository.url -ne "https://$HostName/$RepositoryFullName" -or
                $repository.pullRequest.number -ne $PullRequestId) { throw 'GitHub discussion repository/PR identity mismatch.' }
            $connection = $repository.pullRequest.$Kind
        }
        if ($null -eq $connection.nodes -or $connection.nodes -isnot [array] -or $connection.pageInfo.hasNextPage -isnot [bool]) { throw 'GitHub discussion response is incomplete.' }
        foreach ($node in $connection.nodes) { $nodes.Add($node) }
        $cursor = $connection.pageInfo.endCursor
        if ($connection.pageInfo.hasNextPage) {
            if (!$cursor -or $seen.ContainsKey($cursor)) { throw 'GitHub discussion pagination did not advance.' }
            $seen[$cursor] = $true
        }
    } while ($connection.pageInfo.hasNextPage)
    return [pscustomobject]@{ nodes = @($nodes.ToArray()); pageInfo = [pscustomobject]@{ hasNextPage = $false } }
}

if ($RawResponsePath) {
    $response = Get-Content -LiteralPath $RawResponsePath -Raw | ConvertFrom-Json
    if ($response.errors) { throw 'GitHub MCP returned errors; discussion capture is incomplete.' }
    $repository = if ($response.data) { $response.data.repository } else { $response.repository }
    if ($repository.nameWithOwner -ne $RepositoryFullName -or $repository.url -ne "https://$HostName/$RepositoryFullName" -or
        $repository.pullRequest.number -ne $PullRequestId) { throw 'GitHub discussion repository/PR identity mismatch.' }
    $discussion = $repository.pullRequest
    $source = 'github_mcp'
} else {
    $discussion = [pscustomobject]@{
        comments = Get-Connection 'comments' $commentFields
        reviews = Get-Connection 'reviews' "$commentFields state"
        reviewThreads = Get-Connection 'reviewThreads' $threadFields
    }
    foreach ($thread in $discussion.reviewThreads.nodes) {
        $thread | Add-Member -NotePropertyName comments -NotePropertyValue (Get-Connection 'comments' $replyFields $thread.id) -Force
    }
    $source = 'github_cli'
}
foreach ($kind in @('comments', 'reviews', 'reviewThreads')) { Assert-CompleteConnection $discussion.$kind $kind }

function Convert-Comment {
    param($Comment)
    if (!$Comment.id -or $null -eq $Comment.body) { throw 'GitHub discussion entry lacks an ID or body.' }
    return [ordered]@{
        id = $Comment.id; parent_comment_id = $Comment.replyTo.id
        author = [string]$Comment.author.login; content = [string]$Comment.body
        published_at = $Comment.createdAt; updated_at = $Comment.updatedAt; type = 'text'; url = $Comment.url
        commit = $Comment.commit.oid; original_commit = $Comment.originalCommit.oid
    }
}
$threads = @(
    foreach ($kind in @('comments', 'reviews')) {
        foreach ($entry in $discussion.$kind.nodes) {
            if (!$entry.id -or $null -eq $entry.body) { throw 'GitHub discussion entry lacks an ID or body.' }
            if ($kind -eq 'reviews' -and $entry.state -eq 'PENDING') { continue }
            if ([string]::IsNullOrWhiteSpace($entry.body)) { continue }
            [ordered]@{
                id = $entry.id; kind = if ($kind -eq 'reviews') { 'review_summary' } else { 'conversation' }
                status = $entry.state; source_status = $entry.state; url = $entry.url
                context = $null; pull_request_context = $null; comments = @((Convert-Comment $entry))
            }
        }
    }
    foreach ($thread in $discussion.reviewThreads.nodes) {
        if (!$thread.id -or $thread.isResolved -isnot [bool] -or $thread.isOutdated -isnot [bool]) { throw 'GitHub thread lacks its ID or resolution/outdated state.' }
        Assert-CompleteConnection $thread.comments 'thread comments'
        $comments = @($thread.comments.nodes | ForEach-Object { Convert-Comment $_ })
        if (!$comments.Count) { continue }
        [ordered]@{
            id = $thread.id; kind = 'inline_review'; status = if ($thread.isResolved) { 'resolved' } else { 'open' }
            context = [ordered]@{
                file_path = $thread.path; line = $thread.line; original_line = $thread.originalLine
                start_line = $thread.startLine; original_start_line = $thread.originalStartLine
                diff_side = $thread.diffSide; start_diff_side = $thread.startDiffSide
            }
            pull_request_context = [ordered]@{ is_outdated = $thread.isOutdated; is_resolved = $thread.isResolved; resolved_by = $thread.resolvedBy.login }
            comments = $comments
        }
    }
)
$snapshot = [ordered]@{
    schema_version = 1; provider = 'github'; provider_host = $HostName; repository_full_name = $RepositoryFullName
    pull_request_id = $PullRequestId; captured_at = [DateTime]::UtcNow.ToString('o'); source = $source
    capabilities = [ordered]@{ complete = $true; conversation_comments = $true; review_summaries = $true; inline_threads = $true; thread_resolution = $true; outdated_locations = $true }
    threads = $threads
}
if (!(Test-Path -LiteralPath (Split-Path -Parent $OutputPath) -PathType Container)) { throw 'OutputPath parent directory does not exist.' }
[IO.File]::WriteAllText($OutputPath, ($snapshot | ConvertTo-Json -Depth 30), [Text.UTF8Encoding]::new($false))
$snapshot | ConvertTo-Json -Depth 30 -Compress
