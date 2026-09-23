# Artifact contract

Use this contract for the artifacts you write by hand. The version-3 examples describe the Claude-led workflow; for Codex-led runs, apply the version-4 changes at the end.

- `<run_directory>/run-context.json`
- `<run_directory>/adjudication.json`
- the final-report presentation and effectiveness summary in `<run_directory>/final.md`

`metrics.json` and the history files are produced by the bundled scripts. Never hand-write or edit them.

## Storage layout

Every run writes into its own folder under `.reviews/runs/`. Only the history files, which every run appends to, live outside run folders.

```text
.reviews/
  history.jsonl                 Claude-led history
  codex-led/history.jsonl       Codex-led history
  runs/
    <scope>_<yyyyMMddTHHmmssZ>_<variant>_<review-id-prefix>/
      run-context.json
      claude-review.md
      codex-independent.md
      codex-evaluation.md       Claude-led comparison
      claude-evaluation.md      Codex-led comparison
      adjudication.json
      metrics.json
      final.md
```

Create the folder only with `New-ReviewRunDirectory.ps1`, which builds the name, validates storage, and refuses to reuse an existing folder. The name is:

- `<scope>`: `pr-<id>` in PR mode, `branch-<slug>` in branch mode, or `uncommitted-<slug>` in uncommitted mode, where `<slug>` is the local branch reduced to one safe path segment
- `<yyyyMMddTHHmmssZ>`: `started_at` in UTC
- `<variant>`: `claude-led` or `codex-led`
- `<review-id-prefix>`: the first eight hex digits of `review_id`

The scope comes first, so all runs of one PR or branch list together, oldest to newest. To find earlier runs of a scope, match `.reviews/runs/<scope>_*` (the underscore keeps `pr-12_*` from matching `pr-1234_…`), then confirm each candidate from its `run-context.json`, because different branch names can reduce to the same slug. A run is complete only when its `final.md` exists; a folder without one records a run that failed after its reviews finished. History entries also carry `run_directory`, so the history files index the completed runs.

Never delete, move, or overwrite a run folder, including one left by a failed run. Artifacts that earlier versions of this workflow wrote directly into `.reviews/` or `.reviews/codex-led/` are left as they are; never write to or remove them.

## run-context.json

Schema version 3. Splice the estimator's own `review_size` and `estimate` objects in verbatim rather than retyping their fields.

```json
{
  "schema_version": 3,
  "review_id": "9d2c7f15-baa0-4fa6-82f4-5151dfd43be2",
  "review_mode": "pull_request",
  "invoked_at": "2026-09-09T19:58:30.0000000Z",
  "invoked_at_unix_ms": 1788983910000,
  "started_at": "2026-09-09T20:00:00.0000000Z",
  "started_at_unix_ms": 1788984000000,
  "run_directory": ".reviews/runs/pr-1234_20260909T200000Z_claude-led_9d2c7f15",
  "repository": { "id": "repository-guid", "name": "example-repo", "url": "https://dev.azure.com/org/project/_git/example-repo" },
  "pull_request": {
    "id": 1234,
    "source_ref": "refs/heads/feature/example",
    "target_ref": "refs/heads/main",
    "source_commit": "full-source-commit-id",
    "target_commit": "full-target-commit-id"
  },
  "local": { "branch": "feature/example", "head_commit": "full-local-head-commit-id" },
  "tooling": {
    "pr_metadata": "azure_devops_mcp",
    "claude_review": "native_code_review",
    "codex_review": "native_codex_exec_review",
    "claude_model": "claude-opus-4-7",
    "claude_effort": "high",
    "claude_model_source": "session_context",
    "claude_effort_source": "explicit",
    "codex_model": "gpt-5.6-sol",
    "codex_reasoning_effort": "high",
    "codex_model_source": "codex_doctor",
    "codex_reasoning_effort_source": "explicit",
    "codex_comparison_model": "gpt-5.6-sol",
    "codex_comparison_model_source": "codex_doctor",
    "codex_comparison_reasoning_effort": "medium",
    "codex_comparison_reasoning_effort_source": "explicit"
  },
  "review_size": "<the estimator's review_size object, verbatim>",
  "estimate": "<the estimator's estimate object, verbatim>"
}
```

`run_directory` is the `run_directory_relative` value returned by `New-ReviewRunDirectory.ps1`: repository-relative with forward slashes. It is required for every completed review. The history writer verifies that it identifies the folder containing `final.md` before copying it into the history entry; reports outside `.reviews/runs/` are rejected, as are a ledger, metrics file, or run context outside that same folder.

`invoked_at` is when the command began; `started_at` is captured immediately after approval and is the start used for duration, so user decision time never trains estimates. Unix milliseconds are authoritative; the ISO text is for readability.

