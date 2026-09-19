[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$AllowedTool,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeAllowedTools.ps1')
$path = Get-ClaudeAllowedToolsPath -Path $ConfigPath
$existing = @(Read-ClaudeAllowedToolRules -Path $path)
$seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$merged = [Collections.Generic.List[string]]::new()
foreach ($rule in $existing) {
    if ($seen.Add($rule)) { $merged.Add($rule) }
}
$added = [Collections.Generic.List[string]]::new()
foreach ($rule in $AllowedTool) {
    Assert-ClaudeAllowedToolRule -Rule $rule
    if ($seen.Add($rule)) {
        $merged.Add($rule)
        $added.Add($rule)
    }
}

if ($added.Count -gt 0) {
    $parent = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    $json = [ordered]@{ schema_version = 1; allowed_tools = $merged.ToArray() } | ConvertTo-Json -Depth 4
    $temporaryPath = Join-Path $parent ('.claude-allowed-tools-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporaryPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporaryPath, $path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }
}

[ordered]@{
    config_path = $path
    added = $added.ToArray()
    allowed_tools = $merged.ToArray()
} | ConvertTo-Json -Depth 4
