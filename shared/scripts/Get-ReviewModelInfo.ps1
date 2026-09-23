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
    [string]$CodexDoctorJsonPath,

    [Parameter()]
    [switch]$DiscoverClaudeConfiguration,

    [Parameter()]
    [string]$ReviewWorkspace,

    [Parameter()]
    [string]$ClaudeSettingsPath,

    [string]$ProjectLocalSettingsPath,

    [switch]$RequireCompleteCodexExecutable,

    [switch]$SkipCodexDiagnostics
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
. (Join-Path $PSScriptRoot 'ReviewCliEnvironment.ps1')

function ConvertTo-OptionalText {
    param($Value)

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text.Trim()
}

function ConvertTo-ModelSelection {
    param($Value)
    $selection = ConvertTo-OptionalText $Value
    if ($selection -eq 'default') { return $null }
    return $selection
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
$resolvedClaudeModelSource = if ($null -ne $claudeModelValue) { $ClaudeModelSource } else { 'unavailable' }
if ($null -eq $claudeModelValue -and $DiscoverClaudeConfiguration) {
    $shellModel = ConvertTo-OptionalText $env:ANTHROPIC_MODEL
    if ($null -ne $shellModel) {
        $claudeModelValue = ConvertTo-ModelSelection $shellModel
        if ($null -ne $claudeModelValue) { $resolvedClaudeModelSource = 'environment' }
    } else {
        $settingsFiles = @()
        if ($IsWindows -and -not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
            $settingsFiles += [pscustomobject]@{ path = (Join-Path $env:ProgramFiles 'ClaudeCode/managed-settings.json'); source = 'managed_settings' }
        } elseif ($IsMacOS) {
            $settingsFiles += [pscustomobject]@{ path = '/Library/Application Support/ClaudeCode/managed-settings.json'; source = 'managed_settings' }
        } elseif ($IsLinux) {
            $settingsFiles += [pscustomobject]@{ path = '/etc/claude-code/managed-settings.json'; source = 'managed_settings' }
        }
        if (-not [string]::IsNullOrWhiteSpace($ProjectLocalSettingsPath)) {
            $settingsFiles += [pscustomobject]@{ path = $ProjectLocalSettingsPath; source = 'project_settings' }
        } elseif (-not [string]::IsNullOrWhiteSpace($ReviewWorkspace)) {
            $settingsFiles += [pscustomobject]@{ path = (Join-Path $ReviewWorkspace '.claude/settings.local.json'); source = 'project_settings' }
        }
        if (-not [string]::IsNullOrWhiteSpace($ReviewWorkspace)) {
            $settingsFiles += [pscustomobject]@{ path = (Join-Path $ReviewWorkspace '.claude/settings.json'); source = 'project_settings' }
        }
        $configDirectory = if (-not [string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) { $env:CLAUDE_CONFIG_DIR } elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) { Join-Path $env:USERPROFILE '.claude' } elseif (-not [string]::IsNullOrWhiteSpace($env:HOME)) { Join-Path $env:HOME '.claude' } else { $null }
        if (-not [string]::IsNullOrWhiteSpace($ClaudeSettingsPath)) {
            $settingsFiles += [pscustomobject]@{ path = $ClaudeSettingsPath; source = 'user_settings' }
        } elseif ($null -ne $configDirectory) {
            $settingsFiles += [pscustomobject]@{ path = (Join-Path $configDirectory 'settings.json'); source = 'user_settings' }
        }
        $settingsEntries = @()
        foreach ($settingsFile in $settingsFiles) {
            if (-not (Test-Path -LiteralPath $settingsFile.path -PathType Leaf)) { continue }
            try { $settings = Get-Content -LiteralPath $settingsFile.path -Raw | ConvertFrom-Json }
            catch { continue }
            $settingsEntries += [pscustomobject]@{ settings = $settings; source = $settingsFile.source }
        }
        $selected = $false
        foreach ($entry in $settingsEntries) {
            $candidate = ConvertTo-OptionalText (Get-PropertyValue (Get-PropertyValue $entry.settings @('env')) @('ANTHROPIC_MODEL'))
            if ($null -eq $candidate) { continue }
            $claudeModelValue = ConvertTo-ModelSelection $candidate
            if ($null -ne $claudeModelValue) { $resolvedClaudeModelSource = "$($entry.source)_environment" }
            $selected = $true
            break
        }
        if (-not $selected) {
            foreach ($entry in $settingsEntries) {
                $candidate = ConvertTo-OptionalText (Get-PropertyValue $entry.settings @('model'))
                if ($null -eq $candidate) { continue }
                $claudeModelValue = ConvertTo-ModelSelection $candidate
                if ($null -ne $claudeModelValue) { $resolvedClaudeModelSource = $entry.source }
                $selected = $true
                break
            }
        }
        if (-not $selected) {
            $claudeModelValue = ConvertTo-ModelSelection $env:ANTHROPIC_DEFAULT_MODEL
            if ($null -ne $claudeModelValue) { $resolvedClaudeModelSource = 'default_environment' }
            if ($null -eq $claudeModelValue) {
                foreach ($entry in $settingsEntries) {
                    $candidate = ConvertTo-OptionalText (Get-PropertyValue (Get-PropertyValue $entry.settings @('env')) @('ANTHROPIC_DEFAULT_MODEL'))
                    if ($null -eq $candidate) { continue }
                    $claudeModelValue = ConvertTo-ModelSelection $candidate
                    if ($null -ne $claudeModelValue) { $resolvedClaudeModelSource = "$($entry.source)_default_environment" }
                    break
                }
            }
        }
    }
}
$claudeEffortValue = ConvertTo-OptionalText $ClaudeEffort
$codexModelValue = ConvertTo-OptionalText $CodexModel
$codexEffortValue = ConvertTo-OptionalText $CodexReasoningEffort
$codexModelSource = if ($null -ne $codexModelValue) { 'explicit' } else { 'unavailable' }
$codexEffortSource = if ($null -ne $codexEffortValue) { 'explicit' } else { 'unavailable' }
$doctorStatus = 'not_run'
$doctor = $null
$codexExecutable = $null
if ($RequireCompleteCodexExecutable) { $codexExecutable = Get-ReviewCodexExecutable }

if (-not $SkipCodexDiagnostics -and ($null -eq $codexModelValue -or $null -eq $codexEffortValue)) {
    $doctorText = $null
    if (-not [string]::IsNullOrWhiteSpace($CodexDoctorJsonPath)) {
        $doctorStatus = 'fixture'
        if (Test-Path -LiteralPath $CodexDoctorJsonPath -PathType Leaf) {
            $doctorText = Get-Content -LiteralPath $CodexDoctorJsonPath -Raw
        } else {
            $doctorStatus = 'unavailable'
        }
    } else {
        if ($null -eq $codexExecutable) {
            $command = Get-Command codex -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($null -ne $command) { $codexExecutable = [string]$command.Source }
        }
        if ($null -ne $codexExecutable) {
            $previousCodexHome = $env:CODEX_HOME
            try {
                $resolvedCodexHome = Get-ReviewCodexHome
                if ($RequireCompleteCodexExecutable -and [string]::IsNullOrWhiteSpace($previousCodexHome) -and $null -ne $resolvedCodexHome) { $env:CODEX_HOME = $resolvedCodexHome }
                $rawDoctor = @(& $codexExecutable doctor --json 2>&1)
                $stdout = @($rawDoctor | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
                $doctorText = (($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine)
                $doctorStatus = 'completed'
            } finally {
                if ([string]::IsNullOrWhiteSpace($previousCodexHome)) { $env:CODEX_HOME = $previousCodexHome }
            }
        } else { $doctorStatus = 'codex_not_found' }
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
        model_source = $resolvedClaudeModelSource
        effort_source = if ($null -ne $claudeEffortValue) { $ClaudeEffortSource } else { 'unavailable' }
    }
    codex = [ordered]@{
        model = $codexModelValue
        reasoning_effort = $codexEffortValue
        model_source = $codexModelSource
        reasoning_effort_source = $codexEffortSource
        doctor_status = $doctorStatus
        executable = $codexExecutable
    }
} | ConvertTo-Json -Depth 6 -Compress
