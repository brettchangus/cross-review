[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$startingLocation = (Get-Location).Path
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("cross-review-tests-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$repositoryDirectory = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installScript = Join-Path $repositoryDirectory 'Install-Skill.ps1'
$skillDirectory = Join-Path $testRoot 'installed skill/cross-review'
$measureScript = Join-Path $skillDirectory 'scripts/Measure-ReviewEffectiveness.ps1'
$appendScript = Join-Path $skillDirectory 'scripts/Append-ReviewHistory.ps1'
$estimateScript = Join-Path $skillDirectory 'scripts/Get-ReviewEstimate.ps1'
$resolverScript = Join-Path $skillDirectory 'scripts/Resolve-AdoPr.ps1'
$excludeScript = Join-Path $skillDirectory 'scripts/Initialize-ReviewExclusion.ps1'
$modelInfoScript = Join-Path $skillDirectory 'scripts/Get-ReviewModelInfo.ps1'
$codexInvocationScript = Join-Path $skillDirectory 'scripts/New-CodexReviewInvocation.ps1'
$storageSafetyScript = Join-Path $skillDirectory 'scripts/Assert-ReviewStorageSafe.ps1'
$runDirectoryScript = Join-Path $skillDirectory 'scripts/New-ReviewRunDirectory.ps1'
$workspaceScript = Join-Path $skillDirectory 'scripts/Remove-ReviewWorkspace.ps1'
$confirmationScript = Join-Path $skillDirectory 'scripts/Resolve-ReviewConfirmation.ps1'
$skillPath = Join-Path $skillDirectory 'SKILL.md'
$passed = 0
$failed = 0

function Write-JsonFile {
    param([string]$Path, $Value)
    [System.IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 15), [System.Text.UTF8Encoding]::new($false))
}

function Invoke-TestGit {
    param([string]$RepositoryPath, [string[]]$Arguments)
    $output = @(& git -C $RepositoryPath @Arguments 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "Test Git command failed: git $($Arguments -join ' ')`n$($output -join [Environment]::NewLine)" }
    return @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
}

function New-TestLedger {
    param(
        [object[]]$Findings,
        [object[]]$Groups,
        [object[]]$Overrides = @(),
        [ValidateSet('pull_request', 'uncommitted', 'branch')][string]$ReviewMode = 'pull_request'
    )
    $headCommit = '1111111111111111111111111111111111111111'
    $targetCommit = '2222222222222222222222222222222222222222'
    $scope = switch ($ReviewMode) {
        'uncommitted' {
            [ordered]@{ id = $null; source_ref = 'WORKTREE'; target_ref = 'HEAD'; source_commit = $headCommit; target_commit = $headCommit }
        }
        'branch' {
            [ordered]@{ id = $null; source_ref = 'refs/heads/feature/sample'; target_ref = 'refs/heads/main'; source_commit = $headCommit; target_commit = $targetCommit }
        }
        default {
            [ordered]@{ id = 1234; source_ref = 'refs/heads/feature/sample'; target_ref = 'refs/heads/main'; source_commit = $headCommit; target_commit = $targetCommit }
        }
    }
    return [pscustomobject][ordered]@{
        schema_version = 3
        review_id = [Guid]::NewGuid().ToString()
        review_mode = $ReviewMode
        status = 'complete'
        repository = [ordered]@{
            id = 'repo-1'; name = 'sample-repo'; url = 'https://dev.azure.com/org/project/_git/sample-repo'
            project_id = 'project-1'; project_name = 'Sample Project'
        }
        pull_request = $scope
        local = [ordered]@{ branch = 'feature/sample'; head_commit = $headCommit }
        findings = @($Findings)
        groups = @($Groups)
        adjudication = [ordered]@{ codex_disposition_overrides = @($Overrides) }
    }
}

function Invoke-PassTest {
    param([string]$Name, $Ledger, [scriptblock]$Assert)
    $ledgerPath = Join-Path $testRoot ($Name + '-ledger.json')
    $outputPath = Join-Path $testRoot ($Name + '-metrics.json')
    [System.IO.File]::WriteAllText($ledgerPath, ($Ledger | ConvertTo-Json -Depth 15), [System.Text.UTF8Encoding]::new($false))
    try {
        & $measureScript -LedgerPath $ledgerPath -OutputPath $outputPath | Out-Null
        $metrics = Get-Content -LiteralPath $outputPath -Raw | ConvertFrom-Json
        & $Assert $metrics
        $script:passed++
        Write-Output "PASS $Name"
    } catch {
        $script:failed++
        Write-Output "FAIL $Name - $($_.Exception.Message)"
    }
}

function Invoke-FailTest {
    param([string]$Name, $Ledger, [string]$ExpectedMessage)
    $ledgerPath = Join-Path $testRoot ($Name + '-ledger.json')
    $outputPath = Join-Path $testRoot ($Name + '-metrics.json')
    [System.IO.File]::WriteAllText($ledgerPath, ($Ledger | ConvertTo-Json -Depth 15), [System.Text.UTF8Encoding]::new($false))
    try {
        & $measureScript -LedgerPath $ledgerPath -OutputPath $outputPath | Out-Null
        $script:failed++
        Write-Output "FAIL $Name - expected validation failure"
    } catch {
        if ($_.Exception.Message -like "*$ExpectedMessage*") {
            $script:passed++
            Write-Output "PASS $Name"
        } else {
            $script:failed++
            Write-Output "FAIL $Name - unexpected error: $($_.Exception.Message)"
        }
    }
}

try {
    # All behavioral tests below exercise a standalone installed copy.
    Push-Location $testRoot
    try { $installation = & $installScript -HostApp Claude -DestinationPath 'installed skill/cross-review' }
    finally { Pop-Location }
    try {
        $expectedFiles = 0
        foreach ($sourceDirectory in @((Join-Path $repositoryDirectory 'shared'), (Join-Path $repositoryDirectory 'skills/claude/cross-review'))) {
            foreach ($file in Get-ChildItem -LiteralPath $sourceDirectory -File -Recurse -Force) {
                $relativePath = $file.FullName.Substring($sourceDirectory.Length).TrimStart('\', '/')
                $installedPath = Join-Path $skillDirectory $relativePath
                if (-not (Test-Path -LiteralPath $installedPath -PathType Leaf) -or
                    (Get-FileHash -LiteralPath $installedPath).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) {
                    throw "Installed resource differs from source: $relativePath"
                }
                $expectedFiles++
            }
        }
        if ($installation.file_count -ne $expectedFiles -or
            @(Get-ChildItem -LiteralPath $skillDirectory -File -Recurse -Force).Count -ne $expectedFiles) {
            throw 'Unexpected installed file count'
        }
        $script:passed++
        Write-Output 'PASS install-self-contained-byte-preserving-package'
    } catch {
        $script:failed++
        Write-Output "FAIL install-self-contained-byte-preserving-package - $($_.Exception.Message)"
    }

    try {
        $expectedHash = (Get-FileHash -LiteralPath $skillPath).Hash
        $stalePath = Join-Path $skillDirectory 'scripts/Stale-Removed.ps1'
        Set-Content -LiteralPath $stalePath -Value 'stale'
        Add-Content -LiteralPath $skillPath -Value 'locally modified'
        $replacement = & $installScript -HostApp Claude -DestinationPath $skillDirectory
        if (-not $replacement.replaced) { throw 'Replacement was not reported' }
        if ((Get-FileHash -LiteralPath $skillPath).Hash -ne $expectedHash) { throw 'Existing installation was not replaced' }
        if (Test-Path -LiteralPath $stalePath) { throw 'Stale file survived replacement' }
        if (@(Get-ChildItem -LiteralPath (Split-Path -Parent $skillDirectory) -Force).Count -ne 1) {
            throw 'Staging or previous installation directory was left behind'
        }
        $script:passed++
        Write-Output 'PASS install-replaces-existing-installation'
    } catch {
        $script:failed++
        Write-Output "FAIL install-replaces-existing-installation - $($_.Exception.Message)"
    }

    try {
        $unrelatedDestination = Join-Path $testRoot 'unrelated directory'
        New-Item -ItemType Directory -Path $unrelatedDestination | Out-Null
        $unrelatedFile = Join-Path $unrelatedDestination 'keep.txt'
        Set-Content -LiteralPath $unrelatedFile -Value 'keep'
        $rejected = $false
        try { & $installScript -HostApp Claude -DestinationPath $unrelatedDestination | Out-Null }
        catch {
            if ($_.Exception.Message -notlike '*not a cross-review installation*') { throw }
            $rejected = $true
        }
        if (-not $rejected -or -not (Test-Path -LiteralPath $unrelatedFile) -or
            @(Get-ChildItem -LiteralPath $unrelatedDestination -Force).Count -ne 1) {
            throw 'Unrelated destination was modified'
        }
        $script:passed++
        Write-Output 'PASS install-refuses-unrelated-destination'
    } catch {
        $script:failed++
        Write-Output "FAIL install-refuses-unrelated-destination - $($_.Exception.Message)"
    }

    # An isolated source tree tests missing hosts and duplicate resource paths
    # without modifying this repository or relying on Codex remaining absent.
    $fixtureRoot = Join-Path $testRoot 'installer source'
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    $fixtureInstaller = Join-Path $fixtureRoot 'Install-Skill.ps1'
    Copy-Item -LiteralPath $installScript -Destination $fixtureInstaller
    try {
        $missingDestination = Join-Path $testRoot 'missing host output'
        $rejected = $false
        try { & $fixtureInstaller -HostApp Codex -DestinationPath $missingDestination | Out-Null }
        catch {
            if ($_.Exception.Message -notlike '*implementation is not available*') { throw }
            $rejected = $true
        }
        if (-not $rejected -or (Test-Path -LiteralPath $missingDestination)) { throw 'Missing host created an installation' }
        $script:passed++
        Write-Output 'PASS install-missing-host-no-writes'
    } catch {
        $script:failed++
        Write-Output "FAIL install-missing-host-no-writes - $($_.Exception.Message)"
    }

    try {
        $fixtureHost = Join-Path $fixtureRoot 'skills/claude/cross-review'
        $fixtureShared = Join-Path $fixtureRoot 'shared'
        New-Item -ItemType Directory -Path $fixtureHost, $fixtureShared | Out-Null
        Copy-Item -LiteralPath $skillPath -Destination (Join-Path $fixtureHost 'SKILL.md')
        Copy-Item -LiteralPath $skillPath -Destination (Join-Path $fixtureShared 'SKILL.md')
        $collisionDestination = Join-Path $testRoot 'collision output'
        $rejected = $false
        try { & $fixtureInstaller -HostApp Claude -DestinationPath $collisionDestination | Out-Null }
        catch {
            if ($_.Exception.Message -notlike '*resources collide*') { throw }
            $rejected = $true
        }
        if (-not $rejected -or (Test-Path -LiteralPath $collisionDestination)) { throw 'Resource collision was not rejected before writing' }
        $script:passed++
        Write-Output 'PASS install-rejects-resource-collisions'
    } catch {
        $script:failed++
        Write-Output "FAIL install-rejects-resource-collisions - $($_.Exception.Message)"
    }

    Invoke-PassTest 'zero-findings' (New-TestLedger @() @()) {
        param($metrics)
        if ($metrics.initial.claude.total -ne 0 -or $metrics.final.total -ne 0 -or $null -ne $metrics.metrics.claude_precision) { throw 'zero-finding metrics are incorrect' }
    }

    $uncommittedNoRemoteLedger = New-TestLedger @() @() @() 'uncommitted'
    $uncommittedNoRemoteLedger.repository.url = ''
    Invoke-PassTest 'uncommitted-mode-ledger' $uncommittedNoRemoteLedger {
        param($metrics)
        if ($metrics.review_mode -ne 'uncommitted') { throw 'uncommitted mode was not retained' }
    }

    Invoke-PassTest 'branch-mode-ledger' (New-TestLedger @() @() @() 'branch') {
        param($metrics)
        if ($metrics.review_mode -ne 'branch') { throw 'branch mode was not retained' }
    }

    $isolatedPrLedger = New-TestLedger @() @()
    $isolatedPrLedger.pull_request.source_commit = '3333333333333333333333333333333333333333'
    Invoke-PassTest 'isolated-pr-source-commit' $isolatedPrLedger {
        param($metrics)
        if ($metrics.review_mode -ne 'pull_request') { throw 'PR mode was not retained' }
    }

    $invalidBranchBase = New-TestLedger @() @() @() 'branch'
    $invalidBranchBase.pull_request.target_ref = 'refs/heads/develop'
    Invoke-FailTest 'branch-invalid-default-base' $invalidBranchBase 'must identify main or master'

    $allRejected = New-TestLedger @(
        [pscustomobject]@{ id = 'C-001'; reviewer = 'claude'; severity = 'high' },
        [pscustomobject]@{ id = 'X-001'; reviewer = 'codex'; severity = 'low' }
    ) @(
        [pscustomobject]@{ id = 'G-001'; source_ids = @('C-001'); disposition = 'rejected' },
        [pscustomobject]@{ id = 'G-002'; source_ids = @('X-001'); disposition = 'rejected' }
    )
    Invoke-PassTest 'all-rejected' $allRejected {
        param($metrics)
        if ($metrics.resolution.rejected_false_positives -ne 2 -or $metrics.final.total -ne 0) { throw 'all-rejected metrics are incorrect' }
    }

    $duplicateId = New-TestLedger @(
        [pscustomobject]@{ id = 'C-001'; reviewer = 'claude'; severity = 'high' },
        [pscustomobject]@{ id = 'C-001'; reviewer = 'claude'; severity = 'low' }
    ) @([pscustomobject]@{ id = 'G-001'; source_ids = @('C-001'); disposition = 'rejected' })
    Invoke-FailTest 'duplicate-id' $duplicateId 'Duplicate finding ID'

    $twoGroups = New-TestLedger @([pscustomobject]@{ id = 'C-001'; reviewer = 'claude'; severity = 'high' }) @(
        [pscustomobject]@{ id = 'G-001'; source_ids = @('C-001'); disposition = 'rejected' },
        [pscustomobject]@{ id = 'G-002'; source_ids = @('C-001'); disposition = 'uncertain' }
    )
    Invoke-FailTest 'id-in-two-groups' $twoGroups 'appears in more than one group'

    $missingSeverity = New-TestLedger @([pscustomobject]@{ id = 'X-001'; reviewer = 'codex'; severity = 'medium' }) @(
        [pscustomobject]@{ id = 'G-001'; source_ids = @('X-001'); disposition = 'confirmed' }
    )
    Invoke-FailTest 'confirmed-without-severity' $missingSeverity 'requires a valid final_severity'

    $missingGroups = New-TestLedger @() @()
    $missingGroups.PSObject.Properties.Remove('groups')
    Invoke-FailTest 'missing-groups' $missingGroups 'Missing required array: groups'

    $missingSourceCommit = New-TestLedger @() @()
    $missingSourceCommit.pull_request.Remove('source_commit')
    Invoke-FailTest 'missing-source-commit' $missingSourceCommit 'pull_request.source_commit'

    $overrideFinding = @([pscustomobject]@{ id = 'X-001'; reviewer = 'codex'; severity = 'medium' })
    $overrideGroups = @([pscustomobject]@{ id = 'G-001'; source_ids = @('X-001'); disposition = 'confirmed'; final_severity = 'medium' })
    $unknownOverride = @([pscustomobject]@{ group_id = 'G-999'; codex_disposition = 'rejected'; final_disposition = 'confirmed'; reason = 'Source evidence confirms it.' })
    Invoke-FailTest 'override-unknown-group' (New-TestLedger $overrideFinding $overrideGroups $unknownOverride) 'unknown group'

    $duplicateOverride = @(
        [pscustomobject]@{ group_id = 'G-001'; codex_disposition = 'rejected'; final_disposition = 'confirmed'; reason = 'First record.' },
        [pscustomobject]@{ group_id = 'G-001'; codex_disposition = 'uncertain'; final_disposition = 'confirmed'; reason = 'Second record.' }
    )
    Invoke-FailTest 'override-duplicate-group' (New-TestLedger $overrideFinding $overrideGroups $duplicateOverride) 'more than one adjudication override'

    $unchangedOverride = @([pscustomobject]@{ group_id = 'G-001'; codex_disposition = 'confirmed'; final_disposition = 'confirmed'; reason = 'No actual change.' })
    Invoke-FailTest 'override-without-change' (New-TestLedger $overrideFinding $overrideGroups $unchangedOverride) 'does not change the disposition'

    $mismatchedOverride = @([pscustomobject]@{ group_id = 'G-001'; codex_disposition = 'confirmed'; final_disposition = 'rejected'; reason = 'Does not match ledger.' })
    Invoke-FailTest 'override-final-mismatch' (New-TestLedger $overrideFinding $overrideGroups $mismatchedOverride) "does not match the group's final disposition"

    $mergedCorrect = New-TestLedger @(
        [pscustomobject]@{ id = 'C-001'; reviewer = 'claude'; severity = 'high' },
        [pscustomobject]@{ id = 'C-002'; reviewer = 'claude'; severity = 'medium' },
        [pscustomobject]@{ id = 'X-001'; reviewer = 'codex'; severity = 'high' }
    ) @(
        [pscustomobject]@{ id = 'G-001'; source_ids = @('C-001', 'C-002', 'X-001'); disposition = 'confirmed'; final_severity = 'high' }
    )
    Invoke-PassTest 'merged-confirmed-precision' $mergedCorrect {
        param($metrics)
        if ($metrics.metrics.claude_precision -ne 1.0 -or $metrics.metrics.codex_precision -ne 1.0 -or $metrics.resolution.merged_duplicates -ne 2) {
            throw 'merged confirmed IDs should retain full per-finding precision'
        }
    }

    $modelDoctorPath = Join-Path $testRoot 'codex-doctor-model.json'
    $modelDoctor = [ordered]@{
        schemaVersion = 1
        checks = [ordered]@{
            'config.load' = [ordered]@{
                details = [ordered]@{ model = 'gpt-5.6-sol'; model_reasoning_effort = 'high' }
            }
        }
    }
    Write-JsonFile $modelDoctorPath $modelDoctor
    try {
        $modelInfo = & $modelInfoScript -ClaudeModel 'claude-opus-4-7' -ClaudeEffort 'xhigh' -CodexDoctorJsonPath $modelDoctorPath | ConvertFrom-Json
        if ($modelInfo.claude.model -ne 'claude-opus-4-7' -or $modelInfo.claude.effort -ne 'xhigh' -or
            $modelInfo.codex.model -ne 'gpt-5.6-sol' -or $modelInfo.codex.reasoning_effort -ne 'high' -or
            $modelInfo.codex.model_source -ne 'codex_doctor' -or $modelInfo.codex.reasoning_effort_source -ne 'codex_doctor') {
            throw 'resolved model or effort information is incorrect'
        }
        $script:passed++
        Write-Output 'PASS model-info-resolved'
    } catch {
        $script:failed++
        Write-Output "FAIL model-info-resolved - $($_.Exception.Message)"
    }

    $defaultDoctorPath = Join-Path $testRoot 'codex-doctor-default.json'
    $defaultDoctor = [ordered]@{
        schemaVersion = 1
        checks = [ordered]@{
            'config.load' = [ordered]@{
                details = [ordered]@{ model = '<default>'; model_reasoning_effort = '<default>' }
            }
        }
    }
    Write-JsonFile $defaultDoctorPath $defaultDoctor
    try {
        $defaultModelInfo = & $modelInfoScript -CodexDoctorJsonPath $defaultDoctorPath | ConvertFrom-Json
        if ($null -ne $defaultModelInfo.claude.model -or $null -ne $defaultModelInfo.claude.effort -or
            $null -ne $defaultModelInfo.codex.model -or $null -ne $defaultModelInfo.codex.reasoning_effort -or
            $defaultModelInfo.codex.model_source -ne 'cli_default_unresolved' -or $defaultModelInfo.codex.reasoning_effort_source -ne 'cli_default_unresolved') {
            throw 'unresolved defaults must remain null and explicitly labeled'
        }
        $script:passed++
        Write-Output 'PASS model-info-unresolved-defaults'
    } catch {
        $script:failed++
        Write-Output "FAIL model-info-unresolved-defaults - $($_.Exception.Message)"
    }

    try {
        $explicitEffortInfo = & $modelInfoScript -ClaudeModel 'claude-opus-4-7' -ClaudeEffort 'high' -ClaudeEffortSource explicit -CodexDoctorJsonPath $defaultDoctorPath | ConvertFrom-Json
        if ($explicitEffortInfo.claude.effort -ne 'high' -or $explicitEffortInfo.claude.effort_source -ne 'explicit' -or
            $explicitEffortInfo.claude.model_source -ne 'session_context') {
            throw 'explicit /code-review level must be labeled explicit while the session model stays session_context'
        }
        $sourceWithoutValue = & $modelInfoScript -ClaudeEffortSource explicit -CodexDoctorJsonPath $defaultDoctorPath | ConvertFrom-Json
        if ($null -ne $sourceWithoutValue.claude.effort -or $sourceWithoutValue.claude.effort_source -ne 'unavailable') {
            throw 'an explicit source without a value must report unavailable'
        }
        $script:passed++
        Write-Output 'PASS model-info-explicit-claude-effort'
    } catch {
        $script:failed++
        Write-Output "FAIL model-info-explicit-claude-effort - $($_.Exception.Message)"
    }

    try {
        foreach ($response in @('y', 'Y', 'yes', ' YES ')) {
            $decision = & $confirmationScript -Response $response | ConvertFrom-Json
            if (-not $decision.approved -or $decision.decision -ne 'continue' -or $decision.reason -ne 'explicit_yes') {
                throw "affirmative response '$response' was not approved"
            }
        }
        foreach ($response in @('n', 'no', '', 'escape', 'continue', 'maybe')) {
            $decision = & $confirmationScript -Response $response | ConvertFrom-Json
            if ($decision.approved -or $decision.decision -ne 'quit') { throw "non-affirmative response '$response' was approved" }
        }
        $cancelledDecision = & $confirmationScript -Response yes -Cancelled | ConvertFrom-Json
        if ($cancelledDecision.approved -or $cancelledDecision.reason -ne 'cancelled') { throw 'cancelled confirmation was approved' }
        $script:passed++
        Write-Output 'PASS confirmation-fails-closed'
    } catch {
        $script:failed++
        Write-Output "FAIL confirmation-fails-closed - $($_.Exception.Message)"
    }

    try {
        # Asserts the ordering contract, not the sentences that express it: wherever the skill
        # removes the review worktree, ExitWorktree must come first. The behaviour itself is
        # covered by remove-review-workspace-from-inside.
        $skillText = Get-Content -LiteralPath $skillPath -Raw
        $exitCalls = @([regex]::Matches($skillText, 'ExitWorktree'))
        $removalCalls = @([regex]::Matches($skillText, 'Remove-ReviewWorkspace\.ps1'))
        if ($exitCalls.Count -lt 2 -or $removalCalls.Count -lt 2) {
            throw 'the skill must name both ExitWorktree and the removal script in the invariants and in the final step'
        }
        if ($exitCalls[0].Index -gt $removalCalls[0].Index) {
            throw 'post-entry cleanup must return the session with ExitWorktree before removing the worktree'
        }
        if ($skillText -notmatch 'ExitWorktree` using `action: "keep"`') {
            throw 'cleanup must use ExitWorktree action keep, which never deletes a worktree entered by path'
        }
        if ($skillText -match 'git -C <repository-root> worktree remove') {
            throw 'worktree removal must go through Remove-ReviewWorkspace.ps1, not a bare git command'
        }
        $script:passed++
        Write-Output 'PASS worktree-post-entry-cleanup-order'
    } catch {
        $script:failed++
        Write-Output "FAIL worktree-post-entry-cleanup-order - $($_.Exception.Message)"
    }

    try {
        # Asserts that the background Codex task is tracked and stopped, not the sentences that
        # say so: the task ID must be named at launch, on the stop paths and where it is cleared,
        # and TaskStop must appear in the invariants and in a step 4 failure path.
        $skillText = Get-Content -LiteralPath $skillPath -Raw
        if (@([regex]::Matches($skillText, 'codex_review_task_id')).Count -lt 3) {
            throw 'the Codex task ID must be retained at launch, used by a stop path, and cleared once the review completes'
        }
        if (@([regex]::Matches($skillText, 'TaskStop')).Count -lt 2) {
            throw 'TaskStop must appear in the invariants and in the Claude review failure path'
        }
        if ($skillText -notmatch 'clear it once that review completes') {
            throw 'a completed Codex review must clear the retained task ID so cleanup does not stop a finished task'
        }
        $script:passed++
        Write-Output 'PASS background-codex-failure-cleanup-order'
    } catch {
        $script:failed++
        Write-Output "FAIL background-codex-failure-cleanup-order - $($_.Exception.Message)"
    }

    $prBaseCommit = '2222222222222222222222222222222222222222'
    $branchBaseCommit = '3333333333333333333333333333333333333333'
    $reviewWorkspace = 'C:\temp\review-workspace'
    try {
        $prInvocation = & $codexInvocationScript -ReviewMode pull_request -BaseCommit $prBaseCommit -WorkingDirectory $reviewWorkspace -OutputPath 'C:\temp\codex-independent.md' -Model 'gpt-5.6-sol' -ReasoningEffort high | ConvertFrom-Json
        $branchInvocation = & $codexInvocationScript -ReviewMode branch -BaseCommit $branchBaseCommit -WorkingDirectory $reviewWorkspace -OutputPath 'C:\temp\codex-branch.md' | ConvertFrom-Json
        $uncommittedInvocation = & $codexInvocationScript -ReviewMode uncommitted -WorkingDirectory $reviewWorkspace -OutputPath 'C:\temp\codex-uncommitted.md' | ConvertFrom-Json
        $prArguments = @($prInvocation.arguments | ForEach-Object { [string]$_ })
        $branchArguments = @($branchInvocation.arguments | ForEach-Object { [string]$_ })
        $uncommittedArguments = @($uncommittedInvocation.arguments | ForEach-Object { [string]$_ })

        if ($prInvocation.positional_prompt -ne $false -or $branchInvocation.positional_prompt -ne $false -or $uncommittedInvocation.positional_prompt -ne $false -or
            $prInvocation.sandbox -ne 'read-only' -or $prInvocation.ephemeral -ne $true -or
            $prInvocation.PSObject.Properties.Name -contains 'json_events' -or $prInvocation.PSObject.Properties.Name -contains 'approval_policy' -or
            $prInvocation.working_directory -ne $reviewWorkspace -or $uncommittedInvocation.working_directory -ne $reviewWorkspace) {
            throw 'scoped review invocation must prohibit a positional prompt, enforce an ephemeral read-only sandbox, and record the pinned workspace'
        }
        if (($prArguments -join '|') -ne ('exec|--cd|{1}|--sandbox|read-only|--ephemeral|--model|gpt-5.6-sol|-c|model_reasoning_effort="high"|review|--base|{0}|--output-last-message|C:\temp\codex-independent.md' -f $prBaseCommit, $reviewWorkspace)) {
            throw 'PR invocation arguments are incorrect'
        }
        if (($branchArguments -join '|') -ne ('exec|--cd|{1}|--sandbox|read-only|--ephemeral|review|--base|{0}|--output-last-message|C:\temp\codex-branch.md' -f $branchBaseCommit, $reviewWorkspace)) {
            throw 'branch invocation arguments are incorrect'
        }
        if (($uncommittedArguments -join '|') -ne ('exec|--cd|{0}|--sandbox|read-only|--ephemeral|review|--uncommitted|--output-last-message|C:\temp\codex-uncommitted.md' -f $reviewWorkspace)) {
            throw 'uncommitted invocation arguments are incorrect'
        }
        $script:passed++
        Write-Output 'PASS codex-scoped-review-invocations'
    } catch {
        $script:failed++
        Write-Output "FAIL codex-scoped-review-invocations - $($_.Exception.Message)"
    }

    try {
        try {
            & $codexInvocationScript -ReviewMode uncommitted -BaseCommit $prBaseCommit -WorkingDirectory $reviewWorkspace -OutputPath 'C:\temp\codex-invalid.md' | Out-Null
            throw 'Expected uncommitted BaseCommit rejection did not occur.'
        } catch {
            if ($_.Exception.Message -notlike '*BaseCommit must be omitted*') { throw }
        }
        try {
            & $codexInvocationScript -ReviewMode branch -WorkingDirectory $reviewWorkspace -OutputPath 'C:\temp\codex-invalid.md' | Out-Null
            throw 'Expected missing branch BaseCommit rejection did not occur.'
        } catch {
            if ($_.Exception.Message -notlike '*BaseCommit is required*') { throw }
        }
        try {
            & $codexInvocationScript -ReviewMode branch -BaseCommit $branchBaseCommit -OutputPath 'C:\temp\codex-invalid.md' | Out-Null
            throw 'Expected missing WorkingDirectory rejection did not occur.'
        } catch {
            if ($_.Exception.Message -notlike '*WorkingDirectory must not be empty*') { throw }
        }
        foreach ($mutableBase in @('origin/main', 'refs/remotes/origin/main', 'main', '--upload-pack=malicious', '2222222')) {
            try {
                & $codexInvocationScript -ReviewMode pull_request -BaseCommit $mutableBase -WorkingDirectory $reviewWorkspace -OutputPath 'C:\temp\codex-invalid.md' | Out-Null
                throw "Expected mutable base '$mutableBase' rejection did not occur."
            } catch {
                if ($_.Exception.Message -notlike '*not a ref name*') { throw }
            }
        }
        $script:passed++
        Write-Output 'PASS codex-review-invocation-guards'
    } catch {
        $script:failed++
        Write-Output "FAIL codex-review-invocation-guards - $($_.Exception.Message)"
    }

    $historyLedger = New-TestLedger @() @()
    $historyRunRelative = '.reviews/runs/pr-1234_20260909T200000Z_claude-led_9d2c7f15'
    $historyRunDirectory = Join-Path $testRoot $historyRunRelative
    New-Item -ItemType Directory -Path $historyRunDirectory -Force | Out-Null
    $historyLedgerPath = Join-Path $historyRunDirectory 'adjudication.json'
    $historyMetricsPath = Join-Path $historyRunDirectory 'metrics.json'
    $historyContextPath = Join-Path $historyRunDirectory 'run-context.json'
    $historyFinalPath = Join-Path $historyRunDirectory 'final.md'
    $localHistoryPath = Join-Path $testRoot '.reviews/history.jsonl'
    $globalHistoryPath = Join-Path $testRoot 'global-history.jsonl'
    [System.IO.File]::WriteAllText($historyLedgerPath, ($historyLedger | ConvertTo-Json -Depth 15), [System.Text.UTF8Encoding]::new($false))
    & $measureScript -LedgerPath $historyLedgerPath -OutputPath $historyMetricsPath | Out-Null
    $startedAt = [DateTimeOffset]::UtcNow.AddMinutes(-40)
    $historyContext = [ordered]@{
        schema_version = 3; review_id = $historyLedger.review_id; review_mode = $historyLedger.review_mode; started_at = $startedAt.ToString('o'); started_at_unix_ms = $startedAt.ToUnixTimeMilliseconds()
        run_directory = $historyRunRelative
        repository = $historyLedger.repository; pull_request = $historyLedger.pull_request; local = $historyLedger.local
        tooling = [ordered]@{
            pr_metadata = 'azure_devops_mcp'; claude_review = 'native_code_review'; codex_review = 'native_codex_exec_review'
            claude_model = 'claude-opus-4-7'; claude_effort = 'xhigh'; claude_model_source = 'session_context'; claude_effort_source = 'session_context'
            codex_model = 'gpt-5.6-sol'; codex_reasoning_effort = 'high'; codex_model_source = 'codex_doctor'; codex_reasoning_effort_source = 'codex_doctor'
            codex_comparison_model = 'gpt-5.6-sol'; codex_comparison_model_source = 'codex_doctor'
            codex_comparison_reasoning_effort = 'medium'; codex_comparison_reasoning_effort_source = 'explicit'
        }
        review_size = [ordered]@{ changed_files = 2; lines_added = 20; lines_deleted = 5; lines_changed = 25; binary_files = 0; commit_count = 1; has_changes = $true; review_units = 90; size_band = 'small' }
        estimate = [ordered]@{ seconds = 240; low_seconds = 120; high_seconds = 420; method = 'bootstrap_heuristic'; historical_runs_used = 0; historical_runs_available = 0; confidence = 'low' }
    }
    [System.IO.File]::WriteAllText($historyContextPath, ($historyContext | ConvertTo-Json -Depth 15), [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($historyFinalPath, '# Complete', [System.Text.UTF8Encoding]::new($false))
    try {
        & $appendScript -LedgerPath $historyLedgerPath -MetricsPath $historyMetricsPath -RunContextPath $historyContextPath -FinalReportPath $historyFinalPath -HistoryPath $localHistoryPath -GlobalHistoryPath $globalHistoryPath | Out-Null
        & $appendScript -LedgerPath $historyLedgerPath -MetricsPath $historyMetricsPath -RunContextPath $historyContextPath -FinalReportPath $historyFinalPath -HistoryPath $localHistoryPath -GlobalHistoryPath $globalHistoryPath | Out-Null
        $localLines = @(Get-Content -LiteralPath $localHistoryPath)
        $globalLines = @(Get-Content -LiteralPath $globalHistoryPath)
        $historyEntry = $localLines[0] | ConvertFrom-Json
        if ($localLines.Count -ne 1 -or $globalLines.Count -ne 1 -or -not $historyEntry.timing.estimation_eligible) { throw 'history append, duplicate protection, or four-hour eligibility is incorrect' }
        if ($historyEntry.tooling.claude_model -ne 'claude-opus-4-7' -or $historyEntry.tooling.claude_effort -ne 'xhigh' -or
            $historyEntry.tooling.codex_model -ne 'gpt-5.6-sol' -or $historyEntry.tooling.codex_reasoning_effort -ne 'high') {
            throw 'model and effort information was not preserved in history'
        }
        if ([string]$historyEntry.completed_at -ne [string]$historyEntry.timing.completed_at) { throw 'completion timestamps must match' }
        if ($historyEntry.run_directory -ne $historyRunRelative) { throw 'run_directory was not preserved in history' }
        foreach ($historyLine in @($localLines[0], $globalLines[0])) {
            $savedTooling = ($historyLine | ConvertFrom-Json).tooling
            if ($savedTooling.codex_reasoning_effort -ne 'high' -or
                $savedTooling.codex_comparison_reasoning_effort -ne 'medium' -or
                $savedTooling.codex_comparison_reasoning_effort_source -ne 'explicit' -or
                $savedTooling.codex_comparison_model -ne 'gpt-5.6-sol' -or
                $savedTooling.codex_comparison_model_source -ne 'codex_doctor') {
                throw 'independent and comparison settings must survive both history appends separately'
            }
        }

        $historyContext.run_directory = '.reviews/runs/wrong-folder'
        Write-JsonFile $historyContextPath $historyContext
        try {
            & $appendScript -LedgerPath $historyLedgerPath -MetricsPath $historyMetricsPath -RunContextPath $historyContextPath -FinalReportPath $historyFinalPath -HistoryPath $localHistoryPath | Out-Null
            throw 'Expected mismatched run_directory rejection did not occur.'
        } catch {
            if ($_.Exception.Message -notlike '*does not match the completed report directory*') { throw }
        }
        $historyContext.Remove('run_directory')
        Write-JsonFile $historyContextPath $historyContext
        try {
            & $appendScript -LedgerPath $historyLedgerPath -MetricsPath $historyMetricsPath -RunContextPath $historyContextPath -FinalReportPath $historyFinalPath -HistoryPath $localHistoryPath | Out-Null
            throw 'Expected missing run_directory rejection did not occur.'
        } catch {
            if ($_.Exception.Message -notlike '*run_directory is required*') { throw }
        }
        $historyContext.run_directory = $historyRunRelative
        Write-JsonFile $historyContextPath $historyContext
        $outsideFinalPath = Join-Path $testRoot 'outside-run-final.md'
        [System.IO.File]::WriteAllText($outsideFinalPath, '# Complete', [System.Text.UTF8Encoding]::new($false))
        try {
            & $appendScript -LedgerPath $historyLedgerPath -MetricsPath $historyMetricsPath -RunContextPath $historyContextPath -FinalReportPath $outsideFinalPath -HistoryPath $localHistoryPath | Out-Null
            throw 'Expected out-of-layout final report rejection did not occur.'
        } catch {
            if ($_.Exception.Message -notlike '*must be stored under a .reviews/runs*') { throw }
        }
        # A ledger or metrics file written to the old fixed location must not be
        # indexed under a run folder that lacks it.
        foreach ($strayName in @('adjudication.json', 'metrics.json', 'run-context.json')) {
            $strayPath = Join-Path $testRoot ".reviews/$strayName"
            Copy-Item -LiteralPath (Join-Path $historyRunDirectory $strayName) -Destination $strayPath
            $strayArguments = @{
                LedgerPath = $historyLedgerPath; MetricsPath = $historyMetricsPath; RunContextPath = $historyContextPath
                FinalReportPath = $historyFinalPath; HistoryPath = (Join-Path $testRoot 'stray-history.jsonl')
            }
            switch ($strayName) {
                'adjudication.json' { $strayArguments.LedgerPath = $strayPath }
                'metrics.json' { $strayArguments.MetricsPath = $strayPath }
                'run-context.json' { $strayArguments.RunContextPath = $strayPath }
            }
            try {
                & $appendScript @strayArguments | Out-Null
                throw "Expected rejection of a stray $strayName did not occur."
            } catch {
                if ($_.Exception.Message -notlike '*must be in the same run folder as the final report*') { throw }
            } finally {
                Remove-Item -LiteralPath $strayPath -Force
            }
            if (Test-Path -LiteralPath $strayArguments.HistoryPath) { throw "a stray $strayName still produced a history entry" }
        }
        $script:passed++
        Write-Output 'PASS append-local-global-history'
    } catch {
        $script:failed++
        Write-Output "FAIL append-local-global-history - $($_.Exception.Message)"
    }

    $partialLedger = New-TestLedger @() @()
    $partialRoot = Join-Path $testRoot 'partial-history-fixture'
    $partialRunRelative = '.reviews/runs/pr-1234_20260909T200100Z_claude-led_11111111'
    $partialRunDirectory = Join-Path $partialRoot $partialRunRelative
    New-Item -ItemType Directory -Path $partialRunDirectory -Force | Out-Null
    $partialLedgerPath = Join-Path $partialRunDirectory 'adjudication.json'
    $partialMetricsPath = Join-Path $partialRunDirectory 'metrics.json'
    $partialContextPath = Join-Path $partialRunDirectory 'run-context.json'
    $partialFinalPath = Join-Path $partialRunDirectory 'final.md'
    $partialLocalPath = Join-Path $partialRoot '.reviews/history.jsonl'
    $blockingParent = Join-Path $testRoot 'global-parent-blocker'
    $partialGlobalPath = Join-Path $blockingParent 'partial-global.jsonl'
    Write-JsonFile $partialLedgerPath $partialLedger
    & $measureScript -LedgerPath $partialLedgerPath -OutputPath $partialMetricsPath | Out-Null
    $partialContext = [ordered]@{
        schema_version = 3; review_id = $partialLedger.review_id; review_mode = $partialLedger.review_mode; started_at = $startedAt.ToString('o'); started_at_unix_ms = $startedAt.ToUnixTimeMilliseconds()
        run_directory = $partialRunRelative
        repository = $partialLedger.repository; pull_request = $partialLedger.pull_request; local = $partialLedger.local
        tooling = $historyContext.tooling; review_size = $historyContext.review_size; estimate = $historyContext.estimate
    }
    Write-JsonFile $partialContextPath $partialContext
    [System.IO.File]::WriteAllText($partialFinalPath, '# Complete', [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText($blockingParent, 'blocks directory creation', [System.Text.UTF8Encoding]::new($false))
    try {
        try {
            & $appendScript -LedgerPath $partialLedgerPath -MetricsPath $partialMetricsPath -RunContextPath $partialContextPath -FinalReportPath $partialFinalPath -HistoryPath $partialLocalPath -GlobalHistoryPath $partialGlobalPath | Out-Null
            throw 'Expected global history append failure did not occur.'
        } catch {
            if ($_.Exception.Message -notlike '*Re-running this same command is safe*') { throw }
        }
        Remove-Item -LiteralPath $blockingParent -Force
        New-Item -ItemType Directory -Path $blockingParent | Out-Null
        & $appendScript -LedgerPath $partialLedgerPath -MetricsPath $partialMetricsPath -RunContextPath $partialContextPath -FinalReportPath $partialFinalPath -HistoryPath $partialLocalPath -GlobalHistoryPath $partialGlobalPath | Out-Null
        if (@(Get-Content -LiteralPath $partialLocalPath).Count -ne 1 -or @(Get-Content -LiteralPath $partialGlobalPath).Count -ne 1) {
            throw 'safe retry did not leave exactly one local and one global entry'
        }
        $script:passed++
        Write-Output 'PASS partial-history-recovery'
    } catch {
        $script:failed++
        Write-Output "FAIL partial-history-recovery - $($_.Exception.Message)"
    }

    $uncommittedLedger = New-TestLedger @() @() @() 'uncommitted'
    $uncommittedLedger.repository.url = ''
    $uncommittedRoot = Join-Path $testRoot 'uncommitted-history-fixture'
    $uncommittedRunRelative = '.reviews/runs/uncommitted-feature-sample_20260909T200200Z_claude-led_22222222'
    $uncommittedRunDirectory = Join-Path $uncommittedRoot $uncommittedRunRelative
    New-Item -ItemType Directory -Path $uncommittedRunDirectory -Force | Out-Null
    $uncommittedLedgerPath = Join-Path $uncommittedRunDirectory 'adjudication.json'
    $uncommittedMetricsPath = Join-Path $uncommittedRunDirectory 'metrics.json'
    $uncommittedContextPath = Join-Path $uncommittedRunDirectory 'run-context.json'
    $uncommittedFinalPath = Join-Path $uncommittedRunDirectory 'final.md'
    $uncommittedHistoryPath = Join-Path $uncommittedRoot '.reviews/history.jsonl'
    Write-JsonFile $uncommittedLedgerPath $uncommittedLedger
    & $measureScript -LedgerPath $uncommittedLedgerPath -OutputPath $uncommittedMetricsPath | Out-Null
    $uncommittedContext = [ordered]@{
        schema_version = 3; review_id = $uncommittedLedger.review_id; review_mode = 'uncommitted'; started_at = $startedAt.ToString('o'); started_at_unix_ms = $startedAt.ToUnixTimeMilliseconds()
        run_directory = $uncommittedRunRelative
        repository = $uncommittedLedger.repository; pull_request = $uncommittedLedger.pull_request; local = $uncommittedLedger.local
        tooling = [ordered]@{ pr_metadata = 'not_queried'; claude_review = 'native_code_review'; codex_review = 'native_codex_exec_review' }
        review_size = $historyContext.review_size; estimate = $historyContext.estimate
    }
    Write-JsonFile $uncommittedContextPath $uncommittedContext
    [System.IO.File]::WriteAllText($uncommittedFinalPath, '# Complete', [System.Text.UTF8Encoding]::new($false))
    try {
        & $appendScript -LedgerPath $uncommittedLedgerPath -MetricsPath $uncommittedMetricsPath -RunContextPath $uncommittedContextPath -FinalReportPath $uncommittedFinalPath -HistoryPath $uncommittedHistoryPath | Out-Null
        $uncommittedHistory = (Get-Content -LiteralPath $uncommittedHistoryPath -Raw).Trim() | ConvertFrom-Json
        if ($uncommittedHistory.review_mode -ne 'uncommitted' -or $null -ne $uncommittedHistory.pull_request.id -or $uncommittedHistory.repository.url -ne '') { throw 'non-PR history scope is incorrect' }
        if ($uncommittedHistory.run_directory -ne $uncommittedRunRelative) { throw 'uncommitted run_directory was not preserved' }
        $script:passed++
        Write-Output 'PASS append-uncommitted-history'
    } catch {
        $script:failed++
        Write-Output "FAIL append-uncommitted-history - $($_.Exception.Message)"
    }

    $longLedger = New-TestLedger @() @()
    $longRoot = Join-Path $testRoot 'long-history-fixture'
    $longRunRelative = '.reviews/runs/pr-1234_20260909T200300Z_claude-led_33333333'
    $longRunDirectory = Join-Path $longRoot $longRunRelative
    New-Item -ItemType Directory -Path $longRunDirectory -Force | Out-Null
    $longLedgerPath = Join-Path $longRunDirectory 'adjudication.json'
    $longMetricsPath = Join-Path $longRunDirectory 'metrics.json'
    $longContextPath = Join-Path $longRunDirectory 'run-context.json'
    $longFinalPath = Join-Path $longRunDirectory 'final.md'
    $longHistoryPath = Join-Path $longRoot '.reviews/history.jsonl'
    Write-JsonFile $longLedgerPath $longLedger
    & $measureScript -LedgerPath $longLedgerPath -OutputPath $longMetricsPath | Out-Null
    $longStartedAt = [DateTimeOffset]::UtcNow.AddHours(-5)
    $longContext = [ordered]@{
        schema_version = 3; review_id = $longLedger.review_id; review_mode = $longLedger.review_mode; started_at = $longStartedAt.ToString('o'); started_at_unix_ms = $longStartedAt.ToUnixTimeMilliseconds()
        run_directory = $longRunRelative
        repository = $longLedger.repository; pull_request = $longLedger.pull_request; local = $longLedger.local
        tooling = $historyContext.tooling; review_size = $historyContext.review_size; estimate = $historyContext.estimate
    }
    Write-JsonFile $longContextPath $longContext
    [System.IO.File]::WriteAllText($longFinalPath, '# Complete', [System.Text.UTF8Encoding]::new($false))
    try {
        & $appendScript -LedgerPath $longLedgerPath -MetricsPath $longMetricsPath -RunContextPath $longContextPath -FinalReportPath $longFinalPath -HistoryPath $longHistoryPath -WarningAction SilentlyContinue | Out-Null
        $longEntry = (Get-Content -LiteralPath $longHistoryPath -Raw).Trim() | ConvertFrom-Json
        if ($longEntry.timing.estimation_eligible -or $longEntry.timing.plausibility_ceiling_seconds -ne 14400) { throw 'five-hour review should be recorded but estimation-ineligible' }
        $script:passed++
        Write-Output 'PASS long-review-ineligible'
    } catch {
        $script:failed++
        Write-Output "FAIL long-review-ineligible - $($_.Exception.Message)"
    }

    try {
        $lock = [System.IO.File]::Open($localHistoryPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $appendJob = Start-Job -ScriptBlock {
                param($Script, $Ledger, $Metrics, $Context, $Final, $Local, $Global)
                & $Script -LedgerPath $Ledger -MetricsPath $Metrics -RunContextPath $Context -FinalReportPath $Final -HistoryPath $Local -GlobalHistoryPath $Global
            } -ArgumentList $appendScript, $historyLedgerPath, $historyMetricsPath, $historyContextPath, $historyFinalPath, $localHistoryPath, $globalHistoryPath
            Start-Sleep -Milliseconds 750
        } finally {
            $lock.Dispose()
        }
        $null = Wait-Job -Job $appendJob -Timeout 15
        if ($appendJob.State -ne 'Completed') { throw "locked-history retry job ended in state '$($appendJob.State)'" }
        Receive-Job -Job $appendJob -ErrorAction Stop | Out-Null
        $script:passed++
        Write-Output 'PASS locked-history-retry'
    } catch {
        $script:failed++
        Write-Output "FAIL locked-history-retry - $($_.Exception.Message)"
    } finally {
        if ($null -ne $appendJob) { Remove-Job -Job $appendJob -Force -ErrorAction SilentlyContinue }
    }

    $repositoryPath = Join-Path $testRoot 'resolver-estimator-repo'
    New-Item -ItemType Directory -Path $repositoryPath | Out-Null
    Invoke-TestGit $repositoryPath @('init') | Out-Null
    Invoke-TestGit $repositoryPath @('config', 'user.email', 'cross-review-tests@example.invalid') | Out-Null
    Invoke-TestGit $repositoryPath @('config', 'user.name', 'Cross Review Tests') | Out-Null
    Invoke-TestGit $repositoryPath @('checkout', '-b', 'feature/sample') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repositoryPath 'base.txt'), "base`n", [System.Text.UTF8Encoding]::new($false))
    Invoke-TestGit $repositoryPath @('add', 'base.txt') | Out-Null
    Invoke-TestGit $repositoryPath @('commit', '-m', 'base') | Out-Null
    $targetCommit = ([string](Invoke-TestGit $repositoryPath @('rev-parse', 'HEAD'))).Trim()
    Invoke-TestGit $repositoryPath @('branch', 'main') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repositoryPath 'change.txt'), ((1..20 | ForEach-Object { "changed line $_" }) -join "`n") + "`n", [System.Text.UTF8Encoding]::new($false))
    Invoke-TestGit $repositoryPath @('add', 'change.txt') | Out-Null
    Invoke-TestGit $repositoryPath @('commit', '-m', 'feature change') | Out-Null
    $sourceCommit = ([string](Invoke-TestGit $repositoryPath @('rev-parse', 'HEAD'))).Trim()
    Invoke-TestGit $repositoryPath @('remote', 'add', 'origin', 'https://dev.azure.com/org/Sample%20Project/_git/sample-repo') | Out-Null

    $prMetadata = [ordered]@{
        pullRequestId = 1234; title = 'Test PR'; status = 'active'
        sourceRefName = 'refs/heads/feature/sample'; targetRefName = 'refs/heads/main'
        repository = [ordered]@{
            id = 'repo-1'; name = 'sample-repo'; webUrl = 'https://dev.azure.com/org/Sample%20Project/_git/sample-repo'
            project = [ordered]@{ id = 'project-1'; name = 'Sample Project' }
        }
        lastMergeSourceCommit = [ordered]@{ commitId = $sourceCommit }
        lastMergeTargetCommit = [ordered]@{ commitId = $targetCommit }
    }
    $metadataPath = Join-Path $testRoot 'resolver-metadata.json'
    Write-JsonFile $metadataPath $prMetadata
    try {
        Push-Location $repositoryPath
        try { $resolved = & $resolverScript -MetadataPath $metadataPath | ConvertFrom-Json }
        finally { Pop-Location }
        if ($resolved.operation -ne 'pr_lookup' -or $resolved.repository_name -ne 'sample-repo' -or $resolved.project_name -ne 'Sample Project' -or $resolved.source_ref -ne 'refs/heads/feature/sample') {
            throw 'resolver returned incorrect normalized identity'
        }
        $script:passed++
        Write-Output 'PASS resolver-https-identity'
    } catch {
        $script:failed++
        Write-Output "FAIL resolver-https-identity - $($_.Exception.Message)"
    }

    $numericStatusMetadata = $prMetadata | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    $numericStatusMetadata.status = 1
    $numericStatusMetadataPath = Join-Path $testRoot 'resolver-numeric-status.json'
    Write-JsonFile $numericStatusMetadataPath $numericStatusMetadata
    try {
        Push-Location $repositoryPath
        try { $numericStatusResult = & $resolverScript -MetadataPath $numericStatusMetadataPath | ConvertFrom-Json }
        finally { Pop-Location }
        if ($numericStatusResult.status -ne 'active') { throw 'numeric Active status was not canonicalized' }
        $script:passed++
        Write-Output 'PASS resolver-numeric-active-status'
    } catch {
        $script:failed++
        Write-Output "FAIL resolver-numeric-active-status - $($_.Exception.Message)"
    }

    $objectStatusMetadata = $prMetadata | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    $objectStatusMetadata.status = [pscustomobject]@{ value = 1; name = 'Active' }
    $objectStatusMetadataPath = Join-Path $testRoot 'resolver-object-status.json'
    Write-JsonFile $objectStatusMetadataPath $objectStatusMetadata
    try {
        Push-Location $repositoryPath
        try { $objectStatusResult = & $resolverScript -MetadataPath $objectStatusMetadataPath | ConvertFrom-Json }
        finally { Pop-Location }
        if ($objectStatusResult.status -ne 'active') { throw 'object-form Active status was not canonicalized' }
        $script:passed++
        Write-Output 'PASS resolver-object-active-status'
    } catch {
        $script:failed++
        Write-Output "FAIL resolver-object-active-status - $($_.Exception.Message)"
    }

    $inactiveNumericMetadata = $prMetadata | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    $inactiveNumericMetadata.status = 2
    $inactiveNumericMetadataPath = Join-Path $testRoot 'resolver-inactive-numeric-status.json'
    Write-JsonFile $inactiveNumericMetadataPath $inactiveNumericMetadata
    try {
        Push-Location $repositoryPath
        try { & $resolverScript -MetadataPath $inactiveNumericMetadataPath | Out-Null }
        finally { Pop-Location }
        $script:failed++
        Write-Output 'FAIL resolver-inactive-numeric-status - expected validation failure'
    } catch {
        if ($_.Exception.Message -like "*is 'abandoned', not active*") {
            $script:passed++
            Write-Output 'PASS resolver-inactive-numeric-status'
        } else {
            $script:failed++
            Write-Output "FAIL resolver-inactive-numeric-status - unexpected error: $($_.Exception.Message)"
        }
    }

    $credentialedMetadata = $prMetadata | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    $credentialedMetadata.repository.webUrl = 'https://example-user:example-value@dev.azure.com/org/Sample%20Project/_git/sample-repo?example_parameter=example-query-value#fragment'
    $credentialedMetadataPath = Join-Path $testRoot 'resolver-credentialed-metadata.json'
    Write-JsonFile $credentialedMetadataPath $credentialedMetadata
    try {
        Push-Location $repositoryPath
        try { $sanitizedMetadataText = & $resolverScript -MetadataPath $credentialedMetadataPath }
        finally { Pop-Location }
        $sanitizedMetadata = $sanitizedMetadataText | ConvertFrom-Json
        if ($sanitizedMetadataText -match 'example-user|example-value|example_parameter|example-query-value' -or
            $sanitizedMetadata.repository_url -ne 'https://dev.azure.com/org/Sample%20Project/_git/sample-repo') {
            throw 'credential-bearing MCP repository URL was not sanitized'
        }
        $script:passed++
        Write-Output 'PASS resolver-sanitizes-mcp-metadata-url'
    } catch {
        $script:failed++
        Write-Output "FAIL resolver-sanitizes-mcp-metadata-url - $($_.Exception.Message)"
    }

    try {
        Push-Location $repositoryPath
        try { $localIdentity = & $resolverScript -LocalOnly | ConvertFrom-Json }
        finally { Pop-Location }
        if ($localIdentity.operation -ne 'local_identity' -or $localIdentity.found -or $localIdentity.metadata_source -ne 'not_used' -or $localIdentity.repository_id -ne 'ado://org/Sample Project/sample-repo') {
            throw 'local-only identity is incorrect'
        }
        $script:passed++
        Write-Output 'PASS resolver-local-only'
    } catch {
        $script:failed++
        Write-Output "FAIL resolver-local-only - $($_.Exception.Message)"
    }

    try {
        Invoke-TestGit $repositoryPath @('remote', 'set-url', 'origin', 'https://example-user:example-value@dev.azure.com/org/Sample%20Project/_git/sample-repo?example_parameter=example-query-value#fragment') | Out-Null
        Push-Location $repositoryPath
        try { $sanitizedAdoIdentityText = & $resolverScript -LocalOnly }
        finally { Pop-Location }
        $sanitizedAdoIdentity = $sanitizedAdoIdentityText | ConvertFrom-Json
        if ($sanitizedAdoIdentityText -match 'example-user|example-value|example_parameter|example-query-value' -or
            $sanitizedAdoIdentity.repository_url -ne 'https://dev.azure.com/org/Sample%20Project/_git/sample-repo') {
            throw 'credential-bearing Azure DevOps origin was not sanitized'
        }
        $script:passed++
        Write-Output 'PASS resolver-sanitizes-ado-origin'
    } catch {
        $script:failed++
        Write-Output "FAIL resolver-sanitizes-ado-origin - $($_.Exception.Message)"
    } finally {
        Invoke-TestGit $repositoryPath @('remote', 'set-url', 'origin', 'https://dev.azure.com/org/Sample%20Project/_git/sample-repo') | Out-Null
    }

    try {
        Invoke-TestGit $repositoryPath @('remote', 'set-url', 'origin', 'https://github.com/example/sample-repo.git') | Out-Null
        Push-Location $repositoryPath
        try { $genericIdentity = & $resolverScript -LocalOnly | ConvertFrom-Json }
        finally { Pop-Location }
        if ($genericIdentity.operation -ne 'local_identity' -or $genericIdentity.repository_id -ne 'remote:https://github.com/example/sample-repo' -or
            $genericIdentity.repository_name -ne 'sample-repo' -or $genericIdentity.project_name -ne '' -or $genericIdentity.repository_url -notlike 'https://github.com/*') {
            throw 'generic remote identity is incorrect'
        }
        $script:passed++
        Write-Output 'PASS resolver-generic-remote'
    } catch {
        $script:failed++
        Write-Output "FAIL resolver-generic-remote - $($_.Exception.Message)"
    } finally {
        Invoke-TestGit $repositoryPath @('remote', 'set-url', 'origin', 'https://dev.azure.com/org/Sample%20Project/_git/sample-repo') | Out-Null
    }

    try {
        Invoke-TestGit $repositoryPath @('remote', 'set-url', 'origin', 'https://example-user:example-value@github.com/example/sample-repo.git?example_parameter=example-query-value#fragment') | Out-Null
        Push-Location $repositoryPath
        try { $sanitizedGenericText = & $resolverScript -LocalOnly }
        finally { Pop-Location }
        $sanitizedGeneric = $sanitizedGenericText | ConvertFrom-Json
        if ($sanitizedGenericText -match 'example-user|example-value|example_parameter|example-query-value' -or
            $sanitizedGeneric.repository_url -ne 'https://github.com/example/sample-repo.git' -or
            $sanitizedGeneric.repository_id -ne 'remote:https://github.com/example/sample-repo') {
            throw 'credential-bearing generic origin was not sanitized'
        }
        $script:passed++
        Write-Output 'PASS resolver-sanitizes-generic-origin'
    } catch {
        $script:failed++
        Write-Output "FAIL resolver-sanitizes-generic-origin - $($_.Exception.Message)"
    } finally {
        Invoke-TestGit $repositoryPath @('remote', 'set-url', 'origin', 'https://dev.azure.com/org/Sample%20Project/_git/sample-repo') | Out-Null
    }

    try {
        Invoke-TestGit $repositoryPath @('remote', 'remove', 'origin') | Out-Null
        Push-Location $repositoryPath
        try { $noRemoteIdentity = & $resolverScript -LocalOnly | ConvertFrom-Json }
        finally { Pop-Location }
        if ($noRemoteIdentity.operation -ne 'local_identity' -or $noRemoteIdentity.repository_id -notmatch '^local-root:[0-9a-f]{64}$' -or
            $noRemoteIdentity.repository_name -ne (Split-Path -Leaf $repositoryPath) -or $noRemoteIdentity.repository_url -ne '') {
            throw 'no-remote identity is incorrect'
        }
        $script:passed++
        Write-Output 'PASS resolver-no-remote'
    } catch {
        $script:failed++
        Write-Output "FAIL resolver-no-remote - $($_.Exception.Message)"
    } finally {
        Invoke-TestGit $repositoryPath @('remote', 'add', 'origin', 'https://dev.azure.com/org/Sample%20Project/_git/sample-repo') | Out-Null
    }

    try {
        $firstExclusion = & $excludeScript -RepositoryPath $repositoryPath | ConvertFrom-Json
        $secondExclusion = & $excludeScript -RepositoryPath $repositoryPath | ConvertFrom-Json
        $excludeContent = @(Get-Content -LiteralPath $firstExclusion.exclude_path)
        foreach ($expectedPattern in @('/.reviews/', '/.claude/worktrees/')) {
            if (@($excludeContent | Where-Object { $_ -eq $expectedPattern }).Count -ne 1) {
                throw "exclusion '$expectedPattern' was not written exactly once"
            }
        }
        if (-not $firstExclusion.changed -or $secondExclusion.changed -or $firstExclusion.exclude_path -ne $secondExclusion.exclude_path -or
            @($firstExclusion.patterns).Count -ne 2 -or @($secondExclusion.patterns | Where-Object { $_.changed }).Count -ne 0) {
            throw 'repository-local exclusions were not idempotent'
        }
        $script:passed++
        Write-Output 'PASS initialize-review-exclusion'
    } catch {
        $script:failed++
        Write-Output "FAIL initialize-review-exclusion - $($_.Exception.Message)"
    }

    $workspaceRepositoryPath = Join-Path $testRoot 'workspace-repo'
    New-Item -ItemType Directory -Path $workspaceRepositoryPath | Out-Null
    Invoke-TestGit $workspaceRepositoryPath @('init') | Out-Null
    Invoke-TestGit $workspaceRepositoryPath @('config', 'user.email', 'cross-review-tests@example.invalid') | Out-Null
    Invoke-TestGit $workspaceRepositoryPath @('config', 'user.name', 'Cross Review Tests') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $workspaceRepositoryPath 'seed.txt'), "seed`n", [System.Text.UTF8Encoding]::new($false))
    Invoke-TestGit $workspaceRepositoryPath @('add', 'seed.txt') | Out-Null
    Invoke-TestGit $workspaceRepositoryPath @('commit', '-m', 'seed') | Out-Null
    $workspaceCommit = ([string](Invoke-TestGit $workspaceRepositoryPath @('rev-parse', 'HEAD'))).Trim()

    function New-TestWorktree {
        param([string]$Name)
        $path = Join-Path $testRoot $Name
        Invoke-TestGit $workspaceRepositoryPath @('worktree', 'add', '--detach', $path, $workspaceCommit) | Out-Null
        return $path
    }

    try {
        $cleanWorktree = New-TestWorktree 'wt-clean'
        $cleanResult = & $workspaceScript -RepositoryPath $workspaceRepositoryPath -WorktreePath $cleanWorktree | ConvertFrom-Json
        if (-not $cleanResult.removed -or $cleanResult.method -ne 'removed' -or (Test-Path -LiteralPath $cleanWorktree)) {
            throw 'a clean review worktree was not removed'
        }

        $dirtyWorktree = New-TestWorktree 'wt-dirty'
        [System.IO.File]::WriteAllText((Join-Path $dirtyWorktree 'stray.txt'), "stray`n", [System.Text.UTF8Encoding]::new($false))
        $dirtyResult = & $workspaceScript -RepositoryPath $workspaceRepositoryPath -WorktreePath $dirtyWorktree -WarningAction SilentlyContinue | ConvertFrom-Json
        if (-not $dirtyResult.removed -or $dirtyResult.method -ne 'removed_forced' -or (Test-Path -LiteralPath $dirtyWorktree)) {
            throw 'a worktree holding untracked files was not force-removed'
        }

        $repeatResult = & $workspaceScript -RepositoryPath $workspaceRepositoryPath -WorktreePath $dirtyWorktree | ConvertFrom-Json
        if (-not $repeatResult.removed -or $repeatResult.method -ne 'already_absent') { throw 'removal was not idempotent' }
        $script:passed++
        Write-Output 'PASS remove-review-workspace'
    } catch {
        $script:failed++
        Write-Output "FAIL remove-review-workspace - $($_.Exception.Message)"
    }

    try {
        $insideWorktree = New-TestWorktree 'wt-inside'
        Push-Location $insideWorktree
        try {
            $insideResult = & $workspaceScript -RepositoryPath $workspaceRepositoryPath -WorktreePath $insideWorktree | ConvertFrom-Json
            $locationAfterRemoval = (Get-Location).Path
        } finally { Pop-Location }
        if (-not $insideResult.removed -or (Test-Path -LiteralPath $insideWorktree)) {
            throw 'the worktree was not removed while it was the current directory'
        }
        if (-not [string]::Equals(
                [System.IO.Path]::GetFullPath($locationAfterRemoval).TrimEnd('\', '/'),
                [System.IO.Path]::GetFullPath($workspaceRepositoryPath).TrimEnd('\', '/'),
                [System.StringComparison]::OrdinalIgnoreCase)) {
            throw 'the caller was not moved to the repository root before removal'
        }
        $script:passed++
        Write-Output 'PASS remove-review-workspace-from-inside'
    } catch {
        $script:failed++
        Write-Output "FAIL remove-review-workspace-from-inside - $($_.Exception.Message)"
    }

    try {
        try {
            & $workspaceScript -RepositoryPath $workspaceRepositoryPath -WorktreePath $workspaceRepositoryPath | Out-Null
            throw 'Expected main-worktree rejection did not occur.'
        } catch {
            if ($_.Exception.Message -notlike '*main worktree*') { throw }
        }

        $orphanPath = Join-Path $testRoot 'wt-orphan'
        New-Item -ItemType Directory -Path $orphanPath | Out-Null
        $orphanResult = & $workspaceScript -RepositoryPath $workspaceRepositoryPath -WorktreePath $orphanPath | ConvertFrom-Json
        if (-not $orphanResult.removed -or $orphanResult.method -ne 'orphan_directory_removed' -or (Test-Path -LiteralPath $orphanPath)) {
            throw 'the empty directory left by a partial removal was not cleaned up'
        }

        $keptPath = Join-Path $testRoot 'wt-orphan-kept'
        New-Item -ItemType Directory -Path $keptPath | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $keptPath 'user-file.txt'), "keep me`n", [System.Text.UTF8Encoding]::new($false))
        $keptResult = & $workspaceScript -RepositoryPath $workspaceRepositoryPath -WorktreePath $keptPath -WarningAction SilentlyContinue | ConvertFrom-Json
        if ($keptResult.removed -or -not (Test-Path -LiteralPath $keptPath)) {
            throw 'a non-empty unregistered directory must be left alone'
        }
        $script:passed++
        Write-Output 'PASS remove-review-workspace-guards'
    } catch {
        $script:failed++
        Write-Output "FAIL remove-review-workspace-guards - $($_.Exception.Message)"
    }

    try {
        $storageState = & $storageSafetyScript -RepositoryPath $repositoryPath | ConvertFrom-Json
        if (-not $storageState.safe -or $storageState.managed_files_checked -ne 1 -or
            (Test-Path -LiteralPath (Join-Path $repositoryPath '.reviews'))) {
            throw 'absent review storage was not accepted without being created'
        }
        New-Item -ItemType Directory -Path (Join-Path $repositoryPath '.reviews') | Out-Null
        $existingStorageState = & $storageSafetyScript -RepositoryPath $repositoryPath | ConvertFrom-Json
        if (-not $existingStorageState.safe) { throw 'regular review storage was not accepted' }
        # Artifacts an earlier version left directly in .reviews are no longer managed.
        New-Item -ItemType Directory -Path (Join-Path $repositoryPath '.reviews/final.md') | Out-Null
        & $storageSafetyScript -RepositoryPath $repositoryPath | Out-Null
        Remove-Item -LiteralPath (Join-Path $repositoryPath '.reviews') -Recurse -Force
        $script:passed++
        Write-Output 'PASS review-storage-safe'
    } catch {
        $script:failed++
        Write-Output "FAIL review-storage-safe - $($_.Exception.Message)"
    }

    function Assert-StorageRejected {
        param([scriptblock]$Action, [string]$Message)
        try {
            & $Action | Out-Null
        } catch {
            if ($_.Exception.Message -like "*$Message*") { return }
            throw
        }
        throw "Expected rejection containing '$Message' did not occur."
    }

    try {
        $blockedHistoryPath = Join-Path $repositoryPath '.reviews/history.jsonl'
        New-Item -ItemType Directory -Path $blockedHistoryPath -Force | Out-Null
        Assert-StorageRejected { & $storageSafetyScript -RepositoryPath $repositoryPath } 'must be a regular file'
        Remove-Item -LiteralPath $blockedHistoryPath -Force

        $runDirectory = (& $runDirectoryScript -RepositoryPath $repositoryPath -Variant claude-led -ReviewMode pull_request -PullRequestId 7 `
            -ReviewId ([Guid]::NewGuid()) -StartedAt '2026-09-18T14:25:01Z' | ConvertFrom-Json).run_directory
        New-Item -ItemType Directory -Path (Join-Path $runDirectory 'final.md') | Out-Null
        Assert-StorageRejected { & $storageSafetyScript -RepositoryPath $repositoryPath -RunDirectory $runDirectory } 'must be a regular file'
        Assert-StorageRejected { & $storageSafetyScript -RepositoryPath $repositoryPath -RunDirectory (Join-Path $repositoryPath '.reviews') } 'directly under'
        Remove-Item -LiteralPath (Join-Path $repositoryPath '.reviews') -Recurse -Force

        $junctionTarget = Join-Path $testRoot 'runs-junction-target'
        New-Item -ItemType Directory -Path $junctionTarget | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $repositoryPath '.reviews') | Out-Null
        $runsJunction = Join-Path $repositoryPath '.reviews/runs'
        New-Item -ItemType Junction -Path $runsJunction -Target $junctionTarget | Out-Null
        try {
            Assert-StorageRejected { & $storageSafetyScript -RepositoryPath $repositoryPath } 'symbolic link, junction, or reparse point'
            Assert-StorageRejected {
                & $runDirectoryScript -RepositoryPath $repositoryPath -Variant codex-led -ReviewMode pull_request -PullRequestId 7 `
                    -ReviewId ([Guid]::NewGuid()) -StartedAt '2026-09-18T14:25:01Z'
            } 'symbolic link, junction, or reparse point'
        } finally {
            # Delete only the link itself, never its target.
            [System.IO.Directory]::Delete($runsJunction)
        }
        if (@(Get-ChildItem -LiteralPath $junctionTarget -Force).Count -ne 0) { throw 'a run folder was created through a junction' }
        Remove-Item -LiteralPath (Join-Path $repositoryPath '.reviews') -Recurse -Force
        $script:passed++
        Write-Output 'PASS review-storage-redirection-guard'
    } catch {
        $script:failed++
        Write-Output "FAIL review-storage-redirection-guard - $($_.Exception.Message)"
    }

    try {
        $startedText = '2026-09-18T16:25:01+02:00'
        $reviewId = '9d2c7f15-baa0-4fa6-82f4-5151dfd43be2'
        $prRun = & $runDirectoryScript -RepositoryPath $repositoryPath -Variant claude-led -ReviewMode pull_request -PullRequestId 1234 `
            -BranchName 'feature/ignored' -ReviewId $reviewId -StartedAt $startedText | ConvertFrom-Json
        if ($prRun.name -ne 'pr-1234_20260918T142501Z_claude-led_9d2c7f15' -or
            $prRun.run_directory_relative -ne ".reviews/runs/$($prRun.name)" -or
            -not (Test-Path -LiteralPath $prRun.run_directory -PathType Container)) {
            throw "unexpected PR run folder '$($prRun.name)'"
        }
        # The other variant for the same PR and start time gets a sibling folder.
        $codexRun = & $runDirectoryScript -RepositoryPath $repositoryPath -Variant codex-led -ReviewMode pull_request -PullRequestId 1234 `
            -ReviewId $reviewId -StartedAt $startedText | ConvertFrom-Json
        if ($codexRun.name -ne 'pr-1234_20260918T142501Z_codex-led_9d2c7f15' -or
            (Split-Path -Parent $codexRun.run_directory) -ne (Split-Path -Parent $prRun.run_directory)) {
            throw 'the two variants did not produce sibling run folders'
        }
        Assert-StorageRejected {
            & $runDirectoryScript -RepositoryPath $repositoryPath -Variant claude-led -ReviewMode pull_request -PullRequestId 1234 `
                -ReviewId $reviewId -StartedAt $startedText
        } 'already exists'

        $branchRun = & $runDirectoryScript -RepositoryPath $repositoryPath -Variant claude-led -ReviewMode branch `
            -BranchName 'feature/login' -ReviewId ([Guid]::NewGuid()) -StartedAt $startedText | ConvertFrom-Json
        if ($branchRun.name -notlike 'branch-feature-login_20260918T142501Z_claude-led_*') { throw "unexpected branch run folder '$($branchRun.name)'" }

        $longBranch = 'x' * 200
        foreach ($case in @(
            @('../../x', 'uncommitted-x_'),
            @('feat/äö---y', 'uncommitted-feat-y_'),
            @('---', 'uncommitted-unnamed_'),
            @($longBranch, "uncommitted-$('x' * 48)_")
        )) {
            $run = & $runDirectoryScript -RepositoryPath $repositoryPath -Variant codex-led -ReviewMode uncommitted `
                -BranchName $case[0] -ReviewId ([Guid]::NewGuid()) -StartedAt $startedText | ConvertFrom-Json
            if (-not $run.name.StartsWith($case[1], [System.StringComparison]::Ordinal) -or
                (Split-Path -Parent $run.run_directory) -ne (Split-Path -Parent $prRun.run_directory)) {
                throw "branch '$($case[0])' produced unsafe run folder '$($run.name)'"
            }
        }

        New-Item -ItemType Directory -Path (Join-Path (Split-Path -Parent $prRun.run_directory) 'pr-12_20260918T142501Z_claude-led_00000000') | Out-Null
        $matches12 = @(Get-ChildItem -LiteralPath (Split-Path -Parent $prRun.run_directory) -Directory -Filter 'pr-12_*')
        if ($matches12.Count -ne 1) { throw 'the pr-12_* discovery pattern matched another PR' }

        Assert-StorageRejected {
            & $runDirectoryScript -RepositoryPath $repositoryPath -Variant claude-led -ReviewMode branch `
                -ReviewId ([Guid]::NewGuid()) -StartedAt $startedText
        } 'BranchName is required'
        Assert-StorageRejected {
            & $runDirectoryScript -RepositoryPath $repositoryPath -Variant claude-led -ReviewMode pull_request `
                -ReviewId 'not-a-uuid' -PullRequestId 1 -StartedAt $startedText
        } 'must be a UUID'
        Remove-Item -LiteralPath (Join-Path $repositoryPath '.reviews') -Recurse -Force
        $script:passed++
        Write-Output 'PASS new-review-run-directory'
    } catch {
        $script:failed++
        Write-Output "FAIL new-review-run-directory - $($_.Exception.Message)"
    }

    try {
        Invoke-TestGit $repositoryPath @('remote', 'set-url', 'origin', 'ssh://git@ssh.dev.azure.com:22/v3/org/Sample%20Project/sample-repo') | Out-Null
        Push-Location $repositoryPath
        try { $resolvedSsh = & $resolverScript -MetadataPath $metadataPath | ConvertFrom-Json }
        finally { Pop-Location }
        if ($resolvedSsh.repository_name -ne 'sample-repo' -or $resolvedSsh.project_name -ne 'Sample Project') { throw 'SSH identity was not decoded correctly' }
        $script:passed++
        Write-Output 'PASS resolver-ssh-port-identity'
    } catch {
        $script:failed++
        Write-Output "FAIL resolver-ssh-port-identity - $($_.Exception.Message)"
    } finally {
        Invoke-TestGit $repositoryPath @('remote', 'set-url', 'origin', 'https://dev.azure.com/org/Sample%20Project/_git/sample-repo') | Out-Null
    }

    $wrongMetadata = $prMetadata | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    $wrongMetadata.repository.name = 'other-repo'
    $wrongMetadataPath = Join-Path $testRoot 'resolver-wrong-repository.json'
    Write-JsonFile $wrongMetadataPath $wrongMetadata
    try {
        Push-Location $repositoryPath
        try { & $resolverScript -MetadataPath $wrongMetadataPath | Out-Null }
        finally { Pop-Location }
        $script:failed++
        Write-Output 'FAIL resolver-repository-mismatch - expected validation failure'
    } catch {
        if ($_.Exception.Message -like '*Repository safety check failed*') {
            $script:passed++
            Write-Output 'PASS resolver-repository-mismatch'
        } else {
            $script:failed++
            Write-Output "FAIL resolver-repository-mismatch - unexpected error: $($_.Exception.Message)"
        }
    }

    $unsafeRefMetadata = $prMetadata | ConvertTo-Json -Depth 15 | ConvertFrom-Json
    $unsafeRefMetadata.targetRefName = '--upload-pack=malicious'
    $unsafeRefMetadataPath = Join-Path $testRoot 'resolver-unsafe-ref.json'
    Write-JsonFile $unsafeRefMetadataPath $unsafeRefMetadata
    try {
        Push-Location $repositoryPath
        try { & $resolverScript -MetadataPath $unsafeRefMetadataPath | Out-Null }
        finally { Pop-Location }
        $script:failed++
        Write-Output 'FAIL resolver-unsafe-target-ref - expected validation failure'
    } catch {
        if ($_.Exception.Message -like '*invalid targetRefName*') {
            $script:passed++
            Write-Output 'PASS resolver-unsafe-target-ref'
        } else {
            $script:failed++
            Write-Output "FAIL resolver-unsafe-target-ref - unexpected error: $($_.Exception.Message)"
        }
    }

    Push-Location $repositoryPath
    try { $bootstrapEstimate = & $estimateScript -BaseRef main -RepositoryId 'repo-1' -RepositoryName 'sample-repo' | ConvertFrom-Json }
    finally { Pop-Location }
    try {
        if ($bootstrapEstimate.estimate.method -ne 'bootstrap_heuristic' -or $bootstrapEstimate.estimate.seconds -ne 240) { throw 'small bootstrap estimate is incorrect' }
        $script:passed++
        Write-Output 'PASS estimate-bootstrap'
    } catch {
        $script:failed++
        Write-Output "FAIL estimate-bootstrap - $($_.Exception.Message)"
    }

    Push-Location $repositoryPath
    try { $branchEstimate = & $estimateScript -ReviewMode branch -BaseRef main -HeadRef feature/sample -RepositoryId 'repo-1' -RepositoryName 'sample-repo' | ConvertFrom-Json }
    finally { Pop-Location }
    try {
        if ($branchEstimate.review_mode -ne 'branch' -or -not $branchEstimate.review_size.has_changes -or $branchEstimate.review_size.commit_count -ne 1) {
            throw 'branch source/base measurement is incorrect'
        }
        $script:passed++
        Write-Output 'PASS estimate-branch-scope'
    } catch {
        $script:failed++
        Write-Output "FAIL estimate-branch-scope - $($_.Exception.Message)"
    }

    Push-Location $repositoryPath
    try { $emptyEstimate = & $estimateScript -ReviewMode branch -BaseRef HEAD -HeadRef HEAD -RepositoryId 'repo-1' -RepositoryName 'sample-repo' | ConvertFrom-Json }
    finally { Pop-Location }
    try {
        if ($emptyEstimate.review_size.has_changes -or $emptyEstimate.review_size.changed_files -ne 0) { throw 'empty branch comparison should report no changes' }
        $script:passed++
        Write-Output 'PASS estimate-nothing-to-review'
    } catch {
        $script:failed++
        Write-Output "FAIL estimate-nothing-to-review - $($_.Exception.Message)"
    }

    $reviewUnits = [double]$bootstrapEstimate.review_size.review_units
    $singleHistoryPath = Join-Path $testRoot 'single-history.jsonl'
    $singleEntry = [ordered]@{
        schema_version = 2; review_id = 'history-1'; repository = [ordered]@{ id = 'repo-1'; name = 'sample-repo' }
        review_size = [ordered]@{ review_units = $reviewUnits }
        estimate = [ordered]@{ high_seconds = 420 }
        timing = [ordered]@{ duration_seconds = 3600; estimation_eligible = $true }
    }
    [System.IO.File]::WriteAllText($singleHistoryPath, ($singleEntry | ConvertTo-Json -Depth 10 -Compress) + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
    Push-Location $repositoryPath
    try { $singleEstimate = & $estimateScript -BaseRef main -HistoryPath $singleHistoryPath -RepositoryId 'repo-1' -RepositoryName 'sample-repo' | ConvertFrom-Json }
    finally { Pop-Location }
    try {
        if ($singleEstimate.estimate.historical_runs_used -ne 1 -or [Math]::Abs([double]$singleEstimate.estimate.history_weight - 0.1143) -gt 0.0001) { throw 'one-run history weight is incorrect' }
        if ($singleEstimate.estimate.seconds -ge 900) { throw 'one slow run distorted the estimate too far' }
        $script:passed++
        Write-Output 'PASS estimate-sparse-history-weight'
    } catch {
        $script:failed++
        Write-Output "FAIL estimate-sparse-history-weight - $($_.Exception.Message)"
    }

    $matureHistoryPath = Join-Path $testRoot 'mature-history.jsonl'
    $matureLines = @()
    foreach ($index in 1..7) {
        $repositoryId = if ($index -le 3) { 'repo-1' } else { "cross-repo-$index" }
        $entry = [ordered]@{
            schema_version = 2; review_id = "mature-$index"; repository = [ordered]@{ id = $repositoryId; name = "repo-$index" }
            review_size = [ordered]@{ review_units = $reviewUnits }
            estimate = [ordered]@{ high_seconds = 900 }
            timing = [ordered]@{ duration_seconds = (540 + (10 * $index)); estimation_eligible = $true }
        }
        $matureLines += ($entry | ConvertTo-Json -Depth 10 -Compress)
    }
    [System.IO.File]::WriteAllLines($matureHistoryPath, $matureLines, [System.Text.UTF8Encoding]::new($false))
    Push-Location $repositoryPath
    try { $matureEstimate = & $estimateScript -BaseRef main -HistoryPath $matureHistoryPath -RepositoryId 'repo-1' -RepositoryName 'sample-repo' | ConvertFrom-Json }
    finally { Pop-Location }
    try {
        if ($matureEstimate.estimate.historical_runs_used -ne 7 -or $matureEstimate.estimate.history_weight -ne 0.8 -or $matureEstimate.estimate.confidence -ne 'high') {
            throw 'mature history should reach 80% weight and high confidence with three same-repository samples'
        }
        $script:passed++
        Write-Output 'PASS estimate-mature-history-weight'
    } catch {
        $script:failed++
        Write-Output "FAIL estimate-mature-history-weight - $($_.Exception.Message)"
    }

    $distanceHistoryPath = Join-Path $testRoot 'distance-history.jsonl'
    $distanceLines = @()
    foreach ($index in 1..7) {
        $entry = [ordered]@{
            schema_version = 2; review_id = "distant-$index"; repository = [ordered]@{ id = 'repo-1'; name = 'sample-repo' }
            review_size = [ordered]@{ review_units = 1 }
            estimate = [ordered]@{ high_seconds = 420 }
            timing = [ordered]@{ duration_seconds = 600; estimation_eligible = $true }
        }
        $distanceLines += ($entry | ConvertTo-Json -Depth 10 -Compress)
    }
    $matchingEntry = [ordered]@{
        schema_version = 2; review_id = 'matching-cross-repo'; repository = [ordered]@{ id = 'other-repo'; name = 'other-repo' }
        review_size = [ordered]@{ review_units = $reviewUnits }
        estimate = [ordered]@{ high_seconds = 420 }
        timing = [ordered]@{ duration_seconds = 600; estimation_eligible = $true }
    }
    $distanceLines += ($matchingEntry | ConvertTo-Json -Depth 10 -Compress)
    [System.IO.File]::WriteAllLines($distanceHistoryPath, $distanceLines, [System.Text.UTF8Encoding]::new($false))
    Push-Location $repositoryPath
    try { $distanceEstimate = & $estimateScript -BaseRef main -HistoryPath $distanceHistoryPath -RepositoryId 'repo-1' -RepositoryName 'sample-repo' | ConvertFrom-Json }
    finally { Pop-Location }
    try {
        if ($distanceEstimate.estimate.historical_runs_eligible -ne 8 -or $distanceEstimate.estimate.historical_runs_available -ne 1 -or $distanceEstimate.estimate.same_repository_runs_used -ne 0) {
            throw 'distant same-repository samples should not displace a comparable cross-repository sample'
        }
        $script:passed++
        Write-Output 'PASS estimate-size-distance-filter'
    } catch {
        $script:failed++
        Write-Output "FAIL estimate-size-distance-filter - $($_.Exception.Message)"
    }

    [System.IO.File]::AppendAllText((Join-Path $repositoryPath 'base.txt'), "unstaged`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $repositoryPath 'staged.txt'), "staged`n", [System.Text.UTF8Encoding]::new($false))
    Invoke-TestGit $repositoryPath @('add', 'staged.txt') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repositoryPath 'untracked.txt'), "one`ntwo`n", [System.Text.UTF8Encoding]::new($false))
    New-Item -ItemType Directory -Path (Join-Path $repositoryPath '.reviews') | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $repositoryPath '.reviews/ignored.txt'), "ignore me`n", [System.Text.UTF8Encoding]::new($false))
    Push-Location $repositoryPath
    try {
        $uncommittedEstimate = & $estimateScript -ReviewMode uncommitted -BaseRef HEAD -HistoryPath $singleHistoryPath -RepositoryId 'repo-1' -RepositoryName 'sample-repo' | ConvertFrom-Json
    } finally { Pop-Location }
    try {
        if (-not $uncommittedEstimate.review_size.has_changes -or $uncommittedEstimate.review_size.changed_files -ne 3 -or $uncommittedEstimate.review_size.commit_count -ne 0) {
            throw 'uncommitted sizing did not include staged, unstaged, and untracked files while excluding .reviews'
        }
        if ($uncommittedEstimate.estimate.historical_runs_used -ne 0) { throw 'legacy PR history must not train uncommitted estimates' }
        $script:passed++
        Write-Output 'PASS estimate-uncommitted-scope'
    } catch {
        $script:failed++
        Write-Output "FAIL estimate-uncommitted-scope - $($_.Exception.Message)"
    }

    try {
        Push-Location $repositoryPath
        try {
            try {
                & $estimateScript -ReviewMode uncommitted -BaseRef HEAD -HeadRef main -RepositoryId 'repo-1' -RepositoryName 'sample-repo' | Out-Null
                throw 'Expected non-HEAD HeadRef rejection did not occur.'
            } catch {
                if ($_.Exception.Message -notlike '*Uncommitted reviews always use HEAD*') { throw }
            }
        } finally { Pop-Location }
        $script:passed++
        Write-Output 'PASS estimate-uncommitted-head-guard'
    } catch {
        $script:failed++
        Write-Output "FAIL estimate-uncommitted-head-guard - $($_.Exception.Message)"
    }

    try {
        $nestedPath = Join-Path $repositoryPath 'nested/subdirectory'
        New-Item -ItemType Directory -Path $nestedPath -Force | Out-Null
        Push-Location $nestedPath
        try {
            $subdirectoryEstimate = & $estimateScript -ReviewMode uncommitted -BaseRef HEAD -OutputPath '.reviews/subdirectory-estimate.json' -RepositoryId 'repo-1' -RepositoryName 'sample-repo' | ConvertFrom-Json
        } finally { Pop-Location }
        if ($subdirectoryEstimate.review_size.changed_files -ne $uncommittedEstimate.review_size.changed_files -or
            $subdirectoryEstimate.review_size.lines_changed -ne $uncommittedEstimate.review_size.lines_changed -or
            -not (Test-Path -LiteralPath (Join-Path $repositoryPath '.reviews/subdirectory-estimate.json') -PathType Leaf) -or
            (Test-Path -LiteralPath (Join-Path $nestedPath '.reviews/subdirectory-estimate.json'))) {
            throw 'subdirectory invocation did not measure and write relative to the repository root'
        }
        $script:passed++
        Write-Output 'PASS estimate-repository-root-scope'
    } catch {
        $script:failed++
        Write-Output "FAIL estimate-repository-root-scope - $($_.Exception.Message)"
    }

    try {
        $largeUntrackedPath = Join-Path $repositoryPath 'large-untracked.txt'
        $largeStream = [System.IO.File]::Open($largeUntrackedPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $largeBuffer = [System.Text.Encoding]::ASCII.GetBytes(('a' * 65536))
            for ($written = 0; $written -lt 6MB; $written += $largeBuffer.Length) {
                $writeCount = [int][Math]::Min($largeBuffer.Length, (6MB - $written))
                $largeStream.Write($largeBuffer, 0, $writeCount)
            }
        } finally { $largeStream.Dispose() }
        Push-Location $repositoryPath
        try { $largeEstimate = & $estimateScript -ReviewMode uncommitted -BaseRef HEAD -RepositoryId 'repo-1' -RepositoryName 'sample-repo' | ConvertFrom-Json }
        finally { Pop-Location }
        if ($largeEstimate.review_size.changed_files -ne 4 -or $largeEstimate.review_size.oversized_untracked_files -ne 1 -or
            $largeEstimate.review_size.lines_added -le $uncommittedEstimate.review_size.lines_added) {
            throw 'oversized untracked text file was not measured with the bounded estimate'
        }
        $script:passed++
        Write-Output 'PASS estimate-oversized-untracked-file'
    } catch {
        $script:failed++
        Write-Output "FAIL estimate-oversized-untracked-file - $($_.Exception.Message)"
    }
} finally {
    # Remove-ReviewWorkspace.ps1 moves the caller into the repository it cleaned, which can leave
    # this session inside $testRoot and make the directory removal below fail as "in use".
    # Restore the caller's own directory rather than stranding them in the tests folder.
    if (Test-Path -LiteralPath $startingLocation) {
        Set-Location -LiteralPath $startingLocation
    } else {
        Set-Location -LiteralPath $PSScriptRoot
    }
    $resolvedTestRoot = [System.IO.Path]::GetFullPath($testRoot)
    $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    if ($resolvedTestRoot.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item -LiteralPath $resolvedTestRoot -Recurse -Force
    }
}

Write-Output "$passed passed, $failed failed"
if ($failed -gt 0) { exit 1 }
if ($PSVersionTable.PSVersion -ge [Version]'7.4') {
    & (Join-Path $PSScriptRoot 'Run-CodexTests.ps1') | Out-Null
} else {
    Write-Output 'Codex tests require PowerShell 7.4 or later.'
}
