[CmdletBinding()]
param(
    [Parameter()]
    [string]$ClaudeModel,

    [Parameter()]
    [string]$ClaudeEffort,

    [Parameter()]
    [ValidateSet('session_context', 'explicit')]
    [string]$ClaudeModelSource = 'session_context',

    [Parameter()]
    [ValidateSet('session_context', 'explicit')]
    [string]$ClaudeEffortSource = 'session_context',

    [Parameter()]
    [string]$CodexModel,

    [Parameter()]
    [string]$CodexReasoningEffort,

    [Parameter()]
    [string]$CodexDoctorJsonPath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false

function ConvertTo-OptionalText {
    param($Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text.Trim()
}

function Get-PropertyValue {
    param($Object, [Parameter(Mandatory)][string[]]$Names)

    if ($null -eq $Object) { return $null }
    foreach ($name in $Names) {
        $property = $Object.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) { return $property.Value }
    }
    return $null
}

function ConvertFrom-DoctorJson {
    param([Parameter(Mandatory)][string]$Text)

    $start = $Text.IndexOf('{')
    $end = $Text.LastIndexOf('}')
    if ($start -lt 0 -or $end -lt $start) { return $null }
    try { return $Text.Substring($start, $end - $start + 1) | ConvertFrom-Json }
    catch { return $null }
}

$claudeModelValue = ConvertTo-OptionalText $ClaudeModel
$claudeEffortValue = ConvertTo-OptionalText $ClaudeEffort
$codexModelValue = ConvertTo-OptionalText $CodexModel
$codexEffortValue = ConvertTo-OptionalText $CodexReasoningEffort
$codexModelSource = if ($null -ne $codexModelValue) { 'explicit' } else { 'unavailable' }
$codexEffortSource = if ($null -ne $codexEffortValue) { 'explicit' } else { 'unavailable' }
$doctorStatus = 'not_run'
$doctor = $null

if ($null -eq $codexModelValue -or $null -eq $codexEffortValue) {
    $doctorText = $null
    if (-not [string]::IsNullOrWhiteSpace($CodexDoctorJsonPath)) {
        $doctorStatus = 'fixture'
        if (Test-Path -LiteralPath $CodexDoctorJsonPath -PathType Leaf) {
            $doctorText = Get-Content -LiteralPath $CodexDoctorJsonPath -Raw
        } else {
            $doctorStatus = 'unavailable'
        }
    } elseif ($null -ne (Get-Command codex -ErrorAction SilentlyContinue)) {
        $rawDoctor = @(& codex doctor --json 2>&1)
        $stdout = @($rawDoctor | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        $doctorText = (($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
        $doctorStatus = 'completed'
    } else {
        $doctorStatus = 'codex_not_found'
    }

    if (-not [string]::IsNullOrWhiteSpace($doctorText)) {
        $doctor = ConvertFrom-DoctorJson $doctorText
        if ($null -eq $doctor) { $doctorStatus = 'invalid_json' }
    }
}

if ($null -ne $doctor) {
    $configLoad = Get-PropertyValue $doctor.checks @('config.load', 'config_load')
    $details = if ($null -ne $configLoad) { Get-PropertyValue $configLoad @('details') } else { $null }
    if ($null -eq $codexModelValue) {
        $reportedModel = ConvertTo-OptionalText (Get-PropertyValue $details @('model'))
        if ($null -ne $reportedModel -and $reportedModel -ne '<default>') {
            $codexModelValue = $reportedModel
            $codexModelSource = 'codex_doctor'
        } elseif ($reportedModel -eq '<default>') {
            $codexModelSource = 'cli_default_unresolved'
        }
    }
    if ($null -eq $codexEffortValue) {
        $reportedEffort = ConvertTo-OptionalText (Get-PropertyValue $details @('model_reasoning_effort', 'reasoning_effort', 'reasoning effort'))
        if ($null -ne $reportedEffort -and $reportedEffort -ne '<default>') {
            $codexEffortValue = $reportedEffort
            $codexEffortSource = 'codex_doctor'
        } elseif ($reportedEffort -eq '<default>') {
            $codexEffortSource = 'cli_default_unresolved'
        }
    }
}

[ordered]@{
    schema_version = 1
    claude = [ordered]@{
        model = $claudeModelValue
        effort = $claudeEffortValue
        model_source = if ($null -ne $claudeModelValue) { $ClaudeModelSource } else { 'unavailable' }
        effort_source = if ($null -ne $claudeEffortValue) { $ClaudeEffortSource } else { 'unavailable' }
    }
    codex = [ordered]@{
        model = $codexModelValue
        reasoning_effort = $codexEffortValue
        model_source = $codexModelSource
        reasoning_effort_source = $codexEffortSource
        doctor_status = $doctorStatus
    }
} | ConvertTo-Json -Depth 6 -Compress
