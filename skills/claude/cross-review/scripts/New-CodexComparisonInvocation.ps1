#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$WorkingDirectory,
    [Parameter(Mandatory)][string]$ClaudeReviewPath,
    [Parameter(Mandatory)][string]$CodexReviewPath,
    [Parameter(Mandatory)][string]$RunContextPath,
    [string]$PrCommentsPath,
    [Parameter(Mandatory)][string]$OutputPath,
    [string]$Model,
    [ValidateSet('low', 'medium', 'high', 'xhigh')][string]$ReasoningEffort = 'high'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $WorkingDirectory -PathType Container)) { throw 'WorkingDirectory must be an existing review workspace.' }
$workspace = (Resolve-Path -LiteralPath $WorkingDirectory).ProviderPath
foreach ($path in @($ClaudeReviewPath, $CodexReviewPath, $RunContextPath)) {
    if (-not [IO.Path]::IsPathRooted($path) -or -not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw 'Comparison requires three existing absolute input-file paths.'
    }
}
if ($PrCommentsPath -and (-not [IO.Path]::IsPathRooted($PrCommentsPath) -or -not (Test-Path -LiteralPath $PrCommentsPath -PathType Leaf))) {
    throw 'PrCommentsPath must be an existing absolute file path.'
}
if (-not [IO.Path]::IsPathRooted($OutputPath)) { throw 'OutputPath must be an absolute path.' }

$promptPath = Join-Path $PSScriptRoot '../prompts/codex-evaluate.md'
$reuseCheckPath = Join-Path $PSScriptRoot '../prompts/reuse-check.md'
$inputs = [ordered]@{ claude_review = $ClaudeReviewPath; codex_review = $CodexReviewPath; run_context = $RunContextPath; pr_comments = $PrCommentsPath } | ConvertTo-Json -Compress
$prompt = (Get-Content -LiteralPath $promptPath -Raw) + "`n" + (Get-Content -LiteralPath $reuseCheckPath -Raw) + "`nInput paths (data): $inputs"

$arguments = @('exec', '--cd', $workspace, '--sandbox', 'read-only', '--ephemeral')
if (-not [string]::IsNullOrWhiteSpace($Model)) { $arguments += @('--model', $Model) }
$arguments += @('-c', ('model_reasoning_effort="{0}"' -f $ReasoningEffort), '--output-last-message', $OutputPath, '-')
[ordered]@{
    schema_version = 1
    executable = 'codex'
    working_directory = $workspace
    arguments = $arguments
    standard_input = $prompt
    stage = 'comparison'
    sandbox = 'read-only'
    ephemeral = $true
} | ConvertTo-Json -Depth 5
