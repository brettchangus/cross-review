# Shared read-only Git and repository identity helpers. Dot-source this file.
function Invoke-ReviewGit {
    param([string[]]$Arguments, [switch]$Optional, [string]$FailureMessage)
    # Windows PowerShell treats redirected native stderr as ErrorRecords. Capture
    # those diagnostics without aborting before the native exit code is checked.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $result = @(& git @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($exitCode -ne 0) {
        if ($Optional) { return '' }
        # Name the subcommand rather than a leading global option such as -C, and
        # keep Git's diagnostic with any URL credentials redacted.
        $index = 0
        while ($index -lt $Arguments.Count -and $Arguments[$index].StartsWith('-')) { $index += if ($Arguments[$index] -ceq '-C') { 2 } else { 1 } }
        $command = if ($index -lt $Arguments.Count) { $Arguments[$index] } else { 'command' }
        $detail = (($result | ForEach-Object { [string]$_ }) -join ' ').Trim() -replace '(?<=://)[^/\s@]+@', ''
        $message = if ($FailureMessage) { $FailureMessage } else { "Git $command failed." }
        if ($detail) { $message += " $detail" }
        throw $message
    }
    $stdout = @($result | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    return (($stdout | ForEach-Object { [string]$_ }) -join "`n").Trim()
}

function Get-ReviewSafeUrl {
    param([string]$Url)
    if (!$Url) { return '' }
    $uri = $null
    if ([Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri)) {
        # Local filesystem remotes carry no host or credentials; never treat
        # file: as an scp-style host below.
        if ($uri.IsFile) { return $Url }
        $builder = [UriBuilder]::new($uri)
        $builder.UserName = ''; $builder.Password = ''; $builder.Query = ''; $builder.Fragment = ''
        return $builder.Uri.AbsoluteUri
    }
    if ($Url -notmatch '^[A-Za-z]:[\\/]' -and $Url -match '^(?:[^@/\\]+@)?([^:/\\]+):(.+)$') {
        return Get-ReviewSafeUrl "ssh://$($Matches[1])/$($Matches[2].TrimStart('/'))"
    }
    return $Url
}

function Get-ReviewRemoteIdentity {
    param([string]$Url, [string[]]$GitHubHost = @())
    $safe = Get-ReviewSafeUrl $Url
    $identity = [ordered]@{ provider = 'local'; host = ''; owner = ''; name = ''; full_name = ''; url = $safe }
    if (!$safe) { return [pscustomobject]$identity }
    $identity.provider = 'unknown'
    $uri = $null
    if (![Uri]::TryCreate($safe, [UriKind]::Absolute, [ref]$uri) -or $uri.IsFile) { return [pscustomobject]$identity }
    $identity.host = $uri.Host.ToLowerInvariant()
    $parts = @($uri.AbsolutePath.Trim('/') -split '/' | ForEach-Object { [Uri]::UnescapeDataString($_) })
    if (($uri.Host -eq 'dev.azure.com' -and $parts.Count -eq 4 -and $parts[2] -eq '_git') -or
        ($uri.Host -match '^[^.]+\.visualstudio\.com$' -and $parts.Count -eq 3 -and $parts[1] -eq '_git') -or
        ($uri.Host -eq 'ssh.dev.azure.com' -and $parts.Count -eq 4 -and $parts[0] -eq 'v3')) {
        $identity.provider = 'azure_devops'
        $identity.name = $parts[-1] -replace '\.git$', ''
    } elseif ($uri.Host -in @('github.com') + @($GitHubHost) + @($env:GH_HOST) -and $parts.Count -eq 2) {
        if ($parts[0] -notmatch '^[A-Za-z0-9_.-]+$' -or $parts[1] -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Invalid GitHub repository identity.' }
        $identity.provider = 'github'
        $identity.owner = $parts[0]
        $identity.name = $parts[1] -replace '\.git$', ''
        $identity.full_name = "$($identity.owner)/$($identity.name)"
        $identity.url = "https://$($identity.host)/$($identity.full_name)"
    }
    return [pscustomobject]$identity
}

function Get-ReviewRemoteUrl {
    param([string]$RepositoryRoot, [string]$RemoteName, [string[]]$GitHubHost = @(), [switch]$Optional)
    $url = Invoke-ReviewGit @('-C', $RepositoryRoot, 'config', '--get', "remote.$RemoteName.url") -Optional:$Optional
    if (!$url) { return '' }
    # Keep recognized provider identities stable when Git redirects transport to
    # a local mirror. Expand shorthand aliases that do not identify a provider.
    $identity = Get-ReviewRemoteIdentity $url $GitHubHost
    if ($identity.provider -in @('github', 'azure_devops')) { return $url }
    return Invoke-ReviewGit @('-C', $RepositoryRoot, 'remote', 'get-url', '--', $RemoteName) -Optional:$Optional
}

function Get-ReviewPrUrl {
    param([string]$Url)
    $uri = $null
    if (![Uri]::TryCreate($Url, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or
        $uri.UserInfo -or $uri.Query -or $uri.Fragment -or $uri.AbsolutePath -notmatch '^/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)/?$') {
        throw 'PR URL must be an HTTPS GitHub URL ending in /owner/repo/pull/<positive-integer>, without credentials, query, or fragment.'
    }
    $number = 0
    if (![int]::TryParse($Matches[3], [ref]$number)) { throw 'PR number is out of range.' }
    return [pscustomobject]@{ host = $uri.Host.ToLowerInvariant(); full_name = "$($Matches[1])/$($Matches[2])"; number = $number }
}

function Assert-ReviewBranchRef {
    param([string]$Ref)
    if (!$Ref.StartsWith('refs/heads/', [StringComparison]::Ordinal)) { throw 'Invalid branch ref.' }
    Invoke-ReviewGit @('check-ref-format', $Ref) -FailureMessage 'Invalid branch ref.' | Out-Null
    return $Ref
}

function Invoke-ReviewGhJson {
    param([string[]]$Arguments)
    $response = @(& gh @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw 'GitHub CLI request failed; check authentication and repository access.' }
    try {
        # Wrap the JSON so Windows PowerShell preserves empty/nested arrays;
        # its default ConvertFrom-Json output enumerates top-level arrays.
        $json = ($response | ForEach-Object { [string]$_ }) -join "`n"
        $envelope = ('{"payload":' + $json + '}') | ConvertFrom-Json
        return ,($envelope.payload)
    }
    catch { throw 'GitHub CLI returned invalid JSON.' }
}
