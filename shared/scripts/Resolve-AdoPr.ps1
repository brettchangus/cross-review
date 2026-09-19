[CmdletBinding(DefaultParameterSetName = 'Cli')]
param(
    [Parameter(ParameterSetName = 'Cli')]
    [ValidateRange(1, [int]::MaxValue)]
    [int]$PullRequestId,

    [Parameter(ParameterSetName = 'Cli')]
    [switch]$AllowNoMatch,

    [Parameter(Mandatory, ParameterSetName = 'Mcp')]
    [string]$MetadataPath,

    [Parameter(Mandatory, ParameterSetName = 'Local')]
    [switch]$LocalOnly
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function Assert-Text {
    param(
        $Value,
        [Parameter(Mandatory)][string]$Name
    )

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        throw "Azure DevOps returned no $Name."
    }
    return $text
}

function Get-PropertyValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string[]]$Names
    )

    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }
    return $null
}

function Invoke-GitText {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$FailureMessage
    )

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage $($output -join [Environment]::NewLine)"
    }
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    return (($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Invoke-GitOptionalText {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $output = @(& git @Arguments 2>$null)
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Get-SanitizedRemoteUrl {
    param([Parameter(Mandatory)][string]$RemoteUrl)

    $text = $RemoteUrl.Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }

    $uri = $null
    if ([Uri]::TryCreate($text, [UriKind]::Absolute, [ref]$uri) -and -not $uri.IsFile) {
        $builder = [UriBuilder]::new($uri)
        $builder.UserName = ''
        $builder.Password = ''
        $builder.Query = ''
        $builder.Fragment = ''
        return $builder.Uri.AbsoluteUri
    }

    if ($text -notmatch '^[A-Za-z]:[\\/]' -and $text -match '^(?:[^@/\\]+@)?([^:/\\]+):(.+)$') {
        $hostName = $Matches[1]
        $remotePath = $Matches[2].TrimStart('/')
        return ('ssh://{0}/{1}' -f $hostName, $remotePath)
    }

    return $text
}

function Assert-GitBranchRef {
    param($Value, [Parameter(Mandatory)][string]$Name)

    $ref = Assert-Text $Value $Name
    if (-not $ref.StartsWith('refs/heads/', [System.StringComparison]::Ordinal) -or $ref -match '[\x00-\x20\x7f]') {
        throw "Azure DevOps returned an invalid $Name."
    }
    & git check-ref-format $ref 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Azure DevOps returned an invalid $Name." }
    return $ref
}

function ConvertTo-CanonicalPullRequestStatus {
    param($Value)

    if ($null -eq $Value) { throw 'Azure DevOps returned no PR status.' }
    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($Value -is [string] -or $Value -is [ValueType]) {
        $candidates.Add(([string]$Value).Trim())
    } else {
        foreach ($propertyName in @('name', 'displayName', 'value', 'id')) {
            $property = $Value.PSObject.Properties[$propertyName]
            if ($null -ne $property -and $null -ne $property.Value) {
                $candidates.Add(([string]$property.Value).Trim())
            }
        }
        $candidates.Add(([string]$Value).Trim())
    }

    foreach ($candidate in $candidates) {
        switch ($candidate.ToLowerInvariant()) {
            '0' { return 'notSet' }
            'notset' { return 'notSet' }
            'not set' { return 'notSet' }
            '1' { return 'active' }
            'active' { return 'active' }
            '2' { return 'abandoned' }
            'abandoned' { return 'abandoned' }
            '3' { return 'completed' }
            'completed' { return 'completed' }
            '4' { return 'all' }
            'all' { return 'all' }
        }
    }

    $displayValue = @($candidates | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1)
    if ($displayValue.Count -eq 0) { throw 'Azure DevOps returned no PR status.' }
    return [string]$displayValue[0]
}

function Get-AdoRemoteContext {
    param([Parameter(Mandatory)][string]$RemoteUrl)

    $organization = $null
    $project = $null
    $repository = $null

    if ($RemoteUrl -match '^(?:ssh://)?(?:git@)?ssh\.dev\.azure\.com(?::\d+)?(?::v3|/v3)/([^/]+)/([^/]+)/(.+?)(?:\.git)?$') {
        $organization = [Uri]::UnescapeDataString($Matches[1])
        $project = [Uri]::UnescapeDataString($Matches[2])
        $repository = [Uri]::UnescapeDataString($Matches[3])
    } else {
        try { $uri = [Uri]$RemoteUrl }
        catch { throw "Origin is not a recognized Azure DevOps URL: '$RemoteUrl'." }
        $segments = @($uri.AbsolutePath.Trim('/') -split '/' | ForEach-Object { [Uri]::UnescapeDataString($_) })
        if ($uri.Host -ieq 'dev.azure.com' -and $segments.Count -ge 4 -and $segments[2] -eq '_git') {
            $organization = $segments[0]
            $project = $segments[1]
            $repository = $segments[3]
        } elseif ($uri.Host -match '^([^.]+)\.visualstudio\.com$' -and $segments.Count -ge 3 -and $segments[1] -eq '_git') {
            $organization = $Matches[1]
            $project = $segments[0]
            $repository = $segments[2]
        }
    }

    if ([string]::IsNullOrWhiteSpace($organization) -or [string]::IsNullOrWhiteSpace($project) -or [string]::IsNullOrWhiteSpace($repository)) {
        throw "Origin is not a recognized Azure DevOps repository URL: '$RemoteUrl'."
    }
    $repository = $repository -replace '\.git$', ''
    return [pscustomobject]@{
        organization = $organization
        organization_url = "https://dev.azure.com/$organization"
        project = $project
        repository = $repository
        origin_url = Get-SanitizedRemoteUrl $RemoteUrl
    }
}

$repositoryRoot = Invoke-GitText @('rev-parse', '--show-toplevel') 'Cannot resolve the repository root.'
$localBranch = Invoke-GitText @('-C', $repositoryRoot, 'branch', '--show-current') 'Cannot resolve the current local branch.'
if ([string]::IsNullOrWhiteSpace($localBranch)) {
    throw 'Cannot resolve the current local branch. Detached HEAD is not supported.'
}
$localHead = Invoke-GitText @('-C', $repositoryRoot, 'rev-parse', 'HEAD') 'Cannot resolve the local HEAD commit.'
$rawOriginUrl = Invoke-GitOptionalText @('-C', $repositoryRoot, 'remote', 'get-url', 'origin')
$originUrl = if ([string]::IsNullOrWhiteSpace($rawOriginUrl)) { $null } else { Get-SanitizedRemoteUrl $rawOriginUrl }
$expectedSourceRef = "refs/heads/$localBranch"

if ($PSCmdlet.ParameterSetName -eq 'Local') {
    $repositoryName = Split-Path -Leaf $repositoryRoot
    $repositoryUrl = ''
    $repositoryId = ''
    $projectName = ''
    $organizationUrl = ''

    if (-not [string]::IsNullOrWhiteSpace($originUrl)) {
        try {
            $localAdoContext = Get-AdoRemoteContext $originUrl
            $repositoryId = "ado://$($localAdoContext.organization)/$($localAdoContext.project)/$($localAdoContext.repository)"
            $repositoryName = $localAdoContext.repository
            $projectName = $localAdoContext.project
            $organizationUrl = $localAdoContext.organization_url
        } catch {
            $normalizedRemote = $originUrl.Trim().TrimEnd('/') -replace '\.git$', ''
            $repositoryId = "remote:$normalizedRemote"
            $remotePath = $normalizedRemote -replace '\\', '/'
            $remoteSegments = @($remotePath -split '[:/]' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
            if ($remoteSegments.Count -gt 0) { $repositoryName = $remoteSegments[-1] }
        }
        $repositoryUrl = $originUrl
    } else {
        $rootCommits = Invoke-GitText @('-C', $repositoryRoot, 'rev-list', '--max-parents=0', 'HEAD') 'Cannot resolve the repository root commit.'
        $rootFingerprintInput = (@($rootCommits -split '\r?\n' | Where-Object { $_ } | Sort-Object) -join "`n")
        $sha256 = [System.Security.Cryptography.SHA256]::Create()
        try {
            $hashBytes = $sha256.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($rootFingerprintInput))
            $rootFingerprint = ([BitConverter]::ToString($hashBytes)).Replace('-', '').ToLowerInvariant()
        } finally {
            $sha256.Dispose()
        }
        $repositoryId = "local-root:$rootFingerprint"
    }

    [ordered]@{
        operation = 'local_identity'
        found = $false
        repository_id = $repositoryId
        repository_name = $repositoryName
        repository_url = $repositoryUrl
        project_id = ''
        project_name = $projectName
        organization_url = $organizationUrl
        local_branch = $localBranch
        local_head_commit = $localHead
        local_origin_url = $repositoryUrl
        local_repository_name = $repositoryName
        local_project_name = $projectName
        metadata_source = 'not_used'
    } | ConvertTo-Json -Depth 6 -Compress
    return
}

if ([string]::IsNullOrWhiteSpace($originUrl)) {
    throw "Cannot resolve the 'origin' remote required for Azure DevOps PR discovery."
}
$adoContext = Get-AdoRemoteContext $originUrl
$localRepositoryId = "ado://$($adoContext.organization)/$($adoContext.project)/$($adoContext.repository)"

$metadataSource = 'azure-cli-fallback'
if ($PSCmdlet.ParameterSetName -eq 'Mcp') {
    if (-not (Test-Path -LiteralPath $MetadataPath -PathType Leaf)) { throw "MCP metadata file not found: '$MetadataPath'." }
    try { $pr = Get-Content -LiteralPath $MetadataPath -Raw | ConvertFrom-Json }
    catch { throw "MCP metadata is not valid JSON: $($_.Exception.Message)" }
    $metadataSource = 'azure-devops-mcp'
} elseif ($PSBoundParameters.ContainsKey('PullRequestId')) {
    $raw = @(& az repos pr show --id $PullRequestId --organization $adoContext.organization_url --output json --only-show-errors 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI could not retrieve PR #${PullRequestId}: $($raw -join [Environment]::NewLine)"
    }
    $pr = ($raw -join [Environment]::NewLine) | ConvertFrom-Json
} else {
    $raw = @(& az repos pr list --organization $adoContext.organization_url --project $adoContext.project --repository $adoContext.repository --status active --source-branch $localBranch --top 2 --output json --only-show-errors 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI could not list active PRs for '$localBranch': $($raw -join [Environment]::NewLine)"
    }
    $prMatches = @(($raw -join [Environment]::NewLine) | ConvertFrom-Json)
    if ($prMatches.Count -eq 0) {
        if ($AllowNoMatch) {
            [ordered]@{
                operation = 'pr_lookup'
                found = $false
                repository_id = $localRepositoryId
                repository_name = $adoContext.repository
                repository_url = $originUrl
                project_id = ''
                project_name = $adoContext.project
                organization_url = $adoContext.organization_url
                local_branch = $localBranch
                local_head_commit = $localHead
                local_origin_url = $originUrl
                local_repository_name = $adoContext.repository
                local_project_name = $adoContext.project
                metadata_source = $metadataSource
            } | ConvertTo-Json -Depth 6 -Compress
            return
        }
        throw "No active Azure DevOps PR was found for '$expectedSourceRef' in '$($adoContext.project)/$($adoContext.repository)'."
    }
    if ($prMatches.Count -gt 1) {
        $ids = ($prMatches | ForEach-Object { Get-PropertyValue $_ @('pullRequestId', 'id') }) -join ', '
        throw "Multiple active Azure DevOps PRs match '$expectedSourceRef' in '$($adoContext.project)/$($adoContext.repository)' (IDs: $ids). Specify 'pr <id>'."
    }
    $pr = $prMatches[0]
}

$idText = Assert-Text (Get-PropertyValue $pr @('pullRequestId', 'id')) 'pull-request ID'
$parsedId = 0
if (-not [int]::TryParse($idText, [ref]$parsedId) -or $parsedId -le 0) {
    throw "Azure DevOps returned an invalid pull-request ID: '$idText'."
}
$status = ConvertTo-CanonicalPullRequestStatus (Get-PropertyValue $pr @('status'))
$sourceRef = Assert-GitBranchRef (Get-PropertyValue $pr @('sourceRefName', 'sourceRef')) 'sourceRefName'
$targetRef = Assert-GitBranchRef (Get-PropertyValue $pr @('targetRefName', 'targetRef')) 'targetRefName'

if (-not [string]::Equals($status, 'active', [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "PR #$parsedId is '$status', not active."
}
if (-not [string]::Equals($sourceRef, $expectedSourceRef, [System.StringComparison]::Ordinal)) {
    throw "Branch safety check failed. PR source is '$sourceRef'; local branch is '$localBranch' (expected '$expectedSourceRef')."
}

$repository = Get-PropertyValue $pr @('repository')
if ($null -eq $repository) { throw 'Azure DevOps returned no repository metadata.' }
$returnedRepositoryName = Assert-Text (Get-PropertyValue $repository @('name')) 'repository name'
if (-not [string]::Equals($returnedRepositoryName, $adoContext.repository, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Repository safety check failed. PR repository is '$returnedRepositoryName'; local origin repository is '$($adoContext.repository)'."
}
$project = Get-PropertyValue $repository @('project')
$returnedProjectName = if ($null -ne $project) { [string](Get-PropertyValue $project @('name')) } else { '' }
if ([string]::IsNullOrWhiteSpace($returnedProjectName)) { $returnedProjectName = $adoContext.project }
if (-not [string]::Equals($returnedProjectName, $adoContext.project, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Repository safety check failed. PR project is '$returnedProjectName'; local origin project is '$($adoContext.project)'."
}

$sourceCommitObject = Get-PropertyValue $pr @('lastMergeSourceCommit', 'sourceCommit')
$targetCommitObject = Get-PropertyValue $pr @('lastMergeTargetCommit', 'targetCommit')
$repositoryUrl = [string](Get-PropertyValue $repository @('webUrl', 'url'))
if ([string]::IsNullOrWhiteSpace($repositoryUrl)) { $repositoryUrl = $originUrl }
$repositoryUrl = Get-SanitizedRemoteUrl $repositoryUrl

$result = [ordered]@{
    operation = 'pr_lookup'
    found = $true
    pull_request_id = $parsedId
    title = [string](Get-PropertyValue $pr @('title'))
    status = $status
    repository_id = Assert-Text (Get-PropertyValue $repository @('id')) 'repository ID'
    repository_name = $returnedRepositoryName
    repository_url = Assert-Text $repositoryUrl 'repository URL'
    project_id = if ($null -ne $project) { [string](Get-PropertyValue $project @('id')) } else { '' }
    project_name = $returnedProjectName
    organization_url = $adoContext.organization_url
    source_ref = $sourceRef
    target_ref = $targetRef
    source_commit = if ($null -ne $sourceCommitObject) { [string](Get-PropertyValue $sourceCommitObject @('commitId', 'id')) } else { '' }
    target_commit = if ($null -ne $targetCommitObject) { [string](Get-PropertyValue $targetCommitObject @('commitId', 'id')) } else { '' }
    local_branch = $localBranch
    local_head_commit = $localHead
    local_origin_url = $originUrl
    local_repository_name = $adoContext.repository
    local_project_name = $adoContext.project
    metadata_source = $metadataSource
}

$result | ConvertTo-Json -Depth 6 -Compress