`pr_metadata` is one of `azure_devops_mcp`, `azure_cli_fallback`, `azure_devops_mcp_no_match`, `azure_cli_fallback_no_match`, `not_queried`, `not_applicable_no_origin`, or `not_applicable_non_azure_origin`.

Model and effort values are nullable, because not every CLI exposes an exact effective default before invocation. Their `_source` fields are `session_context`, `explicit`, `codex_doctor`, `cli_default_unresolved`, or `unavailable`. Store JSON `null` when a value is unresolved and render a fallback such as `CLI default (exact model unresolved)` in human-readable output only. Never store that label as if it were an identifier.

The existing `codex_model`, `codex_reasoning_effort`, and their source fields describe the independent review. Record the comparison separately in `codex_comparison_model`, `codex_comparison_model_source`, `codex_comparison_reasoning_effort`, and `codex_comparison_reasoning_effort_source`. Copy the independent review's model and model source into the comparison model fields; the independent review's effort is always `high` and the comparison effort is always `medium`, both with source `explicit`. Report both stages' settings in the final report. The history writer preserves these fields through the run context's `tooling` object; older history entries without comparison fields remain valid.

## Finding IDs and severity

Assign IDs immediately after each independent review, in that review's original order:

- Claude: `C-001`, `C-002`, ...
- Codex: `X-001`, `X-002`, ...

Use at least three digits and expand naturally after 999. Never recycle or renumber an ID. An ID represents one raw initial finding, not an underlying issue group.

Normalize each initial severity to `high`, `medium`, or `low`. Map `critical` or blocking/security-critical findings to `high`, informational or nit findings that still qualify as findings to `low`, and otherwise pick the closest stated severity. Keep the original label in the review artifact. Do not count prose observations that are not findings.

## adjudication.json

```json
{
  "schema_version": 3,
  "review_id": "9d2c7f15-baa0-4fa6-82f4-5151dfd43be2",
  "review_mode": "pull_request",
  "status": "complete",
  "repository": {
    "id": "repository-guid",
    "name": "example-repo",
    "url": "https://dev.azure.com/org/project/_git/example-repo",
    "project_id": "project-guid",
    "project_name": "Example Project"
  },
  "pull_request": {
    "id": 1234,
    "source_ref": "refs/heads/feature/example",
    "target_ref": "refs/heads/main",
    "source_commit": "full-source-commit-id",
    "target_commit": "full-target-commit-id"
  },
  "local": {
    "branch": "feature/example",
    "head_commit": "full-local-head-commit-id"
  },
  "findings": [
    { "id": "C-001", "reviewer": "claude", "severity": "high" },
    { "id": "X-001", "reviewer": "codex", "severity": "medium" }
  ],
  "groups": [
    {
      "id": "G-001",
      "source_ids": ["C-001", "X-001"],
      "disposition": "confirmed",
      "final_severity": "high"
    }
  ],
  "adjudication": {
    "codex_disposition_overrides": [
      {
        "group_id": "G-001",
        "codex_disposition": "uncertain",
        "final_disposition": "confirmed",
        "reason": "The source and regression test establish the failure path."
      }
    ]
  }
}
```

Repository ID and name, local branch and HEAD, and the source/target refs and commits are always required and non-empty. `pull_request` mode additionally requires the repository URL, project identity, and a positive `pull_request.id`; the other modes set that ID to `null`. A non-PR repository with no remote uses an empty URL.

The `pull_request` object is the scope container in every mode:

| `review_mode` | `pull_request.id` | source | target |
| --- | --- | --- | --- |
| `pull_request` | positive integer | fetched PR source ref/commit | fetched PR target ref/commit |
| `uncommitted` | `null` | `WORKTREE` at local HEAD | `HEAD` at the same commit |
| `branch` | `null` | current branch at local HEAD | resolved `main` or `master` ref/commit |

Rules the calculator enforces:

- Every `C-*` and `X-*` ID appears in exactly one group.
- `confirmed` requires a `final_severity` of `high`, `medium`, or `low`; `rejected` and `uncertain` must leave it absent or null.
- `adjudication.codex_disposition_overrides` is required and is `[]` when empty.

Merge findings into one group only when they describe the same root cause and materially the same impact. A confirmed group holding both a `C-*` and an `X-*` ID is cross-model agreement; one holding IDs from a single reviewer is reviewer-only confirmed.

Add one override entry whenever your final disposition differs from Codex's proposed disposition for that group. This records disposition changes only — not severity changes or regrouping — and does not prove either model was objectively correct.

## Final report presentation

In both `<run_directory>/final.md` and the final chat output, place a high-level `Change summary` before the review findings. Aim for one or two paragraphs and never exceed four. Summarize the reviewed diff rather than the review process: explain the main behavior and affected areas, leading with critical or breaking changes and any compatibility, migration, configuration, data, API, deployment, or rollout implications. If no breaking change is evident, say so briefly rather than inventing one. Base the summary on the frozen diff and inspected source; PR title and description are context, not proof. For branch and uncommitted modes, summarize the selected change scope the same way.

