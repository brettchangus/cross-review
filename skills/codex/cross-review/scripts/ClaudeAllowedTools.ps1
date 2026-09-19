function Get-ClaudeAllowedToolsPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $userProfile = [Environment]::GetFolderPath('UserProfile')
        if ([string]::IsNullOrWhiteSpace($userProfile)) { throw 'Cannot resolve the user profile for the Claude allowlist.' }
        $Path = Join-Path $userProfile '.codex/cross-review/claude-allowed-tools.json'
    }
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
}

function Assert-ClaudeAllowedToolRule {
    param([Parameter(Mandatory)][string]$Rule)

    if ([string]::IsNullOrWhiteSpace($Rule) -or $Rule -ne $Rule.Trim()) {
        throw 'Claude allowlist rules must be non-empty and cannot have leading or trailing whitespace.'
    }
    if ($Rule -match '[\x00-\x1f,]') {
        throw "Claude allowlist rule '$Rule' contains a control character or comma."
    }
    if ($Rule -notmatch '^Bash\(([^()]+)\)$') {
        throw "Claude allowlist rule '$Rule' must be a scoped Bash(command) rule."
    }
    $command = $Matches[1]
    if ([string]::IsNullOrWhiteSpace($command) -or $command.StartsWith('*') -or
        [string]::IsNullOrWhiteSpace(($command -replace '[*\s]', ''))) {
        throw 'Bare Bash and Bash(*) are too broad for the review allowlist.'
    }
}

function Read-ClaudeAllowedToolRules {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Claude allowlist path is not a file: '$Path'." }
    try { $configuration = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "Claude allowlist is not valid JSON: '$Path'. $($_.Exception.Message)" }
    if ($configuration.schema_version -ne 1 -or $configuration.PSObject.Properties.Name -notcontains 'allowed_tools') {
        throw "Claude allowlist must use schema_version 1 and contain allowed_tools: '$Path'."
    }

    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $rules = [Collections.Generic.List[string]]::new()
    foreach ($ruleValue in @($configuration.allowed_tools)) {
        $rule = [string]$ruleValue
        Assert-ClaudeAllowedToolRule -Rule $rule
        if ($seen.Add($rule)) { $rules.Add($rule) }
    }
    return $rules.ToArray()
}
