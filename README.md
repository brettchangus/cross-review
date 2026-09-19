# cross-review

**Two-model code review for Claude Code and Codex.**

`cross-review` runs Claude's native `/code-review` and Codex's native review independently on the same change, reconciles their findings against the source, and records how each reviewer performed. The result is a single verified report, plus metrics that show over time how much each model contributes.

It works on Azure DevOps pull requests, uncommitted changes, and branch comparisons. It is read-only: it never edits code, posts comments, or changes PR state.

## Contents

- [Why two reviewers](#why-two-reviewers)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Output](#output)
- [Security and privacy](#security-and-privacy)
- [Design details](#design-details)
- [Development](#development)
- [License](#license)

## Why two reviewers

Each model finds issues the other misses, and each raises some false positives. Running both independently, then checking every finding against the source, gives you:

- **Wider coverage.** Findings from either reviewer make it into the final report.
- **Fewer false positives.** Every finding is confirmed, rejected, or marked uncertain from source evidence before it is reported.
- **Measurable value.** Precision, agreement, and added value are recorded for every run, so you can see whether the second reviewer is paying for itself.

## How it works

There are two implementations with the same workflow. They differ in which tool runs the review and makes the final decisions.

| | Claude-led | Codex-led |
|---|---|---|
| Invoked from | Claude Code: `/cross-review` | Codex: `$cross-review` |
| Independent reviews | Codex in the background, Claude in the session | Both as fresh child processes, concurrently |
| Comparison pass | Codex (`medium` reasoning) | Claude (`medium` effort) |
| Final adjudication | Claude, in the session | Codex, in the session |
| Run folders | `.reviews/runs/*_claude-led_*` | `.reviews/runs/*_codex-led_*` |

```text
Select the review scope
  -> show the complete preflight and ask for confirmation
  -> Claude /code-review and Codex review, independently and concurrently
  -> comparison pass by the non-host model
  -> source verification and final adjudication by the host
  -> deterministic metrics, final report, and history
```

The two reviews start before either has written any findings, so neither can see the other's output. The comparison pass groups what the reviewers found and checks each group with targeted reads of the relevant source; it does not re-review the diff. The host then makes the final call on each finding from the source.

Both reviewers run at pinned levels (Claude `/code-review high`, Codex reasoning `high`), so results are reproducible and comparable between runs.

## Requirements

- [Claude Code](https://code.claude.com) with the native `/code-review` skill
- [Codex CLI](https://learn.chatgpt.com/docs/non-interactive-mode) with `codex exec review`
- Git
- PowerShell 5.1 or later for the Claude-led skill; PowerShell 7.4 or later (`pwsh`) for the Codex-led skill
- For pull request reviews only:
  - Azure DevOps MCP configured in Claude Code (preferred), or
  - Azure CLI with the `azure-devops` extension and authenticated defaults (fallback)

Uncommitted and branch reviews need neither Azure DevOps nor a configured remote.

The Codex-led skill also needs native `claude` and `codex` executables on `PATH`, not `.cmd` or `.bat` shims.

> [!NOTE]
> The skills are developed and tested on Windows.

Both skills use your existing CLI sessions and authentication. No API keys or additional integrations are needed.

## Installation

Clone the repository and run the installer for each host you use:

```powershell
./Install-Skill.ps1 -HostApp Claude
./Install-Skill.ps1 -HostApp Codex
```

This installs a self-contained skill to the default location for each host:

| Host | Location |
|---|---|
| Claude Code | `%USERPROFILE%\.claude\skills\cross-review\` |
| Codex | `%USERPROFILE%\.agents\skills\cross-review\` |

To install somewhere else, pass the full destination skill directory:

```powershell
./Install-Skill.ps1 -HostApp Claude -DestinationPath <path>\cross-review
```

The installer combines the host's skill with the shared scripts and references, so install with the script rather than copying the repository or a `skills/` directory directly.

**Upgrading.** The installer never overwrites an existing installation. Move the old one aside first, then install again. If an install fails part way, the partial directory is left for inspection; move it aside before retrying.

Restart Claude Code or Codex if the skill does not appear.

## Usage

In Claude Code:

```text
/cross-review
/cross-review pr 1234
```

In Codex:

```text
$cross-review
$cross-review pr 1234
```

### Choosing what to review

With no arguments, the skill reviews the first of these that applies:

1. Uncommitted changes (staged, unstaged, or untracked) against `HEAD`
2. The active Azure DevOps pull request for the current branch
3. The current branch against the repository's default branch (`main` or `master`)

If none applies, there is nothing to review. Passing `pr <id>` reviews that pull request ahead of everything else.

A pull request must match the branch you have checked out and your local repository. The skill never switches your branch.

### Confirming a run

Before anything runs, the skill shows a complete preflight and asks for confirmation. The preflight covers the scope, source and target commits, tools, models and effort levels, review size, and estimated duration. Only `y` or `yes` continues. Any other answer, including cancelling, stops without creating any files, worktrees, or history.

To preview a run without starting it, invoke the skill and answer `no`.

## Output

Each run gets its own folder under `.reviews/runs/` in the reviewed repository. Only the history files, which every run adds to, sit outside the run folders.

```text
.reviews/
  history.jsonl                     Claude-led history
  codex-led/history.jsonl           Codex-led history
  runs/
    pr-1234_20260918T142501Z_claude-led_9d2c7f15/
      run-context.json              scope, commits, tools, models, and estimate
      claude-review.md              Claude's independent review
      codex-independent.md          Codex's independent review
      codex-evaluation.md           comparison pass (claude-evaluation.md for Codex-led)
      adjudication.json             final decision on every finding
      metrics.json                  calculated metrics
      final.md                      final report
```

Run folders are named `<scope>_<UTC start time>_<skill>_<run ID prefix>`, where the scope is `pr-<id>`, `branch-<branch>`, or `uncommitted-<branch>`. All runs of the same PR or branch therefore list together, oldest first, and a later run can find earlier ones by matching the scope, for example `.reviews/runs/pr-1234_*`. Each history entry also records its run folder.

The skills never delete or overwrite a run folder. A folder without a `final.md` belongs to a run that failed after its reviews finished; it is kept for inspection. Delete old run folders by hand when you no longer need them.

The skill adds `/.reviews/` and `/.claude/worktrees/` to the repository's local `.git/info/exclude`, so these files stay out of `git status` without changing your `.gitignore`.

> [!NOTE]
> Earlier versions wrote each run's files directly into `.reviews/` or `.reviews/codex-led/`, replacing the previous run's. Those files are left where they are and are no longer updated; you can delete them.

### Report contents

The final report starts with a one- or two-paragraph summary of the reviewed changes, emphasizing any critical or breaking behavior before the findings. It then lists every confirmed finding with its severity, plus:

- total run time in the cross-review effectiveness block
- initial Claude and Codex finding counts by severity
- confirmed counts by severity
- agreed, Claude-only, and Codex-only confirmed findings
- rejected false positives, merged duplicates, and uncertain findings
- the precision of each reviewer and the value added by the second reviewer
- the models and effort levels used, and where each value came from

### Metrics

Every initial finding gets a permanent ID (`C-001` for Claude, `X-001` for Codex). Findings that describe the same issue are grouped, and each group is confirmed, rejected, or marked uncertain.

```text
Claude precision       = Claude findings in confirmed groups / all Claude findings
Codex precision        = Codex findings in confirmed groups / all Codex findings
Codex added value      = Codex-only confirmed groups / all confirmed groups
Cross-review reduction = 1 - (confirmed groups / initial unique findings)
```

A metric with a zero denominator is shown as `N/A`. The Codex-led skill also reports the value Claude added.

The calculations are deterministic, but the grouping and confirmation they rely on are model judgments. The precision figures describe confirmation by this pipeline; they are not an objective ranking of the two models.

### History and estimates

Each completed run is appended to a repository history and a user-level history:

| Skill | Repository history | User-level history |
|---|---|---|
| Claude-led | `.reviews/history.jsonl` | `%USERPROFILE%\.claude\cross-review\history.jsonl` |
| Codex-led | `.reviews/codex-led/history.jsonl` | `%USERPROFILE%\.codex\cross-review\history.jsonl` |

History is used to estimate how long future reviews will take. Failed or declined runs are not recorded, existing lines are never rewritten, and the two skills never mix their histories.

## Security and privacy

- **Read-only.** Both Codex stages run with `--sandbox read-only --ephemeral`. Claude runs without edit tools and without bypassing permissions. The skill never requests an approval bypass or a writable sandbox.
- **No credentials.** The skills use your existing Claude Code, Codex, Git, and Azure DevOps sessions with their current permissions.
- **URL sanitization.** Credentials, query strings, and fragments are removed from repository URLs before they are shown or stored, so a token embedded in `origin` never reaches the history.
- **Untrusted input.** Repository content, diffs, PR metadata, branch names, and reviewer output are treated as data, not instructions. Command arguments are passed as discrete values rather than shell text, Azure DevOps refs must be valid `refs/heads/*` refs, and review storage paths are checked against symbolic-link and directory redirection before anything is written.
- **Frozen commits.** Both reviewers receive the exact source and target commits shown in the preflight, not branch names, so a fetch or push during the review cannot change what was approved.

> [!IMPORTANT]
> Review artifacts can contain repository names, commit IDs, findings, and source excerpts. They stay on your machine under `.reviews/` and your user profile. Check them before sharing. The local Git exclusion does not protect artifacts that were already tracked or force-added.

## Design details

<details>
<summary>Pull request resolution</summary>

PR metadata comes from the Azure DevOps MCP server. The Azure CLI (`az repos pr`) is used only if the MCP server is unavailable or its response is unusable.

A branch mismatch, repository or project mismatch, inactive PR, or multiple matching PRs stops the run; these are safety failures, not reasons to try the fallback. Both paths pass through the same validator, which checks the PR against your local branch and `origin`. The CLI fallback derives the organization, project, and repository from `origin`.

PR source and target refs are fetched fresh, so rebased and force-pushed branches are handled. PR lookup is skipped when uncommitted changes take precedence, and is not attempted when the repository has no Azure DevOps remote.

</details>

<details>
<summary>Review workspace</summary>

PR and branch reviews run against the exact source commit from the preflight. If your checkout is clean and already at that commit, which is the usual case when you have pulled a PR branch, the review runs in place. Otherwise the skill creates a temporary detached worktree under `.claude/worktrees/`, so your local changes and later commits cannot affect the review.

The worktree is kept until adjudication finishes, so every source check sees the reviewed commit. It is then removed, along with all temporary review data, whether the run succeeds or fails. The cleanup script only touches that exact worktree path and reports anything it deliberately left in place.

</details>

<details>
<summary>Models and effort levels</summary>

| Stage | Setting |
|---|---|
| Claude independent review | `/code-review high` |
| Codex independent review | reasoning `high` |
| Comparison pass | `medium` |

Every level is pinned explicitly. Without that, Claude would reuse the level from your last `/code-review` and Codex would use whatever `model_reasoning_effort` is in your configuration, which the skill cannot read back. The comparison pass runs lighter because judging existing findings is less work than finding them.

The Claude model comes from the current session. The Codex model comes from read-only `codex doctor --json` diagnostics and is passed explicitly to both Codex stages when it is known. If a model cannot be determined without making a model request, the preflight says so rather than guessing. Each stage's settings are recorded separately, so a change in results can be traced to the setting that caused it.

</details>

<details>
<summary>Size and duration estimates</summary>

Review size counts changed files, added and deleted lines, commits, and binary files across the whole repository, even when invoked from a subdirectory. Text files up to 5 MiB are counted exactly; larger files are estimated from their byte size.

The first run uses a fixed estimate of 4, 6, 8, or 10 minutes for small through very large reviews. After that, estimates blend in up to seven past runs of the same review mode, preferring runs from the same repository and ignoring runs more than about 7.4 times larger or smaller. History carries about 11% of the weight with one sample, rising to 80% with seven.

Timing starts when you confirm, so time spent reading the preflight is not counted. The effectiveness summary shows total run time through final-report generation; history timing ends when the run is recorded. Runs longer than four hours are recorded but not used for estimates.

</details>

<details>
<summary>Codex-led process supervision</summary>

The Codex-led skill runs both reviewers as child processes. The supervisor starts both before waiting, reads both output streams, and stops the whole process tree on failure or after a 30-minute stage timeout. It records process IDs, start times, and transcript paths, so `Stop-ReviewProcesses.ps1` can cancel a run without mistaking a reused process ID for a reviewer.

A review counts only if the reviewer finished and produced a report: Claude must have run the native `code-review high`, and Codex must have completed its turn. A missing native skill stops the run; it is never replaced with a generic review prompt. Tool or sandbox denials are kept as diagnostics rather than failing an otherwise complete report.

After the run, the skill lists commands the Claude reviewer was denied and can offer narrow rules, such as `Bash(ls *)`, to allow on future runs. It adds only rules you explicitly accept, stores them in `%USERPROFILE%\.codex\cross-review\claude-allowed-tools.json`, and never grants blanket `Bash` access. Codex denials are reported but never added to an allowlist, because that would weaken the read-only sandbox.

</details>

## Development

```text
skills/
  claude/cross-review/    Claude-led skill and its comparison prompt
  codex/cross-review/     Codex-led skill, comparison prompt, and process helpers
shared/
  scripts/                helpers used by both skills
  references/             artifact and history contracts
tests/
  Run-Tests.ps1           test entry point, Claude-led and shared helpers
  Run-CodexTests.ps1      Codex-led helpers
Install-Skill.ps1
```

Shared scripts and references are maintained once under `shared/` and copied into each installed skill. Host-specific files must not use the same paths as shared ones; the installer fails if they collide.

The artifact and history formats are defined in [`shared/references/artifact-contract.md`](shared/references/artifact-contract.md). The Claude-led skill writes schema version 3 and the Codex-led skill writes version 4.

### Running the tests

The tests have no external dependencies. They build a temporary installation and run the helpers from it, so they test packaging as well as behavior.

```powershell
./tests/Run-Tests.ps1
```

This also runs the Codex-led tests when you are on PowerShell 7.4 or later.

## License

Released under the [MIT License](LICENSE).
