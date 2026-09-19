[CmdletBinding()]
param(
    [Parameter()]
    [AllowNull()]
    [AllowEmptyString()]
    [string]$Response,

    [Parameter()]
    [switch]$Cancelled
)

$ErrorActionPreference = 'Stop'
$normalized = if ($null -eq $Response) { '' } else { $Response.Trim().ToLowerInvariant() }
$approved = -not $Cancelled -and $normalized -in @('y', 'yes')
$reason = if ($Cancelled) {
    'cancelled'
} elseif ($approved) {
    'explicit_yes'
} elseif ($normalized -in @('n', 'no')) {
    'explicit_no'
} elseif ([string]::IsNullOrWhiteSpace($normalized)) {
    'missing_response'
} else {
    'unrecognized_response'
}

[ordered]@{
    schema_version = 1
    approved = $approved
    decision = if ($approved) { 'continue' } else { 'quit' }
    reason = $reason
    normalized_response = if ([string]::IsNullOrWhiteSpace($normalized)) { $null } else { $normalized }
} | ConvertTo-Json -Depth 4 -Compress
