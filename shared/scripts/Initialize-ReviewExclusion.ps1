[CmdletBinding()]
param(
    [Parameter()]
    [string]$RepositoryPath = '.'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$excludePatterns = @('/.reviews/', '/.claude/worktrees/')

function Invoke-GitText {
    param([Parameter(Mandatory)][string[]]$Arguments, [Parameter(Mandatory)][string]$FailureMessage)

    $output = @(& git @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage $($output -join [Environment]::NewLine)"
    }
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    return (($stdout | ForEach-Object { [string]$_ }) -join [Environment]::NewLine).Trim()
}

function Open-ExcludeFile {
    param([Parameter(Mandatory)][string]$Path)

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            return [System.IO.File]::Open($Path, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        } catch [System.IO.IOException] {
            if ($attempt -eq 5) {
                throw "Git exclude file '$Path' remained locked after 5 attempts: $($_.Exception.Message)"
            }
            Start-Sleep -Milliseconds (100 * $attempt)
        }
    }
}

$repositoryRoot = Invoke-GitText @('-C', $RepositoryPath, 'rev-parse', '--show-toplevel') 'Cannot resolve the repository root.'
$commonGitDirectory = Invoke-GitText @('-C', $repositoryRoot, 'rev-parse', '--git-common-dir') 'Cannot resolve the common Git directory.'
if (-not [System.IO.Path]::IsPathRooted($commonGitDirectory)) {
    $commonGitDirectory = Join-Path $repositoryRoot $commonGitDirectory
}
$excludePath = [System.IO.Path]::GetFullPath((Join-Path $commonGitDirectory 'info/exclude'))
[System.IO.Directory]::CreateDirectory((Split-Path -Parent $excludePath)) | Out-Null

$encoding = [System.Text.UTF8Encoding]::new($false)
$file = Open-ExcludeFile -Path $excludePath
$results = [System.Collections.Generic.List[object]]::new()
$changed = $false
try {
    $reader = [System.IO.StreamReader]::new($file, $encoding, $true, 1024, $true)
    try { $content = $reader.ReadToEnd() }
    finally { $reader.Dispose() }

    $existingLines = [System.Collections.Generic.List[string]]::new()
    foreach ($existingLine in ($content -split '\r?\n')) { $existingLines.Add([string]$existingLine) }

    foreach ($pattern in $excludePatterns) {
        $alreadyPresent = $existingLines.Contains($pattern)
        if (-not $alreadyPresent) {
            $file.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
            if ($file.Length -gt 0) {
                $file.Seek(-1, [System.IO.SeekOrigin]::End) | Out-Null
                $lastByte = $file.ReadByte()
                $file.Seek(0, [System.IO.SeekOrigin]::End) | Out-Null
                if ($lastByte -ne 10) {
                    $separator = $encoding.GetBytes([Environment]::NewLine)
                    $file.Write($separator, 0, $separator.Length)
                }
            }
            $entryBytes = $encoding.GetBytes($pattern + [Environment]::NewLine)
            $file.Write($entryBytes, 0, $entryBytes.Length)
            $existingLines.Add($pattern)
            $changed = $true
        }
        $results.Add([ordered]@{ pattern = $pattern; changed = (-not $alreadyPresent) })
    }

    if ($changed) { $file.Flush($true) }
} finally {
    $file.Dispose()
}

[ordered]@{
    changed = $changed
    patterns = @($results)
    exclude_path = $excludePath
} | ConvertTo-Json -Depth 4 -Compress
