#requires -Version 7.4
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

function Get-ReviewProcessPath {
    param(
        [Parameter(Mandatory)][string]$ToolDirectory,
        [AllowEmptyString()][string]$PathValue = $env:PATH,
        [AllowEmptyString()][string]$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User'),
        [AllowEmptyString()][string]$MachinePath = [Environment]::GetEnvironmentVariable('Path', 'Machine'),
        [AllowEmptyString()][string]$BundledBinRoot = $(if ($env:LOCALAPPDATA) { Join-Path $env:LOCALAPPDATA 'OpenAI/Codex/bin' } else { '' })
    )
    if (-not [IO.Path]::IsPathFullyQualified($ToolDirectory)) { throw 'ToolDirectory must be an absolute path.' }
    $name = if ($IsWindows) { 'rg.exe' } else { 'rg' }
    # Prefer the Codex copy: Windows' restricted identity may not be able to
    # read a user-private WinGet package, even when its parent can resolve rg.
    $bundledDirectories = @()
    if ($BundledBinRoot -and [IO.Directory]::Exists($BundledBinRoot)) {
        $bundledDirectories = @(Get-ChildItem -LiteralPath $BundledBinRoot -Directory -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending | ForEach-Object { $_.FullName })
    }
    $bundledPath = $bundledDirectories -join [IO.Path]::PathSeparator
    $executable = $null
    :findTool foreach ($source in @($bundledPath, $PathValue, $UserPath, $MachinePath)) {
        foreach ($directory in ($source -split [regex]::Escape([string][IO.Path]::PathSeparator))) {
            if ([string]::IsNullOrWhiteSpace($directory)) { continue }
            try {
                $directory = [Environment]::ExpandEnvironmentVariables($directory.Trim().Trim('"'))
                if (-not [IO.Path]::IsPathFullyQualified($directory)) { continue }
                # Path.Combine does not resolve PowerShell drives. An unavailable
                # drive or malformed entry must not prevent trying later entries.
                $candidate = [IO.Path]::Combine($directory, $name)
                $file = [IO.FileInfo]::new($candidate)
                if (-not $file.Exists) { continue }
                $target = $file.ResolveLinkTarget($true)
                if ($null -ne $target) { $file = $target }
                if (-not $file.Exists -or $file -isnot [IO.FileInfo]) { continue }
                $executable = $file.FullName
                break findTool
            } catch { continue }
        }
    }
    if (-not $executable) {
        throw 'ripgrep (rg) was not found on the process or registered user/machine PATH. Install ripgrep before starting a review.'
    }

    # Prepending a shared tool folder can change git, pwsh, or even codex itself.
    # Publish only rg in the invocation's temporary directory, inheriting that
    # directory's permissions rather than depending on the source package ACL.
    $hash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
    $isolatedDirectory = [IO.Path]::Combine($ToolDirectory, $hash)
    $null = [IO.Directory]::CreateDirectory($isolatedDirectory)
    $destination = [IO.Path]::Combine($isolatedDirectory, $name)
    if (-not [IO.File]::Exists($destination)) {
        $temporaryFile = [IO.Path]::Combine($isolatedDirectory, [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::Copy($executable, $temporaryFile)
            try { [IO.File]::Move($temporaryFile, $destination) }
            catch [IO.IOException] { if (-not [IO.File]::Exists($destination)) { throw } }
        } finally {
            if ([IO.File]::Exists($temporaryFile)) { [IO.File]::Delete($temporaryFile) }
        }
    }
    if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -ne $hash) {
        throw "Cached ripgrep does not match the selected executable: '$destination'."
    }
    if ([string]::IsNullOrEmpty($PathValue)) { return $isolatedDirectory }
    $first = ($PathValue -split [regex]::Escape([string][IO.Path]::PathSeparator))[0]
    if ($first -eq $isolatedDirectory) { return $PathValue }
    return $isolatedDirectory + [IO.Path]::PathSeparator + $PathValue
}
