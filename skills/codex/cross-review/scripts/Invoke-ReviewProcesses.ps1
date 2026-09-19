#requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateCount(1, 2)][string[]]$InvocationPath,
    [ValidateRange(1, 14400)][int]$TimeoutSeconds = 1800,
    [ValidateRange(0, 30)][int]$PostExitDrainSeconds = 2
)

$ErrorActionPreference = 'Stop'
$jobs = [Collections.Generic.List[object]]::new()
$deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)

function Close-OutputCapture([object]$Job, [bool]$Force) {
    if ($Job.capture_closed) { return }
    if ($Force) {
        foreach ($reader in @($Job.process.StandardOutput, $Job.process.StandardError)) {
            try { $reader.Dispose() } catch { }
        }
    }

    $tasks = [Threading.Tasks.Task[]]@(@($Job.stdout, $Job.stderr) | Where-Object { $null -ne $_ })
    $tasksCompleted = $true
    if ($tasks.Count -gt 0) {
        try {
            $waitMilliseconds = if ($Force) { 500 } else { 2000 }
            $tasksCompleted = [Threading.Tasks.Task]::WaitAll($tasks, $waitMilliseconds)
            if (-not $tasksCompleted -and -not $Force) {
                throw 'Reviewer output did not finish draining.'
            }
            if ($tasksCompleted) {
                foreach ($task in $tasks) { $task.GetAwaiter().GetResult() }
            }
        } catch {
            if (-not $Force) { throw }
        }
    }
    foreach ($writer in @($Job.stdout_file, $Job.stderr_file)) {
        if ($null -eq $writer) { continue }
        try { $writer.Flush() } finally { $writer.Dispose() }
    }
    if (-not $tasksCompleted) {
        try { $null = [Threading.Tasks.Task]::WaitAll($tasks, 500) } catch { }
    }
    $Job.capture_closed = $true
}

function Complete-ReviewJob([object]$Job, [bool]$ForceCapture) {
    Close-OutputCapture -Job $Job -Force $ForceCapture
    $Job.saved = $true
    if ($ForceCapture) {
        Write-Warning "Reviewer PID $($Job.process.Id) exited, but a descendant kept an output pipe open. Preserved captured output and stopped waiting for EOF."
    }
    if ($Job.process.ExitCode -ne 0) {
        throw "Reviewer exited $($Job.process.ExitCode); see $($Job.path).stdout and .stderr."
    }
}

try {
    foreach ($path in $InvocationPath) {
        $fullPath = (Resolve-Path -LiteralPath $path).ProviderPath
        if (Test-Path -LiteralPath ($fullPath + '.cancel')) { throw 'Review stage was cancelled.' }
        $invocation = Get-Content -LiteralPath $fullPath -Raw | ConvertFrom-Json
        $command = Get-Command ([string]$invocation.executable) -CommandType Application -ErrorAction Stop | Select-Object -First 1
        if ([IO.Path]::GetExtension($command.Source) -in @('.cmd', '.bat')) {
            throw 'Use native CLI executables, not shell wrappers.'
        }
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = $command.Source
        $info.WorkingDirectory = [string]$invocation.working_directory
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardInput = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.StandardInputEncoding = [Text.UTF8Encoding]::new($false)
        $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
        $info.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
        foreach ($argument in $invocation.arguments) { $info.ArgumentList.Add([string]$argument) }
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $info
        $job = [pscustomobject]@{
            process = $process; path = $fullPath; started = $false
            stdout = $null; stderr = $null; stdout_file = $null; stderr_file = $null
            exit_seen_at = $null; capture_closed = $false; saved = $false
        }
        $jobs.Add($job)
        if (-not $process.Start()) { throw "Cannot start $($invocation.executable)." }
        $job.started = $true
        $identity = @{ process_id = $process.Id; started_at_ticks = $process.StartTime.ToUniversalTime().Ticks }
        [IO.File]::WriteAllText($fullPath + '.process.json', ($identity | ConvertTo-Json -Compress))
        $job.stdout_file = [IO.FileStream]::new($fullPath + '.stdout', [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 65536, [IO.FileOptions]::Asynchronous)
        $job.stderr_file = [IO.FileStream]::new($fullPath + '.stderr', [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read, 65536, [IO.FileOptions]::Asynchronous)
        $job.stdout = $process.StandardOutput.BaseStream.CopyToAsync($job.stdout_file)
        $job.stderr = $process.StandardError.BaseStream.CopyToAsync($job.stderr_file)
        if ($invocation.standard_input) { $process.StandardInput.WriteLine([string]$invocation.standard_input) }
        $process.StandardInput.Close()
        Write-Output "Started $($invocation.executable), PID $($process.Id), transcript $fullPath.stdout"
    }
    # Both processes are started before waiting. Copy both byte streams concurrently
    # so verbose CLI output cannot fill a pipe and deadlock the other reviewer.
    while (@($jobs | Where-Object { -not $_.saved }).Count -gt 0) {
        foreach ($job in $jobs) {
            if (Test-Path -LiteralPath ($job.path + '.cancel')) { throw 'Review stage was cancelled.' }
        }
        $now = [DateTimeOffset]::UtcNow
        foreach ($job in $jobs) {
            if ($job.saved -or -not $job.started -or -not $job.process.HasExited) { continue }
            if ($null -eq $job.exit_seen_at) { $job.exit_seen_at = $now }
            $captureComplete = $null -ne $job.stdout -and $null -ne $job.stderr -and $job.stdout.IsCompleted -and $job.stderr.IsCompleted
            $drainExpired = ($now - $job.exit_seen_at).TotalSeconds -ge $PostExitDrainSeconds
            if ($captureComplete -or $drainExpired) {
                Complete-ReviewJob -Job $job -ForceCapture (-not $captureComplete)
            }
        }
        if ($now -ge $deadline) {
            foreach ($job in @($jobs | Where-Object { -not $_.saved -and $_.started -and $_.process.HasExited })) {
                Complete-ReviewJob -Job $job -ForceCapture $true
            }
            if (@($jobs | Where-Object { -not $_.saved }).Count -gt 0) { throw "Review stage exceeded $TimeoutSeconds seconds." }
        }
        if (@($jobs | Where-Object { -not $_.saved }).Count -gt 0) { Start-Sleep -Milliseconds 200 }
    }
} finally {
    foreach ($job in $jobs) {
        try {
            if ($job.started -and -not $job.process.HasExited) {
                $job.process.Kill($true)
                if (-not $job.process.WaitForExit(10000)) { throw "PID $($job.process.Id) did not stop." }
            }
            if (-not $job.capture_closed) { Close-OutputCapture -Job $job -Force $true }
        } catch {
            Write-Warning "Could not confirm full reviewer cleanup for '$($job.path)': $($_.Exception.Message) Preserve its workspace and run data."
        } finally { $job.process.Dispose() }
    }
}
