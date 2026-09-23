[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('pull_request', 'uncommitted', 'branch')]
    [string]$ReviewMode,

    [string]$BaseCommit,

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [string]$WorkingDirectory,

    [string]$Model,

    [string]$ExecutablePath,

    [ValidateSet('minimal', 'low', 'medium', 'high', 'xhigh', 'max', 'ultra')]
    [string]$ReasoningEffort,

    [switch]$StructuredDiagnostics
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ReviewCliEnvironment.ps1')

if ($PSBoundParameters.ContainsKey('ExecutablePath') -and [string]::IsNullOrWhiteSpace($ExecutablePath)) {
    throw 'ExecutablePath must not be empty.'
}
if ($PSBoundParameters.ContainsKey('ExecutablePath') -and -not (Test-ReviewCodexExecutable -Path $ExecutablePath)) {
    throw 'ExecutablePath must be a native codex.exe with codex-code-mode-host.exe beside it.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    throw 'OutputPath must not be empty.'
}

if ([string]::IsNullOrWhiteSpace($WorkingDirectory)) {
    throw 'WorkingDirectory must not be empty; it pins Codex to the review workspace.'
}

if ($ReviewMode -in @('pull_request', 'branch')) {
    if ([string]::IsNullOrWhiteSpace($BaseCommit)) {
        throw "BaseCommit is required for $ReviewMode reviews."
    }
    if ($BaseCommit -notmatch '^(?:[0-9a-f]{40}|[0-9a-f]{64})$') {
        throw "BaseCommit must be the full target commit ID recorded during preflight, not a ref name: '$BaseCommit'."
    }
} elseif (-not [string]::IsNullOrWhiteSpace($BaseCommit)) {
    throw 'BaseCommit must be omitted for uncommitted reviews.'
}

$arguments = [System.Collections.Generic.List[string]]::new()
$arguments.Add('exec')
$arguments.Add('--cd')
$arguments.Add($WorkingDirectory)
$arguments.Add('--sandbox')
$arguments.Add('read-only')
$arguments.Add('--ephemeral')
if ($StructuredDiagnostics) {
    $arguments.Add('--json')
    $arguments.Add('-c')
    $arguments.Add('approval_policy="never"')
}

if (-not [string]::IsNullOrWhiteSpace($Model)) {
    $arguments.Add('--model')
    $arguments.Add($Model)
}

if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
    $arguments.Add('-c')
    $arguments.Add(('model_reasoning_effort="{0}"' -f $ReasoningEffort))
}

$arguments.Add('review')
if ($ReviewMode -eq 'uncommitted') {
    $arguments.Add('--uncommitted')
} else {
    $arguments.Add('--base')
    $arguments.Add($BaseCommit)
}
$arguments.Add('--output-last-message')
$arguments.Add($OutputPath)

$result = [ordered]@{
    schema_version = 1
    executable = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).ProviderPath } else { 'codex' }
    review_mode = $ReviewMode
    working_directory = $WorkingDirectory
    arguments = @($arguments)
    positional_prompt = $false
    sandbox = 'read-only'
    ephemeral = $true
}
if ($StructuredDiagnostics) {
    $result.json_events = $true
    $result.approval_policy = 'never'
}
$result | ConvertTo-Json -Depth 5
