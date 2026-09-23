function Get-ReviewCodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return $env:CODEX_HOME
    }
    $profile = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { $env:USERPROFILE } else { $env:HOME }
    if ([string]::IsNullOrWhiteSpace($profile)) { return $null }
    return (Join-Path $profile '.codex')
}

function Test-ReviewCodexExecutable {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or [IO.Path]::GetExtension($Path) -ne '.exe') { return $false }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $hostPath = Join-Path (Split-Path -Parent $Path) 'codex-code-mode-host.exe'
    return (Test-Path -LiteralPath $hostPath -PathType Leaf)
}

function Get-ReviewCodexExecutable {
    $candidates = [Collections.Generic.List[string]]::new()
    foreach ($command in @(Get-Command codex -All -CommandType Application -ErrorAction SilentlyContinue)) {
        $candidates.Add([string]$command.Source)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $candidates.Add((Join-Path $env:USERPROFILE '.codex/plugins/.plugin-appserver/codex.exe'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
        $appBin = Join-Path $env:LOCALAPPDATA 'OpenAI/Codex/bin'
        if (Test-Path -LiteralPath $appBin -PathType Container) {
            foreach ($directory in @(Get-ChildItem -LiteralPath $appBin -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending)) {
                $candidates.Add((Join-Path $directory.FullName 'codex.exe'))
            }
        }
    }
    foreach ($candidate in $candidates) {
        if (Test-ReviewCodexExecutable -Path $candidate) { return (Resolve-Path -LiteralPath $candidate).ProviderPath }
    }
    return $null
}