## Effectiveness summary

`<run_directory>/final.md` and the final chat output must both contain this block. Take the effectiveness values from `metrics.json`. Compute total run time from the authoritative `started_at_unix_ms` through final-report generation, round to the nearest second, and render it as a compact duration such as `8m 14s` or `1h 03m 09s`:

```text
Cross-review effectiveness

Total run time: <duration>

Initial:
  Claude: <high> high, <medium> medium, <low> low (<total>)
  Codex:  <high> high, <medium> medium, <low> low (<total>)

Final:
  <high> high, <medium> medium, <low> low (<total>)

Agreement:               <count>
Claude-only confirmed:   <count>
Codex-only confirmed:    <count>
Rejected false positives:<count>
Merged duplicates:       <count>
Uncertain findings:      <count>
Adjudicator overrides:   <count>

Claude precision:        <percent or N/A>
Codex precision:         <percent or N/A>
Codex added value:       <percent or N/A>
Cross-review reduction:  <percent or N/A>
```

Display ratios as percentages rounded to one decimal place, and any null metric as `N/A`. The calculations are deterministic once the ledger is valid, but severity normalization, grouping, and adjudication remain model judgments: precision describes confirmation by this pipeline, not an objective ranking of Claude against Codex.

## Version 4: Codex-led workflow

The Claude-led workflow continues writing version 3 unchanged. Codex-led run context, ledger, metrics, and history use `schema_version: 4`. The shared calculator and history writer accept both versions; never rewrite existing histories. All scope, provenance, severity, timestamp, and grouping rules above still apply.

Codex-led run folders use the `codex-led` variant under the shared `.reviews/runs/` and contain `claude-evaluation.md` instead of `codex-evaluation.md`. Local history is `<original-repository-root>/.reviews/codex-led/history.jsonl`; global history is `<user-profile>/.codex/cross-review/history.jsonl`. Pass these paths explicitly to the estimator and history writer. Do not mix in Claude-led history. Validate storage with `Assert-ReviewStorageSafe.ps1 -Variant codex-led`, adding `-RunDirectory <run_directory>` before writing artifacts.

### Tooling

In the version-4 run context, keep `pr_metadata`, `claude_review`, `codex_review`, and the independent reviewers' model/effort fields above. Set `claude_model_source: explicit` when a discovered model or alias was supplied to the child; otherwise use null model and `cli_default_unresolved`. A supplied alias is recorded verbatim, without guessing its resolved version. Claude's independent effort remains `high` with source `explicit`. Add:

```json
{
  "orchestrator": "codex",
  "comparison_provider": "claude",
  "claude_comparison_model": null,
  "claude_comparison_model_source": "cli_default_unresolved",
  "claude_comparison_effort": "medium",
  "claude_comparison_effort_source": "explicit",
  "adjudicator_model": null,
  "adjudicator_model_source": "unavailable",
  "adjudicator_reasoning_effort": null,
  "adjudicator_reasoning_effort_source": "unavailable"
}
```

These are fields inside `tooling`, not another top-level object. Omit the version-3 `codex_comparison_*` fields: Codex is not running that comparison. If the current Codex session exposes its model/effort, record them with `session_context`; do not use Codex CLI diagnostics as a proxy for this session. An explicit Claude model is passed unchanged to both Claude stages. Native review subagents can use other models; do not infer the main session model from a multi-model usage breakdown. Preserve the honest preflight labels in the final report.

### Adjudication

Replace the version-3 `adjudication` object with:

```json
{
  "adjudicator": "codex",
  "comparison_provider": "claude",
  "comparison_disposition_overrides": [
    {
      "group_id": "G-001",
      "comparison_disposition": "uncertain",
      "final_disposition": "confirmed",
      "reason": "Source evidence establishes the failure path."
    }
  ]
}
```

The override array is required and is `[]` when empty. Do not include `codex_disposition_overrides` in version 4. The calculator requires distinct Claude/Codex comparison and adjudicator roles. The history writer verifies those roles agree across the ledger, metrics, and run context's tooling. Record disposition overrides against the comparison provider, not against initial review findings. Explain regrouping separately when a final group has no one-to-one comparison proposal.

### Metrics

Version 4 retains all existing metrics and adds `metrics.claude_added_value`: Claude-only confirmed groups divided by all confirmed groups, or null for a zero denominator. Include `Claude added value` alongside `Codex added value` in the effectiveness summary. Version-4 metrics also record `adjudication.adjudicator` and `adjudication.comparison_provider`. The history writer preserves stage settings and both added-value metrics. These values describe contribution under the named final adjudicator, not an objective ranking of models.
