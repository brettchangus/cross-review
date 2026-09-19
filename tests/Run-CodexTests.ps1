#requires -Version 7.4
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('cross-review-codex-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$passed = 0
$failed = 0

function Test-Case([string]$Name, [scriptblock]$Action) {
    try { & $Action; $script:passed++; Write-Host "PASS $Name" }
    catch { $script:failed++; Write-Host "FAIL $Name - $($_.Exception.Message)" }
}
function Expect-Failure([scriptblock]$Action, [string]$Message) {
    try { & $Action | Out-Null }
    catch { if ($_.Exception.Message -like "*$Message*") { return }; throw }
    throw "Expected failure containing: $Message"
}
function Write-Json([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}
function New-Ledger {
    return [pscustomobject]@{
        schema_version = 4; review_id = [Guid]::NewGuid().ToString(); review_mode = 'uncommitted'; status = 'complete'
        repository = @{ id = 'fixture'; name = 'fixture'; url = '' }
        pull_request = @{ id = $null; source_ref = 'WORKTREE'; target_ref = 'HEAD'; source_commit = ('a' * 40); target_commit = ('a' * 40) }
        local = @{ branch = 'feature/test'; head_commit = ('a' * 40) }
        findings = @(@{ id = 'C-001'; reviewer = 'claude'; severity = 'high' }, @{ id = 'X-001'; reviewer = 'codex'; severity = 'medium' })
        groups = @(@{ id = 'G-001'; source_ids = @('C-001'); disposition = 'confirmed'; final_severity = 'high' },
            @{ id = 'G-002'; source_ids = @('X-001'); disposition = 'rejected' })
        adjudication = @{ adjudicator = 'codex'; comparison_provider = 'claude'; comparison_disposition_overrides = @(
            @{ group_id = 'G-001'; comparison_disposition = 'uncertain'; final_disposition = 'confirmed'; reason = 'Source confirms it.' }
        ) }
    }
}
function Measure-Ledger($Ledger) {
    Write-Json $ledgerPath $Ledger
    & $measureScript -LedgerPath $ledgerPath -OutputPath $metricsPath | ConvertFrom-Json
}
function Write-Transcript([object[]]$Events) {
    $lines = @($Events | ForEach-Object { $_ | ConvertTo-Json -Depth 12 -Compress })
    [IO.File]::WriteAllLines($transcriptPath, $lines, [Text.UTF8Encoding]::new($false))
}
function New-Probe([string]$Name, [string[]]$Arguments, [string]$InputText = '') {
    $path = Join-Path $testRoot "$Name.json"
    Write-Json $path @{ executable = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source; working_directory = $testRoot
        arguments = @('-NoProfile', '-File', (Join-Path $PSScriptRoot 'fixtures/ReviewProcessProbe.ps1')) + $Arguments; standard_input = $InputText }
    return $path
}
function Assert-Stopped([string]$ReadyPath) {
    if (-not (Test-Path -LiteralPath $ReadyPath)) { throw 'Probe never started.' }
    $probeId = [int](Get-Content -LiteralPath $ReadyPath -Raw)
    if (Get-Process -Id $probeId -ErrorAction SilentlyContinue) { throw "Probe PID $probeId is still running." }
}

try {
    $package = Join-Path $testRoot 'codex package'
    $installation = & (Join-Path $repoRoot 'Install-Skill.ps1') -HostApp Codex -DestinationPath $package
    $builder = Join-Path $package 'scripts/New-ClaudeReviewInvocation.ps1'
    $codexBuilder = Join-Path $package 'scripts/New-CodexReviewInvocation.ps1'
    $reader = Join-Path $package 'scripts/Read-ClaudeReviewResult.ps1'
    $codexReader = Join-Path $package 'scripts/Read-CodexReviewResult.ps1'
    $allowUpdater = Join-Path $package 'scripts/Update-ClaudeAllowedTools.ps1'
    $runner = Join-Path $package 'scripts/Invoke-ReviewProcesses.ps1'
    $stopper = Join-Path $package 'scripts/Stop-ReviewProcesses.ps1'
    $measureScript = Join-Path $package 'scripts/Measure-ReviewEffectiveness.ps1'
    $appendScript = Join-Path $package 'scripts/Append-ReviewHistory.ps1'
    $storageScript = Join-Path $package 'scripts/Assert-ReviewStorageSafe.ps1'
    $runDirectoryScript = Join-Path $package 'scripts/New-ReviewRunDirectory.ps1'
    $ledgerPath = Join-Path $testRoot 'ledger.json'
    $metricsPath = Join-Path $testRoot 'metrics.json'
    $transcriptPath = Join-Path $testRoot 'claude.jsonl'
    $reportPath = Join-Path $testRoot 'report.md'
    $codexReportPath = Join-Path $testRoot 'codex-report.md'
    $allowedToolsPath = Join-Path $testRoot 'claude-allowed-tools.json'
    Test-Case 'codex-package-byte-preserving' {
        $expectedCount = 0
        foreach ($source in @((Join-Path $repoRoot 'shared'), (Join-Path $repoRoot 'skills/codex/cross-review'))) {
            foreach ($file in Get-ChildItem -LiteralPath $source -Recurse -File) {
                $relative = $file.FullName.Substring($source.Length).TrimStart('\', '/')
                if ((Get-FileHash -LiteralPath $file.FullName).Hash -ne (Get-FileHash -LiteralPath (Join-Path $package $relative)).Hash) { throw "Package differs: $relative" }
                $expectedCount++
            }
        }
        if ($installation.file_count -ne $expectedCount) { throw 'Package count mismatch' }
    }
    Test-Case 'claude-native-scope-and-permissions' {
        $scopeRepo = Join-Path $testRoot 'scope fixture'
        New-Item -ItemType Directory -Path $scopeRepo | Out-Null
        & git -C $scopeRepo init -q
        & git -C $scopeRepo -c user.name=Fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m baseline
        if ($LASTEXITCODE -ne 0) { throw 'Cannot create scope fixture' }
        $scopeBase = [string](& git -C $scopeRepo rev-parse HEAD)
        foreach ($mode in @('uncommitted', 'branch', 'pull_request')) {
            $parameters = @{ Stage = 'independent'; WorkingDirectory = $scopeRepo; ReviewMode = $mode; Model = 'fixture-model'; AllowedToolsPath = $allowedToolsPath }
            if ($mode -ne 'uncommitted') { $parameters.BaseCommit = $scopeBase }
            $invocation = & $builder @parameters | ConvertFrom-Json
            if ($invocation.effort -ne 'high' -or $invocation.arguments -notcontains '--no-session-persistence' -or
                $invocation.arguments -notcontains 'dontAsk' -or $invocation.arguments -notcontains 'fixture-model' -or
                $invocation.arguments -contains '--dangerously-skip-permissions' -or $invocation.arguments -contains '--resume') { throw 'Incorrect Claude settings' }
            if ($mode -ne 'uncommitted' -and -not $invocation.standard_input.Contains($scopeBase + '...HEAD')) { throw 'Frozen diff scope missing' }
        }
        Expect-Failure { & $builder -Stage independent -WorkingDirectory $testRoot -ReviewMode branch -BaseCommit main -AllowedToolsPath $allowedToolsPath } 'full frozen target commit'
        Expect-Failure { & $builder -Stage independent -WorkingDirectory $testRoot -ReviewMode uncommitted -BaseCommit ('a' * 40) -AllowedToolsPath $allowedToolsPath } 'must be omitted'
        [IO.File]::WriteAllText((Join-Path $scopeRepo 'unrelated.txt'), 'Uncommitted source')
        Expect-Failure { & $builder -Stage independent -WorkingDirectory $scopeRepo -ReviewMode branch -BaseCommit $scopeBase -AllowedToolsPath $allowedToolsPath } 'requires a clean workspace'
    }
    Test-Case 'claude-comparison-inputs' {
        $inputPaths = @('claude.md', 'codex.md', 'context.json') | ForEach-Object { Join-Path $testRoot $_ }
        foreach ($path in $inputPaths) { [IO.File]::WriteAllText($path, 'fixture') }
        $invocation = & $builder -Stage comparison -WorkingDirectory $testRoot -ClaudeReviewPath $inputPaths[0] -CodexReviewPath $inputPaths[1] -RunContextPath $inputPaths[2] -AllowedToolsPath $allowedToolsPath | ConvertFrom-Json
        if ($invocation.effort -ne 'medium' -or $invocation.arguments -contains '--resume') { throw 'Comparison effort or freshness incorrect' }
        foreach ($path in $inputPaths) { if (-not $invocation.standard_input.Contains(($path | ConvertTo-Json -Compress))) { throw 'Missing escaped input path' } }
        Expect-Failure { & $builder -Stage comparison -WorkingDirectory $testRoot -ClaudeReviewPath 'relative.md' -AllowedToolsPath $allowedToolsPath } 'existing absolute'
    }
    Test-Case 'claude-review-allowlist-is-explicit-scoped-and-persistent' {
        $first = & $allowUpdater -ConfigPath $allowedToolsPath -AllowedTool 'Bash(ls *)','Bash(wc *)' | ConvertFrom-Json
        if ($first.added.Count -ne 2 -or $first.allowed_tools.Count -ne 2) { throw 'Initial allowlist update failed' }
        $second = & $allowUpdater -ConfigPath $allowedToolsPath -AllowedTool 'Bash(ls *)','Bash(head *)' | ConvertFrom-Json
        if ($second.added.Count -ne 1 -or $second.allowed_tools.Count -ne 3) { throw 'Allowlist update was not idempotent' }

        $inputPaths = @('allow-claude.md', 'allow-codex.md', 'allow-context.json') | ForEach-Object { Join-Path $testRoot $_ }
        foreach ($path in $inputPaths) { [IO.File]::WriteAllText($path, 'fixture') }
        $invocation = & $builder -Stage comparison -WorkingDirectory $testRoot -ClaudeReviewPath $inputPaths[0] -CodexReviewPath $inputPaths[1] -RunContextPath $inputPaths[2] -AllowedToolsPath $allowedToolsPath | ConvertFrom-Json
        $allowedIndex = [Array]::IndexOf([object[]]$invocation.arguments, '--allowedTools')
        if ($allowedIndex -lt 0) { throw 'Claude allowlist argument is missing' }
        $allowed = [string]$invocation.arguments[$allowedIndex + 1]
        foreach ($rule in @('Bash(ls *)', 'Bash(wc *)', 'Bash(head *)')) {
            if (-not $allowed.Contains($rule) -or $invocation.additional_allowed_tools -notcontains $rule) { throw "Missing configured rule: $rule" }
        }
        Expect-Failure { & $allowUpdater -ConfigPath $allowedToolsPath -AllowedTool 'Bash(*)' } 'too broad'
        Expect-Failure { & $allowUpdater -ConfigPath $allowedToolsPath -AllowedTool 'Bash(**)' } 'too broad'
        Expect-Failure { & $allowUpdater -ConfigPath $allowedToolsPath -AllowedTool 'Bash(ls) Bash(*)' } 'scoped Bash'
        Expect-Failure { & $allowUpdater -ConfigPath $allowedToolsPath -AllowedTool 'Read' } 'scoped Bash'
    }
    Test-Case 'codex-structured-diagnostics-are-host-opt-in' {
        $plain = & $codexBuilder -ReviewMode uncommitted -WorkingDirectory $testRoot -OutputPath (Join-Path $testRoot 'plain.md') | ConvertFrom-Json
        $structured = & $codexBuilder -ReviewMode uncommitted -WorkingDirectory $testRoot -OutputPath (Join-Path $testRoot 'structured.md') -StructuredDiagnostics | ConvertFrom-Json
        if ($plain.arguments -contains '--json' -or $plain.PSObject.Properties.Name -contains 'json_events' -or
            $plain.PSObject.Properties.Name -contains 'approval_policy') {
            throw 'Shared invocation unexpectedly enabled structured diagnostics'
        }
        $arguments = @($structured.arguments | ForEach-Object { [string]$_ })
        if ($arguments -notcontains '--json' -or $arguments -notcontains 'approval_policy="never"' -or
            $structured.json_events -ne $true -or $structured.approval_policy -ne 'never') {
            throw 'Codex-led structured diagnostics were not enabled explicitly'
        }
    }

    $nativeEvents = @(
        @{ type = 'assistant'; message = @{ content = @(@{ type = 'tool_use'; id = 'call-1'; name = 'Skill'; input = @{ skill = 'code-review'; args = 'high' } }) } },
        @{ type = 'user'; message = @{ content = @(@{ type = 'tool_result'; tool_use_id = 'call-1'; content = 'Loaded'; is_error = $false }) } }
    )
    $success = @{ type = 'result'; subtype = 'success'; is_error = $false; result = 'No findings.'; permission_denials = @() }
    Test-Case 'claude-valid-native-report' {
        Write-Transcript ($nativeEvents + @($success))
        $value = & $reader -TranscriptPath $transcriptPath -OutputPath $reportPath -RequireNativeReview | ConvertFrom-Json
        if (-not $value.native_review_observed -or (Get-Content -LiteralPath $reportPath -Raw) -ne 'No findings.') { throw 'Native extraction failed' }
    }
    Test-Case 'claude-rejects-generic-or-failed-native-review' {
        Write-Transcript @($success)
        Expect-Failure { & $reader -TranscriptPath $transcriptPath -OutputPath $reportPath -RequireNativeReview } 'No successful native'
        $nativeEvents[1].message.content[0].is_error = $true
        Write-Transcript ($nativeEvents + @($success))
        Expect-Failure { & $reader -TranscriptPath $transcriptPath -OutputPath $reportPath -RequireNativeReview } 'No successful native'
        $nativeEvents[1].message.content[0].is_error = $false
    }
    Test-Case 'claude-rejects-error-empty-and-truncated-results' {
        foreach ($bad in @(
            @{ type = 'result'; subtype = 'error_during_execution'; is_error = $true; result = 'Failed' },
            @{ type = 'result'; subtype = 'success'; is_error = $false; result = '' }
        )) {
            Write-Transcript @($bad)
            Expect-Failure { & $reader -TranscriptPath $transcriptPath -OutputPath $reportPath } 'successful, non-empty'
        }
        Write-Transcript $nativeEvents
        Expect-Failure { & $reader -TranscriptPath $transcriptPath -OutputPath $reportPath } 'successful, non-empty'
    }
    Test-Case 'claude-preserves-permission-denials-as-diagnostics' {
        $denied = $success.Clone(); $denied.permission_denials = @(@{ tool_name = 'Bash'; tool_input = @{ command = 'ls -la' } })
        Write-Transcript @($denied)
        $value = & $reader -TranscriptPath $transcriptPath -OutputPath $reportPath | ConvertFrom-Json
        if ($value.permission_denial_count -ne 1 -or $value.permission_denials[0].tool_input.command -ne 'ls -la' -or
            (Get-Content -LiteralPath $reportPath -Raw) -ne 'No findings.') { throw 'Permission denial diagnostics were not preserved' }
    }
    Test-Case 'codex-preserves-sandbox-denials-with-complete-report' {
        [IO.File]::WriteAllText($codexReportPath, 'Complete Codex review.', [Text.UTF8Encoding]::new($false))
        Write-Transcript @(
            @{ type = 'item.completed'; item = @{ id = 'item-1'; type = 'command_execution'; command = 'git status'; aggregated_output = "failed in sandbox: permission denied`n"; exit_code = -1; status = 'failed' } },
            @{ type = 'turn.completed'; usage = @{ input_tokens = 10; output_tokens = 5 } }
        )
        $value = & $codexReader -TranscriptPath $transcriptPath -ReportPath $codexReportPath | ConvertFrom-Json
        if (-not $value.turn_completed -or $value.permission_denial_count -ne 1 -or $value.permission_denials[0].command -ne 'git status') {
            throw 'Codex denial diagnostics were not preserved'
        }
    }
    Test-Case 'codex-does-not-mislabel-generic-command-failures' {
        [IO.File]::WriteAllText($codexReportPath, 'Complete Codex review.', [Text.UTF8Encoding]::new($false))
        Write-Transcript @(
            @{ type = 'item.completed'; item = @{ id = 'item-1'; type = 'command_execution'; command = 'rg sandbox'; aggregated_output = 'command exited 1 while reading sandbox documentation'; exit_code = 1; status = 'failed' } },
            @{ type = 'turn.completed'; usage = @{} }
        )
        $value = & $codexReader -TranscriptPath $transcriptPath -ReportPath $codexReportPath | ConvertFrom-Json
        if ($value.permission_denial_count -ne 0) { throw 'Generic command failure was mislabeled as a permission denial' }
    }
    Test-Case 'codex-rejects-failed-truncated-and-empty-results' {
        [IO.File]::WriteAllText($codexReportPath, 'Complete Codex review.', [Text.UTF8Encoding]::new($false))
        Write-Transcript @(@{ type = 'turn.failed'; error = @{ message = 'failure' } })
        Expect-Failure { & $codexReader -TranscriptPath $transcriptPath -ReportPath $codexReportPath } 'turn.failed'
        Write-Transcript @(@{ type = 'thread.started'; thread_id = 'fixture' })
        Expect-Failure { & $codexReader -TranscriptPath $transcriptPath -ReportPath $codexReportPath } 'turn.completed'
        [IO.File]::WriteAllText($codexReportPath, '')
        Write-Transcript @(@{ type = 'turn.completed'; usage = @{} })
        Expect-Failure { & $codexReader -TranscriptPath $transcriptPath -ReportPath $codexReportPath } 'report is empty'
    }

    Test-Case 'v4-role-neutral-metrics' {
        $metrics = Measure-Ledger (New-Ledger)
        if ($metrics.schema_version -ne 4 -or $metrics.metrics.claude_added_value -ne 1 -or $metrics.metrics.codex_added_value -ne 0 -or
            $metrics.resolution.adjudicator_overrides -ne 1 -or $metrics.adjudication.adjudicator -ne 'codex') { throw 'Incorrect v4 metrics' }
    }
    Test-Case 'v4-empty-metrics' {
        $ledger = New-Ledger; $ledger.findings = @(); $ledger.groups = @(); $ledger.adjudication.comparison_disposition_overrides = @()
        $metrics = Measure-Ledger $ledger
        if ($null -ne $metrics.metrics.claude_added_value -or $metrics.resolution.adjudicator_overrides -ne 0) { throw 'Invalid empty v4 metrics' }
    }
    Test-Case 'v4-rejects-role-and-override-mismatches' {
        $ledger = New-Ledger; $ledger.adjudication.comparison_provider = 'codex'
        Expect-Failure { Measure-Ledger $ledger } 'distinct'
        $ledger = New-Ledger; $ledger.adjudication.codex_disposition_overrides = @()
        Expect-Failure { Measure-Ledger $ledger } 'not codex_disposition_overrides'
        $ledger = New-Ledger; $ledger.adjudication.comparison_disposition_overrides[0].final_disposition = 'rejected'
        Expect-Failure { Measure-Ledger $ledger } "does not match the group's"
        $ledger = New-Ledger; $ledger.adjudication.Remove('comparison_disposition_overrides')
        Expect-Failure { Measure-Ledger $ledger } 'Missing required array'
    }
    Test-Case 'v4-history-roundtrip-and-role-validation' {
        $ledger = New-Ledger
        $historyRoot = Join-Path $testRoot 'v4-history-fixture'
        $runRelative = '.reviews/runs/uncommitted-feature-test_20260909T200400Z_codex-led_44444444'
        $runDirectory = Join-Path $historyRoot $runRelative
        New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        $historyLedgerPath = Join-Path $runDirectory 'adjudication.json'
        $historyMetricsPath = Join-Path $runDirectory 'metrics.json'
        $contextPath = Join-Path $runDirectory 'run-context.json'
        $historyReportPath = Join-Path $runDirectory 'final.md'
        $historyPath = Join-Path $historyRoot '.reviews/codex-led/history.jsonl'
        $globalPath = Join-Path $testRoot 'global.jsonl'
        Write-Json $historyLedgerPath $ledger
        & $measureScript -LedgerPath $historyLedgerPath -OutputPath $historyMetricsPath | Out-Null
        [System.IO.File]::WriteAllText($historyReportPath, '# Complete', [System.Text.UTF8Encoding]::new($false))
        $context = @{ schema_version = 4; review_id = $ledger.review_id; review_mode = $ledger.review_mode
            run_directory = $runRelative
            repository = $ledger.repository; pull_request = $ledger.pull_request; local = $ledger.local
            started_at_unix_ms = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToUnixTimeMilliseconds()
            review_size = @{ review_units = 1; has_changes = $true }; estimate = @{ seconds = 240 }
            tooling = @{ orchestrator = 'codex'; comparison_provider = 'claude'; claude_comparison_effort = 'medium'; adjudicator_model = 'session-fixture' } }
        Write-Json $contextPath $context
        $appendArgs = @{ LedgerPath = $historyLedgerPath; MetricsPath = $historyMetricsPath; RunContextPath = $contextPath; FinalReportPath = $historyReportPath; HistoryPath = $historyPath; GlobalHistoryPath = $globalPath }
        & $appendScript @appendArgs | Out-Null
        & $appendScript @appendArgs | Out-Null
        foreach ($path in @($historyPath, $globalPath)) {
            $lines = @(Get-Content -LiteralPath $path)
            $entry = $lines[0] | ConvertFrom-Json
            if ($lines.Count -ne 1 -or $entry.schema_version -ne 4 -or $entry.tooling.adjudicator_model -ne 'session-fixture' -or $entry.metrics.claude_added_value -ne 1) { throw 'V4 history not preserved' }
        }
        $context.tooling.orchestrator = 'claude'; Write-Json $contextPath $context
        Expect-Failure { & $appendScript @appendArgs } 'disagree on adjudication roles'
    }

    Test-Case 'codex-storage-isolated-and-guarded' {
        $fixtureRepo = Join-Path $testRoot 'repository'
        New-Item -ItemType Directory -Path $fixtureRepo | Out-Null
        & git -C $fixtureRepo init -q
        if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize storage fixture' }
        $claude = & $storageScript -RepositoryPath $fixtureRepo | ConvertFrom-Json
        $codex = & $storageScript -RepositoryPath $fixtureRepo -Variant codex-led | ConvertFrom-Json
        if ($claude.history_path -eq $codex.history_path -or $claude.runs_directory -ne $codex.runs_directory -or
            (Test-Path -LiteralPath (Join-Path $fixtureRepo '.reviews'))) { throw 'Storage isolation or read-only preflight failed' }
        # A blocked Codex-led history does not block the Claude-led validator.
        New-Item -ItemType Directory -Path $codex.history_path -Force | Out-Null
        Expect-Failure { & $storageScript -RepositoryPath $fixtureRepo -Variant codex-led } 'regular file'
        & $storageScript -RepositoryPath $fixtureRepo | Out-Null
        Remove-Item -LiteralPath $codex.history_path -Force
        $run = & $runDirectoryScript -RepositoryPath $fixtureRepo -Variant codex-led -ReviewMode pull_request -PullRequestId 42 `
            -ReviewId ([Guid]::NewGuid()) -StartedAt '2026-09-18T14:25:01Z' | ConvertFrom-Json
        if ((Split-Path -Parent $run.run_directory) -ne $codex.runs_directory -or $run.name -notlike 'pr-42_20260918T142501Z_codex-led_*') {
            throw "Codex-led run folder was not created under the shared runs folder: '$($run.run_directory)'"
        }
        New-Item -ItemType Directory -Path (Join-Path $run.run_directory 'claude-evaluation.md') | Out-Null
        Expect-Failure { & $storageScript -RepositoryPath $fixtureRepo -Variant codex-led -RunDirectory $run.run_directory } 'regular file'
    }
    Test-Case 'supervisor-concurrent-start-and-argument-preservation' {
        $firstReady = Join-Path $testRoot 'first-ready'; $secondReady = Join-Path $testRoot 'second-ready'
        $literal = 'spaces "quotes" $dollars & punctuation'
        $stdinEvidence = 'stdin José — 検証'
        $first = New-Probe 'first' @('-Mode', 'rendezvous', '-ReadyPath', $firstReady, '-PeerPath', $secondReady, '-EchoText', $literal) $stdinEvidence
        $second = New-Probe 'second' @('-Mode', 'rendezvous', '-ReadyPath', $secondReady, '-PeerPath', $firstReady)
        & $runner -InvocationPath $first,$second -TimeoutSeconds 15 | Out-Null
        $output = Get-Content -LiteralPath ($first + '.stdout') -Raw
        if (-not $output.Contains($literal) -or -not $output.Contains($stdinEvidence)) { throw 'Arguments or UTF-8 stdin were altered' }
    }
    Test-Case 'supervisor-drains-both-streams' {
        $probe = New-Probe 'flood' @('-Mode', 'flood')
        & $runner -InvocationPath $probe -TimeoutSeconds 10 | Out-Null
        if ((Get-Item -LiteralPath ($probe + '.stdout')).Length -lt 200000 -or (Get-Item -LiteralPath ($probe + '.stderr')).Length -lt 200000) { throw 'Output was lost' }
    }
    Test-Case 'supervisor-bounds-post-exit-drain-when-child-holds-pipes' {
        $probe = New-Probe 'hold-open' @('-Mode', 'hold-open')
        $warnings = @()
        $timer = [Diagnostics.Stopwatch]::StartNew()
        & $runner -InvocationPath $probe -TimeoutSeconds 10 -PostExitDrainSeconds 1 -WarningVariable warnings | Out-Null
        $timer.Stop()
        $output = Get-Content -LiteralPath ($probe + '.stdout') -Raw
        if ($timer.Elapsed.TotalSeconds -ge 4 -or -not $output.Contains('parent complete') -or
            -not (@($warnings) -join "`n").Contains('descendant kept an output pipe open')) {
            throw "Exited reviewer was not finalized after its bounded drain period (elapsed=$($timer.Elapsed.TotalSeconds), warnings=$(@($warnings).Count), output=$($output.Trim()))"
        }
    }
    Test-Case 'supervisor-kills-peer-on-failure' {
        $ready = Join-Path $testRoot 'failure-peer-ready'
        $slow = New-Probe 'failure-peer' @('-Mode', 'wait', '-ReadyPath', $ready)
        $bad = New-Probe 'failure' @('-Mode', 'fail', '-PeerPath', $ready)
        Expect-Failure { & $runner -InvocationPath $slow,$bad -TimeoutSeconds 15 } 'Reviewer exited 9'
        Assert-Stopped $ready
    }
    Test-Case 'supervisor-kills-on-timeout' {
        $ready = Join-Path $testRoot 'timeout-ready'
        $slow = New-Probe 'timeout' @('-Mode', 'wait', '-ReadyPath', $ready)
        Expect-Failure { & $runner -InvocationPath $slow -TimeoutSeconds 2 } 'exceeded 2 seconds'
        Assert-Stopped $ready
    }
    Test-Case 'explicit-cancellation-stops-active-reviewer' {
        $ready = Join-Path $testRoot 'explicit-cancel-ready'
        $probe = New-Probe 'explicit-cancel' @('-Mode', 'wait', '-ReadyPath', $ready)
        $info = [Diagnostics.ProcessStartInfo]::new()
        $info.FileName = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $info.UseShellExecute = $false; $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-File', $runner, '-InvocationPath', $probe, '-TimeoutSeconds', '15')) { $info.ArgumentList.Add($argument) }
        $supervisor = [Diagnostics.Process]::Start($info)
        $stdout = $supervisor.StandardOutput.ReadToEndAsync(); $stderr = $supervisor.StandardError.ReadToEndAsync()
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(8)
            while (-not (Test-Path -LiteralPath $ready)) {
                if ($supervisor.HasExited -or [DateTime]::UtcNow -ge $deadline) { throw 'Cancellation probe failed to start' }
                Start-Sleep -Milliseconds 25
            }
            & $stopper -InvocationPath $probe | Out-Null
            if (-not $supervisor.WaitForExit(5000)) { throw 'Supervisor did not exit after explicit cancellation' }
            Assert-Stopped $ready
            if ($supervisor.ExitCode -eq 0) { throw 'Cancelled supervisor reported success' }
        } finally {
            if (-not $supervisor.HasExited) { $supervisor.Kill($true); $supervisor.WaitForExit() }
            $supervisor.Dispose()
        }
    }
    Test-Case 'cancellation-before-start-and-stale-pid-guard' {
        $ready = Join-Path $testRoot 'never-started'
        $probe = New-Probe 'pre-cancelled' @('-Mode', 'wait', '-ReadyPath', $ready)
        # Deliberately stale identity must not stop the current test process.
        Write-Json ($probe + '.process.json') @{ process_id = $PID; started_at_ticks = 1 }
        & $stopper -InvocationPath $probe | Out-Null
        Expect-Failure { & $runner -InvocationPath $probe -TimeoutSeconds 2 } 'was cancelled'
        if (Test-Path -LiteralPath $ready) { throw 'Cancelled invocation started anyway' }
    }
} finally {
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedRoot.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        -not ([IO.Path]::GetFileName($resolvedRoot).StartsWith('cross-review-codex-tests-'))) { throw 'Unsafe test cleanup path' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
Write-Host "Codex: $passed passed, $failed failed"
if ($failed -gt 0) { throw "$failed Codex tests failed." }
[pscustomobject]@{ passed = $passed; failed = $failed }
