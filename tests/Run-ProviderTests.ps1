[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$start = (Get-Location).Path
$root = Join-Path ([IO.Path]::GetTempPath()) ('cross-review-provider-tests-' + [Guid]::NewGuid().ToString('N'))
$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
$repository = Split-Path -Parent $PSScriptRoot
$passed = 0; $failed = 0
$oldHost = $env:GH_HOST
function Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Fail([scriptblock]$Action, [string]$Message) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -like "*$Message*") { return }; throw }
    throw "Expected failure: $Message"
}
function Save([string]$Path, $Value) { [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 35), [Text.UTF8Encoding]::new($false)) }
function Fixture-Git([string[]]$Arguments) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) { throw "Fixture Git failed: $($result -join ' ')" }
    return (($result | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n").Trim()
}
function Connection([object[]]$Nodes = @()) { return [pscustomobject]@{ nodes = @($Nodes); pageInfo = @{ hasNextPage = $false; endCursor = $null } } }
function Comment([string]$Id, [string]$Body) { return [pscustomobject]@{ id = $Id; body = $Body; author = @{ login = 'reviewer' }; url = "https://github.com/owner/repo/pull/42#$Id" } }
function Metadata {
    return [pscustomobject]@{
        number = 42; state = 'open'; title = 'Fixture'; draft = $true; html_url = 'https://github.com/owner/repo/pull/42'
        base = @{ ref = 'develop'; sha = $global:CrossReviewProviderTestSha; repo = @{ full_name = 'owner/repo' } }
        head = @{ ref = 'feature/sample'; sha = $global:CrossReviewProviderTestSha; repo = @{ full_name = 'owner/repo' } }
    }
}
function Discussion {
    $reply = Comment 'reply' 'Agreed'; $reply | Add-Member replyTo @{ id = 'inline' }
    $review = Comment 'review' 'Review summary'; $review | Add-Member state 'CHANGES_REQUESTED'
    return [pscustomobject]@{ data = @{ repository = @{
        nameWithOwner = 'owner/repo'; url = 'https://github.com/owner/repo'
        pullRequest = @{ number = 42
            comments = Connection @((Comment 'general' 'Conversation'))
            reviews = Connection @($review)
            reviewThreads = Connection @([pscustomobject]@{
                id = 'thread'; isResolved = $true; isOutdated = $true; path = 'app.ps1'; line = 8; originalLine = 5; diffSide = 'RIGHT'
                comments = Connection @((Comment 'inline' 'Check null'), $reply)
            })
        }
    } } }
}
New-Item -ItemType Directory -Path $root | Out-Null
try {
    $env:GH_HOST = $null
    $installed = Join-Path $root 'installed/cross-review'
    & (Join-Path $repository 'Install-Skill.ps1') -HostApp Claude -DestinationPath $installed | Out-Null
    $scripts = Join-Path $installed 'scripts'
    $repo = Join-Path $root 'repo'; New-Item -ItemType Directory $repo | Out-Null
    Fixture-Git @('-C', $repo, 'init', '-b', 'feature/sample') | Out-Null
    Fixture-Git @('-C', $repo, 'config', 'user.name', 'Fixture') | Out-Null
    Fixture-Git @('-C', $repo, 'config', 'user.email', 'fixture@example.invalid') | Out-Null
    $tree = Fixture-Git @('-C', $repo, 'write-tree')
    # Fixture objects are isolated; never commit or push the working repository.
    $script:sha = Fixture-Git @('-C', $repo, 'commit-tree', $tree, '-m', 'Fixture tree')
    $global:CrossReviewProviderTestSha = $sha
    Fixture-Git @('-C', $repo, 'update-ref', 'refs/heads/feature/sample', $sha) | Out-Null
    Fixture-Git @('-C', $repo, 'branch', 'develop') | Out-Null
    Set-Location -LiteralPath $repo
    $resolve = Join-Path $scripts 'Resolve-ReviewPr.ps1'
    $metadataPath = Join-Path $root 'metadata.json'; Save $metadataPath (Metadata)
    $rawPath = Join-Path $root 'discussion.json'; Save $rawPath (Discussion)
    $snapshotPath = Join-Path $root 'snapshot.json'
    $comments = Join-Path $scripts 'Get-PrCommentSnapshot.ps1'
    Case 'local-no-remote' {
        $c = & $resolve -LocalOnly | ConvertFrom-Json
        if ($c.provider -ne 'local' -or $c.repository_url -ne '' -or $c.repository_id -notlike 'local-root:*') { throw 'Wrong local identity.' }
    }
    Case 'github-https-sanitization' {
        Fixture-Git @('remote', 'add', 'origin', 'https://user:secret@github.com/Owner/Repo.git?token=secret#fragment') | Out-Null
        $c = & $resolve -LocalOnly | ConvertFrom-Json
        if ($c.provider -ne 'github' -or $c.provider_host -ne 'github.com' -or $c.repository_id -ne 'github://github.com/owner/repo' -or ($c | ConvertTo-Json -Depth 10) -match 'secret') { throw 'Identity/token sanitization failed.' }
    }
    Case 'native-git-optional-stderr-and-preference' {
        . (Join-Path $scripts 'ReviewProvider.ps1')
        $optional = Invoke-ReviewGit @('symbolic-ref', 'refs/remotes/origin/HEAD') -Optional
        if ($optional -ne '' -or $ErrorActionPreference -ne 'Stop') { throw 'Optional stderr escaped or changed the caller preference.' }
        Fail { Invoke-ReviewGit @('symbolic-ref', 'refs/remotes/origin/HEAD') -FailureMessage 'Expected native failure.' } 'Expected native failure'
        if ($ErrorActionPreference -ne 'Stop') { throw 'Failed native command changed the caller preference.' }
        $c = & $resolve -LocalOnly | ConvertFrom-Json
        if ($c.provider -ne 'github' -or $c.default_ref -ne '') { throw 'Missing origin/HEAD blocked local identity.' }
    }
    Case 'native-git-failure-names-subcommand' {
        . (Join-Path $scripts 'ReviewProvider.ps1')
        Fail { Invoke-ReviewGit @('-C', $repo, 'ls-remote', '--', 'https://user:secret@invalid.invalid/owner/repo.git', 'HEAD') } 'Git ls-remote failed.'
        try { Invoke-ReviewGit @('-C', $repo, 'ls-remote', '--', 'https://user:secret@invalid.invalid/owner/repo.git', 'HEAD') }
        catch { if ($_.Exception.Message -match 'secret|-C') { throw 'Git failure leaked credentials or named the -C option.' } }
    }
    Case 'file-remote-has-no-host' {
        . (Join-Path $scripts 'ReviewProvider.ps1')
        $fileUrl = 'file:///D:/repos/foo.git'
        $identity = Get-ReviewRemoteIdentity $fileUrl
        if ((Get-ReviewSafeUrl $fileUrl) -ne $fileUrl -or $identity.host -ne '' -or $identity.url -ne $fileUrl) { throw 'File remote was rewritten as an SSH host.' }
    }
    Case 'github-ssh-same-identity' {
        Fixture-Git @('remote', 'set-url', 'origin', 'git@github.com:owner/repo.git') | Out-Null
        $c = & $resolve -LocalOnly | ConvertFrom-Json
        if ($c.repository_id -ne 'github://github.com/owner/repo') { throw 'SSH identity changed.' }
    }
    Case 'github-full-metadata' {
        $p = & $resolve -PullRequestId 42 -MetadataPath $metadataPath | ConvertFrom-Json
        if (!$p.found -or !$p.draft -or $p.target_ref -ne 'refs/heads/develop' -or $p.metadata_transport -ne 'mcp') { throw 'PR metadata lost fields.' }
    }
    Case 'github-metadata-safety-guards' {
        foreach ($kind in @('number','state','target','source','branch','sha')) {
            $p = Metadata
            switch ($kind) {
                number { $p.number = 43 }
                state { $p.state = 'closed' }
                target { $p.base.repo.full_name = 'wrong/repo' }
                source { $p.head.repo.full_name = 'wrong/repo' }
                branch { $p.head.ref = 'other' }
                sha { $p.head.sha = 'invalid' }
            }
            Save $metadataPath $p
            Fail { & $resolve -PullRequestId 42 -MetadataPath $metadataPath } '*'
        }
        Save $metadataPath (Metadata)
    }
    Case 'github-pr-url-parser' {
        $args = & (Join-Path $scripts 'Resolve-ReviewArguments.ps1') -ReviewArguments @('pr','https://github.com/owner/repo/pull/42','--effort','high') | ConvertFrom-Json
        if ($args.pull_request_id -ne 42 -or !$args.pr_url -or $args.effort -ne 'high') { throw 'URL/effort parsing failed.' }
        foreach ($url in @('https://user:secret@github.com/owner/repo/pull/42','https://github.com/owner/repo/pull/42?token=x','https://github.com/owner/repo/pull/0')) {
            Fail { & (Join-Path $scripts 'Resolve-ReviewArguments.ps1') -ReviewArguments @('pr',$url) } 'PR URL'
        }
    }
    Case 'github-fork-upstream' {
        Fixture-Git @('remote', 'set-url', 'origin', 'https://github.com/contributor/fork.git') | Out-Null
        Fixture-Git @('remote', 'add', 'upstream', 'https://github.com/owner/repo.git') | Out-Null
        $p = Metadata; $p.head.repo.full_name = 'contributor/fork'; Save $metadataPath $p
        $resolved = & $resolve -PrUrl 'https://github.com/owner/repo/pull/42' -MetadataPath $metadataPath | ConvertFrom-Json
        if ($resolved.remote_name -ne 'upstream' -or $resolved.source_repository -ne 'contributor/fork' -or $resolved.repository_id -ne 'github://github.com/owner/repo') { throw 'Fork identity failed.' }
        Fail { & $resolve -PrUrl 'https://github.com/unrelated/repo/pull/42' -MetadataPath $metadataPath } 'does not match'
        Fixture-Git @('remote', 'remove', 'upstream') | Out-Null
        Fixture-Git @('remote', 'set-url', 'origin', 'https://github.com/owner/repo.git') | Out-Null
        Save $metadataPath (Metadata)
    }
    Case 'github-url-valued-fork-tracking' {
        try {
            Fixture-Git @('config', 'branch.feature/sample.remote', 'https://github.com/contributor/fork.git') | Out-Null
            Fixture-Git @('config', 'branch.feature/sample.merge', 'refs/heads/feature/sample') | Out-Null
            $c = & $resolve -LocalOnly | ConvertFrom-Json
            if ($c.provider -ne 'github' -or $c.remote_name -ne 'origin' -or $c.source_repository_full_name -ne 'contributor/fork' -or $c.source_branch -ne 'feature/sample') { throw 'URL tracking lost target provider or fork source.' }
            $p = Metadata; $p.head.repo.full_name = 'contributor/fork'; Save $metadataPath $p
            foreach ($parameters in @(@{ PullRequestId = 42 }, @{ PrUrl = 'https://github.com/owner/repo/pull/42' })) {
                $resolved = & $resolve @parameters -MetadataPath $metadataPath | ConvertFrom-Json
                if ($resolved.remote_name -ne 'origin' -or $resolved.source_repository -ne 'contributor/fork') { throw 'URL tracking failed PR validation.' }
            }
            # Revalidation must retain the URL-valued source even when the
            # explicit target is pinned to a named remote.
            $c = & $resolve -LocalOnly -RemoteName origin | ConvertFrom-Json
            if ($c.source_repository_full_name -ne 'contributor/fork') { throw 'Explicit target replaced fork source identity.' }
            Fixture-Git @('remote', 'add', 'fork', 'git@github.com:contributor/fork.git') | Out-Null
            $c = & $resolve -LocalOnly | ConvertFrom-Json
            if ($c.remote_name -ne 'fork') { throw 'URL tracking ignored its matching named remote.' }
        } finally {
            Fixture-Git @('config', '--unset', 'branch.feature/sample.remote') | Out-Null
            Fixture-Git @('config', '--unset', 'branch.feature/sample.merge') | Out-Null
            Fixture-Git @('remote', 'remove', 'fork') | Out-Null
            Save $metadataPath (Metadata)
        }
    }
    Case 'provider-insteadOf-aliases' {
        try {
            Fixture-Git @('config', 'url.https://github.com/.insteadOf', 'gh:') | Out-Null
            Fixture-Git @('remote', 'set-url', 'origin', 'gh:owner/repo.git') | Out-Null
            $c = & $resolve -LocalOnly | ConvertFrom-Json
            if ($c.provider -ne 'github' -or $c.repository_id -ne 'github://github.com/owner/repo') { throw 'GitHub alias lost canonical identity.' }
            $p = & $resolve -PullRequestId 42 -MetadataPath $metadataPath | ConvertFrom-Json
            if (!$p.found) { throw 'GitHub alias blocked PR resolution.' }
            Fixture-Git @('config', 'url.https://dev.azure.com/.insteadOf', 'ado:') | Out-Null
            Fixture-Git @('remote', 'set-url', 'origin', 'ado:org/project/_git/repo') | Out-Null
            $c = & $resolve -LocalOnly | ConvertFrom-Json
            $legacy = & (Join-Path $scripts 'Resolve-AdoPr.ps1') -LocalOnly | ConvertFrom-Json
            if ($c.provider -ne 'azure_devops' -or $c.organization_url -ne 'https://dev.azure.com/org' -or $c.repository_id -ne 'ado://org/project/repo' -or $legacy.repository_id -ne $c.repository_id) { throw 'Azure alias lost canonical identity/history compatibility.' }
        } finally {
            Fixture-Git @('config', '--unset', 'url.https://github.com/.insteadOf') | Out-Null
            Fixture-Git @('config', '--unset', 'url.https://dev.azure.com/.insteadOf') | Out-Null
            Fixture-Git @('remote', 'set-url', 'origin', 'https://github.com/owner/repo.git') | Out-Null
        }
    }
    Case 'enterprise-and-unknown-host' {
        Fixture-Git @('remote', 'set-url', 'origin', 'git@code.example.invalid:owner/repo.git') | Out-Null
        $c = & $resolve -LocalOnly | ConvertFrom-Json
        if ($c.provider -ne 'unknown') { throw 'Unknown provider was assumed GitHub.' }
        $env:GH_HOST = 'code.example.invalid'
        $c = & $resolve -LocalOnly | ConvertFrom-Json
        if ($c.provider -ne 'github' -or $c.provider_host -ne 'code.example.invalid') { throw 'Enterprise detection failed.' }
        $env:GH_HOST = $null
        Fixture-Git @('remote', 'set-url', 'origin', 'https://github.com/owner/repo.git') | Out-Null
    }
    Case 'tracking-remote-and-ambiguity' {
        Fixture-Git @('remote', 'rename', 'origin', 'first') | Out-Null
        Fixture-Git @('remote', 'add', 'second', 'https://github.com/other/repo.git') | Out-Null
        Fail { & $resolve -LocalOnly } 'ambiguous'
        Fixture-Git @('config', 'branch.feature/sample.remote', 'first') | Out-Null
        $c = & $resolve -LocalOnly | ConvertFrom-Json
        if ($c.remote_name -ne 'first') { throw 'Tracking remote ignored.' }
        Fixture-Git @('config', '--unset', 'branch.feature/sample.remote') | Out-Null
        Fixture-Git @('remote', 'remove', 'second') | Out-Null
        Fixture-Git @('remote', 'rename', 'first', 'origin') | Out-Null
    }
    Case 'azure-id-compatibility' {
        Fixture-Git @('remote', 'set-url', 'origin', 'https://dev.azure.com/org/project/_git/repo') | Out-Null
        $old = & (Join-Path $scripts 'Resolve-AdoPr.ps1') -LocalOnly | ConvertFrom-Json
        $new = & $resolve -LocalOnly | ConvertFrom-Json
        if ($new.provider -ne 'azure_devops' -or $new.repository_id -ne $old.repository_id) { throw 'Azure history identity changed.' }
        Fixture-Git @('remote', 'set-url', 'origin', 'https://github.com/owner/repo.git') | Out-Null
    }
    Case 'azure-organization-drift-stops-before-fetch' {
        $azurePath = Join-Path $root 'azure-metadata.json'
        $azureContextPath = Join-Path $root 'azure-context.json'
        $azureMetadata = @{ pullRequestId = 42; status = 'active'; sourceRefName = 'refs/heads/feature/sample'; targetRefName = 'refs/heads/develop'
            repository = @{ id = 'repo-id'; name = 'repo'; project = @{ id = 'project-id'; name = 'project' }; webUrl = 'https://dev.azure.com/original/project/_git/repo' }
            lastMergeSourceCommit = @{ commitId = $sha }; lastMergeTargetCommit = @{ commitId = $sha } }
        Save $azurePath $azureMetadata
        $global:CrossReviewProviderGitExecutable = (Get-Command git -CommandType Application | Select-Object -First 1).Source
        $global:CrossReviewProviderFetchCalls = 0
        try {
            Fixture-Git @('remote', 'set-url', 'origin', 'https://dev.azure.com/original/project/_git/repo') | Out-Null
            $p = & $resolve -PullRequestId 42 -MetadataPath $azurePath | ConvertFrom-Json
            Save $azureContextPath $p
            Fixture-Git @('remote', 'set-url', 'origin', 'https://dev.azure.com/other/project/_git/repo') | Out-Null
            function global:git {
                if ($args -contains 'fetch') {
                    $global:CrossReviewProviderFetchCalls++
                    $global:LASTEXITCODE = 1
                    return 'Unexpected fetch'
                }
                & $global:CrossReviewProviderGitExecutable @args
                $global:LASTEXITCODE = $LASTEXITCODE
            }
            Fail { & (Join-Path $scripts 'Get-ReviewPrScope.ps1') -ContextPath $azureContextPath } 'Azure organization/repository/project moved'
            if ($global:CrossReviewProviderFetchCalls) { throw 'Azure organization drift was detected only after fetching.' }
        } finally {
            if (Test-Path Function:\git) { Remove-Item Function:\git }
            Remove-Variable -Scope Global -Name CrossReviewProviderGitExecutable, CrossReviewProviderFetchCalls -ErrorAction SilentlyContinue
            Fixture-Git @('remote', 'set-url', 'origin', 'https://github.com/owner/repo.git') | Out-Null
        }
    }
    Case 'github-discussion-normalization' {
        & $comments -Provider github -PullRequestId 42 -RepositoryFullName 'owner/repo' -RawResponsePath $rawPath -OutputPath $snapshotPath | Out-Null
        $s = Get-Content $snapshotPath -Raw | ConvertFrom-Json
        $inline = $s.threads | Where-Object kind -eq 'inline_review'
        if ($s.provider -ne 'github' -or !$s.capabilities.complete -or $s.threads.Count -ne 3 -or
            !$inline.pull_request_context.is_outdated -or $inline.status -ne 'resolved' -or $inline.context.original_line -ne 5 -or
            $inline.comments[1].parent_comment_id -ne 'inline') { throw 'Discussion lost structure/state/replies.' }
    }
    Case 'github-discussion-incomplete-no-write' {
        $before = (Get-FileHash $snapshotPath).Hash
        foreach ($kind in @('comments','reviews','reviewThreads','replies','errors','identity')) {
            $d = Discussion
            switch ($kind) {
                replies { $d.data.repository.pullRequest.reviewThreads.nodes[0].comments.pageInfo.hasNextPage = $true }
                errors { $d | Add-Member errors @(@{ message = 'Access denied' }) }
                identity { $d.data.repository.pullRequest.number = 43 }
                default { $d.data.repository.pullRequest.$kind.pageInfo.hasNextPage = $true }
            }
            Save $rawPath $d
            Fail { & $comments -Provider github -PullRequestId 42 -RepositoryFullName 'owner/repo' -RawResponsePath $rawPath -OutputPath $snapshotPath } '*'
            if ((Get-FileHash $snapshotPath).Hash -ne $before) { throw 'Failed capture replaced the existing snapshot.' }
        }
        Save $rawPath (Discussion)
    }
    Case 'github-empty-discussion' {
        $d = Discussion
        foreach ($kind in @('comments','reviews','reviewThreads')) { $d.data.repository.pullRequest.$kind = Connection }
        Save $rawPath $d
        & $comments -Provider github -PullRequestId 42 -RepositoryFullName 'owner/repo' -RawResponsePath $rawPath -OutputPath $snapshotPath | Out-Null
        if (@((Get-Content $snapshotPath -Raw | ConvertFrom-Json).threads).Count) { throw 'Empty discussion contains threads.' }
        Save $rawPath (Discussion)
    }
    # CLI fakes return real API shapes. No network/authentication is required.
    $global:CrossReviewProviderTestghMode = 'metadata'; $global:CrossReviewProviderTestghCalls = [Collections.Generic.List[object]]::new()
    function global:gh {
        $global:CrossReviewProviderTestghCalls.Add(@($args))
        $global:LASTEXITCODE = 0
        if ($global:CrossReviewProviderTestghMode -eq 'failure') { $global:LASTEXITCODE = 1; return 'denied' }
        if ($global:CrossReviewProviderTestghMode -eq 'malformed') { return '{}' }
        if ($global:CrossReviewProviderTestghMode -eq 'metadata') {
            if ($args -contains '--paginate') {
                if ($global:CrossReviewProviderTestnoMatches) { return '[[]]' }
                $p = Metadata
                $pages = if ($global:CrossReviewProviderTestambiguous) { @(@($p), @($p)) } else { @(@($p), @()) }
                ConvertTo-Json -InputObject $pages -Depth 15 -Compress; return
            }
            Metadata | ConvertTo-Json -Depth 15 -Compress; return
        }
        $query = [string]($args | Where-Object { $_ -like 'query=*' })
        $after = [bool]($args | Where-Object { $_ -like 'endCursor=*' })
        $kind = if ($query -match 'reviewThreads\(') { 'reviewThreads' } elseif ($query -match 'reviews\(') { 'reviews' } else { 'comments' }
        $d = Discussion
        if ($query -match 'node\(id:') {
            $c = Connection @((Comment $(if ($after) { 'reply' } else { 'inline' }) 'Thread page'))
            $result = @{ data = @{ node = @{ comments = $c } } }
        } else {
            $c = $d.data.repository.pullRequest.$kind
            if ($after) { $c = Connection @() }
            $result = @{ data = @{ repository = @{ nameWithOwner = 'owner/repo'; url = 'https://github.com/owner/repo'; pullRequest = @{ number = 42; $kind = $c } } } }
        }
        if (!$after) { $c.pageInfo.hasNextPage = $true; $c.pageInfo.endCursor = 'next' }
        $result | ConvertTo-Json -Depth 35 -Compress
    }
    Case 'github-cli-discovery-pagination' {
        $p = & $resolve -AllowNoMatch | ConvertFrom-Json
        if (!$p.found -or $p.metadata_transport -ne 'cli' -or !$global:CrossReviewProviderTestghCalls.Count) { throw 'CLI discovery failed.' }
        $global:CrossReviewProviderTestnoMatches = $true
        $p = & $resolve -AllowNoMatch | ConvertFrom-Json
        if ($p.found) { throw 'No-match discovery failed.' }
        $global:CrossReviewProviderTestnoMatches = $false; $global:CrossReviewProviderTestambiguous = $true
        Fail { & $resolve -AllowNoMatch } 'Multiple'
        $global:CrossReviewProviderTestambiguous = $false
    }
    Case 'github-cli-auth-failure-is-not-empty' {
        $global:CrossReviewProviderTestghMode = 'failure'
        Fail { & $resolve -AllowNoMatch } 'request failed'
        Fail { & $comments -Provider github -PullRequestId 42 -RepositoryFullName 'owner/repo' -OutputPath $snapshotPath } 'request failed'
    }
    Case 'github-cli-malformed-discovery-is-not-empty' {
        $global:CrossReviewProviderTestghMode = 'malformed'
        Fail { & $resolve -AllowNoMatch } 'response is incomplete'
    }
    Case 'github-cli-paginates-every-connection-and-replies' {
        $global:CrossReviewProviderTestghMode = 'discussion'; $global:CrossReviewProviderTestghCalls.Clear()
        & $comments -Provider github -PullRequestId 42 -RepositoryFullName 'owner/repo' -OutputPath $snapshotPath | Out-Null
        $s = Get-Content $snapshotPath -Raw | ConvertFrom-Json
        if ($global:CrossReviewProviderTestghCalls.Count -ne 8 -or @($s.threads | Where-Object kind -eq 'inline_review')[0].comments.Count -ne 2) { throw 'Nested discussion pagination was skipped.' }
    }
    Case 'github-metrics-without-azure-project' {
        $ledger = @{ schema_version = 3; review_id = 'fixture'; review_mode = 'pull_request'; status = 'complete'
            repository = @{ provider = 'github'; host = 'github.com'; owner = 'owner'; id = 'github://github.com/owner/repo'; name = 'repo'; url = 'https://github.com/owner/repo' }
            pull_request = @{ id = 42; source_ref = 'refs/heads/feature/sample'; target_ref = 'refs/heads/develop'; source_commit = $sha; target_commit = $sha }
            local = @{ branch = 'feature/sample'; head_commit = $sha }; findings = @(); groups = @(); adjudication = @{ codex_disposition_overrides = @() }
        }
        $ledgerPath = Join-Path $root 'ledger.json'; Save $ledgerPath $ledger
        & (Join-Path $scripts 'Measure-ReviewEffectiveness.ps1') -LedgerPath $ledgerPath -OutputPath (Join-Path $root 'metrics.json') | Out-Null
    }
    Case 'github-history-preserves-and-validates-provider' {
        $run = Join-Path $root '.reviews/runs/provider-fixture'
        New-Item -ItemType Directory -Path $run | Out-Null
        Copy-Item -LiteralPath (Join-Path $root 'ledger.json') -Destination (Join-Path $run 'adjudication.json')
        Copy-Item -LiteralPath (Join-Path $root 'metrics.json') -Destination (Join-Path $run 'metrics.json')
        $ledger = Get-Content (Join-Path $run 'adjudication.json') -Raw | ConvertFrom-Json
        $context = [pscustomobject]@{
            schema_version = 3; review_id = $ledger.review_id; review_mode = $ledger.review_mode
            repository = $ledger.repository; pull_request = $ledger.pull_request; local = $ledger.local
            started_at = [DateTimeOffset]::UtcNow.AddSeconds(-20).ToString('o')
            run_directory = '.reviews/runs/provider-fixture'
            tooling = @{ pr_metadata = 'github_cli'; pr_metadata_transport = 'cli' }
            review_size = @{ has_changes = $true; review_units = 1 }; estimate = @{ seconds = 240 }
        }
        $contextPath = Join-Path $run 'run-context.json'; Save $contextPath $context
        [IO.File]::WriteAllText((Join-Path $run 'final.md'), 'Fixture report')
        $historyPath = Join-Path $root '.reviews/history.jsonl'
        $appendArgs = @{ LedgerPath = (Join-Path $run 'adjudication.json'); MetricsPath = (Join-Path $run 'metrics.json')
            RunContextPath = $contextPath; FinalReportPath = (Join-Path $run 'final.md'); HistoryPath = $historyPath }
        & (Join-Path $scripts 'Append-ReviewHistory.ps1') @appendArgs | Out-Null
        $entry = Get-Content $historyPath -Raw | ConvertFrom-Json
        if ($entry.repository.provider -ne 'github' -or $entry.repository.host -ne 'github.com' -or $entry.tooling.pr_metadata_transport -ne 'cli') { throw 'History lost provider/transport.' }
        $context.repository = $ledger.repository | ConvertTo-Json | ConvertFrom-Json
        $context.repository.host = 'wrong.example.invalid'; Save $contextPath $context
        Fail { & (Join-Path $scripts 'Append-ReviewHistory.ps1') @appendArgs } 'repository.host'
        $context.repository.host = 'github.com'
        $context.pull_request = $ledger.pull_request | ConvertTo-Json | ConvertFrom-Json
        $context.pull_request | Add-Member source_repository 'different/repo'; Save $contextPath $context
        Fail { & (Join-Path $scripts 'Append-ReviewHistory.ps1') @appendArgs } 'source_repository'
        if (@(Get-Content $historyPath).Count -ne 1) { throw 'Invalid context appended history.' }
    }
    Case 'provider-preflight-in-both-installed-hosts' {
        $codexInstall = Join-Path $root 'codex/cross-review'
        & (Join-Path $repository 'Install-Skill.ps1') -HostApp Codex -DestinationPath $codexInstall | Out-Null
        foreach ($hostSkill in @($installed, $codexInstall)) {
            $text = Get-Content (Join-Path $hostSkill 'SKILL.md') -Raw
            if ($text -notmatch 'Repository provider:' -or $text -notmatch 'provider-workflow.md' -or !(Test-Path (Join-Path $hostSkill 'scripts/Resolve-GitHubPr.ps1'))) { throw 'Installed host lacks provider workflow/preflight.' }
        }
    }
    Case 'default-branch-and-pr-fetch-consistency' {
        # Local Git mirror exercises real fetches without changing any checkout.
        $mirror = Join-Path $root 'mirror.git'
        Fixture-Git @('clone','--bare',$repo,$mirror) | Out-Null
        Fixture-Git @('--git-dir', $mirror, 'symbolic-ref', 'HEAD', 'refs/heads/develop') | Out-Null
        Fixture-Git @('--git-dir', $mirror, 'update-ref', 'refs/pull/42/head', $sha) | Out-Null
        Fixture-Git @('config', ('url.' + $mirror.Replace('\','/') + '.insteadOf'), 'https://github.com/owner/repo.git') | Out-Null
        $base = & (Join-Path $scripts 'Resolve-ReviewBase.ps1') | ConvertFrom-Json
        if ($base.target_ref -ne 'refs/heads/develop' -or $base.target_commit -ne $sha) { throw 'Actual default branch was ignored.' }
        $p = & $resolve -PullRequestId 42 -MetadataPath $metadataPath | ConvertFrom-Json
        $contextPath = Join-Path $root 'context.json'; Save $contextPath $p
        $scope = & (Join-Path $scripts 'Get-ReviewPrScope.ps1') -ContextPath $contextPath | ConvertFrom-Json
        if ($scope.source_commit -ne $sha -or $scope.source_local_ref -ne 'refs/cross-review/pr/42/head') { throw 'Wrong PR scope.' }
        # A URL-tracked fork keeps its source identity while refs are fetched
        # from origin, even when transport URLs are rewritten to local mirrors.
        try {
            Fixture-Git @('config', 'branch.feature/sample.remote', 'https://github.com/contributor/fork.git') | Out-Null
            Fixture-Git @('config', 'branch.feature/sample.merge', 'refs/heads/feature/sample') | Out-Null
            Fixture-Git @('config', '--add', ('url.' + $mirror.Replace('\','/') + '.insteadOf'), 'https://github.com/contributor/fork.git') | Out-Null
            $forkMetadata = Metadata; $forkMetadata.head.repo.full_name = 'contributor/fork'; Save $metadataPath $forkMetadata
            $forkContext = & $resolve -PrUrl 'https://github.com/owner/repo/pull/42' -MetadataPath $metadataPath | ConvertFrom-Json
            Save $contextPath $forkContext
            $scope = & (Join-Path $scripts 'Get-ReviewPrScope.ps1') -ContextPath $contextPath | ConvertFrom-Json
            if ($scope.source_commit -ne $sha -or $scope.source_repository -ne 'contributor/fork') { throw 'URL-tracked fork failed frozen-scope fetching.' }
        } finally {
            Fixture-Git @('config', '--unset', 'branch.feature/sample.remote') | Out-Null
            Fixture-Git @('config', '--unset', 'branch.feature/sample.merge') | Out-Null
            Fixture-Git @('config', '--unset', ('url.' + $mirror.Replace('\','/') + '.insteadOf'), '^https://github[.]com/contributor/fork[.]git$') | Out-Null
            Save $metadataPath (Metadata)
        }
        # GitHub base.sha stays at the base as of the last head push, so a
        # stale reported base must freeze the fetched tip rather than fail.
        $p.target_commit = 'e' * 40; Save $contextPath $p
        $scope = & (Join-Path $scripts 'Get-ReviewPrScope.ps1') -ContextPath $contextPath | ConvertFrom-Json
        if ($scope.target_commit -ne $sha) { throw 'Stale GitHub base.sha was not replaced by the fetched target tip.' }
        # Provider drift must be caught for Azure contexts too, not only GitHub.
        $azure = $p | ConvertTo-Json -Depth 8 | ConvertFrom-Json
        $azure.provider = 'azure_devops'; $azure.target_commit = $sha; Save $contextPath $azure
        Fail { & (Join-Path $scripts 'Get-ReviewPrScope.ps1') -ContextPath $contextPath } 'Repository or branch moved'
        $p.target_commit = $sha; $p.source_commit = 'f' * 40; Save $contextPath $p
        Fail { & (Join-Path $scripts 'Get-ReviewPrScope.ps1') -ContextPath $contextPath } 'PR moved'
        if ((Fixture-Git @('branch','--show-current')) -ne 'feature/sample') { throw 'Fetch switched branch.' }
    }
} finally {
    Set-Location -LiteralPath $start
    $env:GH_HOST = $oldHost
    if (Test-Path Function:\gh) { Remove-Item Function:\gh }
    Remove-Variable -Scope Global -Name CrossReviewProviderTestghMode, CrossReviewProviderTestghCalls, CrossReviewProviderTestnoMatches, CrossReviewProviderTestambiguous, CrossReviewProviderTestSha -ErrorAction SilentlyContinue
    $resolvedRoot = [IO.Path]::GetFullPath($root)
    if ($resolvedRoot.StartsWith($tempRoot.TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
    }
}
Write-Host "$passed provider tests passed, $failed failed"
if ($failed) { exit 1 }
