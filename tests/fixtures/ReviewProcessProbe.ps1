param(
    [ValidateSet('rendezvous', 'wait', 'fail', 'flood', 'hold-open')][string]$Mode,
    [string]$ReadyPath,
    [string]$PeerPath,
    [string]$EchoText
)
$ErrorActionPreference = 'Stop'
if ($ReadyPath) { [IO.File]::WriteAllText($ReadyPath, [string]$PID) }
if ($PeerPath) {
    $deadline = [DateTime]::UtcNow.AddSeconds(8)
    while (-not (Test-Path -LiteralPath $PeerPath)) {
        if ([DateTime]::UtcNow -ge $deadline) { throw 'Peer did not start concurrently.' }
        Start-Sleep -Milliseconds 25
    }
}
switch ($Mode) {
    'wait' { Start-Sleep -Seconds 60 }
    'fail' { [Console]::Error.WriteLine('deliberate failure'); exit 9 }
    'flood' {
        [Console]::Out.WriteLine('o' * 200000)
        [Console]::Error.WriteLine('e' * 200000)
    }
    'hold-open' {
        $childInfo = [Diagnostics.ProcessStartInfo]::new()
        $childInfo.FileName = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $childInfo.UseShellExecute = $false
        $childInfo.CreateNoWindow = $true
        $childInfo.WorkingDirectory = [IO.Path]::GetTempPath()
        foreach ($argument in @('-NoProfile', '-Command', 'Start-Sleep -Seconds 6')) { $childInfo.ArgumentList.Add($argument) }
        [Diagnostics.Process]::Start($childInfo).Dispose()
        [Console]::Out.WriteLine('parent complete')
        exit 0
    }
}
[Console]::Out.WriteLine($EchoText)
[Console]::Out.WriteLine([Console]::In.ReadToEnd())
