# Repository providers

Both host skills use this workflow before their existing estimation, confirmation,
independent review, comparison, and adjudication stages. All script paths are
relative to the installed skill directory. Keep PR lookup and comments read-only.

## Local identity and selection

Parse arguments with `Resolve-ReviewArguments.ps1`. It accepts `pr <number>` or
`pr <GitHub-PR-URL>` and the existing effort option. Retain `pr_url` alongside the
number; pass `-PrUrl <url>` to the resolver whenever it is present.

Use `Resolve-ReviewPr.ps1 -LocalOnly` for local identity. It reports `provider`
(`azure_devops`, `github`, `unknown`, `local`), `provider_host`, the selected
`remote_name`, sanitized identity, tracking source, and root/branch/HEAD. Batch
this with the existing Git status read. With a PR URL, pass that URL to the local
identity call too. A URL must match a recognized local remote.

The branch tracking remote takes precedence, then origin, then a sole remote.
Multiple remotes without tracking or origin stop as ambiguous. A GitHub PR URL
selects its target remote explicitly, including upstream for fork PRs. The source
repository remains the branch's tracking remote, or origin when tracking is absent.
URL-valued tracking (as configured by `gh pr checkout`) identifies the source
repository even without a named fork remote. The target uses a matching configured
remote, then origin or a sole remote; ambiguous targets still stop. Recognized
provider URLs retain their identity when Git redirects transport to a mirror;
shorthand `insteadOf` aliases are expanded for provider detection.
Never choose a fork solely by its branch name. Review source ref must still match
the exact current local branch. A renamed local/tracking branch requires the user
to align the branch; do not silently widen this guard.

GitHub.com is detected from HTTPS and SSH URLs. GitHub Enterprise hosts are
recognized through `GH_HOST` or an explicit helper `-GitHubHost <host>` argument;
propagate that argument to subsequent resolver/scope calls. An arbitrary two-part
remote URL does not prove it is GitHub. Unknown and no-remote repositories remain
eligible for uncommitted and branch review without provider CLI authentication.

Preserve scope precedence: explicit PR, uncommitted changes, discovered PR,
branch comparison, nothing to review. Discover PRs only for supported providers;
skip lookup when local changes take precedence. Do not turn an authentication or
API failure into a zero-result lookup or silently fall through to branch review.

## PR metadata

Use the selected provider's available MCP operation first, then its CLI if MCP is
absent, disconnected, errors, lacks the operation, or lacks required fields.
Disclose the fallback reason. Successful zero-result discovery is final; do not
repeat through CLI. Repository, source-repository, branch, PR-state, requested-ID,
and ambiguity failures stop; they are never fallback triggers.

For automatic discovery, list all open/active PRs for the selected target repository
and exact source repository/branch; get the sole candidate in full. Pagination must
be complete before declaring no match or a sole match. For GitHub, the CLI adapter
uses REST head filtering and validates the returned source repository as well.

Pass complete raw get metadata to `Resolve-ReviewPr.ps1 -MetadataPath <file>`.
Also pass `-PullRequestId <number>` for explicit requests and `-PrUrl <url>` when
present. Store temporary metadata outside the reviewed repository and delete it
after normalization. Do not reconstruct metadata. Azure accepts its existing
full PR record and status enum shapes. GitHub accepts a complete REST-shaped PR
record with `number`, `state`, `html_url`, `head` and `base` (each containing
`ref`, `sha`, and `repo.full_name`). An unusable MCP shape qualifies for CLI
fallback; a usable record that fails an identity guard does not.

CLI fallback calls:

```powershell
& '<skill_dir>/scripts/Resolve-ReviewPr.ps1' -PullRequestId <number> [-PrUrl <url>]
& '<skill_dir>/scripts/Resolve-ReviewPr.ps1' -AllowNoMatch
```

Azure uses authenticated `az repos pr`; GitHub uses authenticated `gh api`.
Open draft GitHub PRs are eligible and retain their draft flag. Closed/merged PRs
are not. Azure PR and local repository IDs retain their existing values; GitHub
uses `github://<host>/<owner>/<repo>` consistently across local and PR modes.
Provider identity is independent of `metadata_transport` (`mcp` or `cli`).

Save the validated normalized result to a temporary context JSON file, then:

```powershell
& '<skill_dir>/scripts/Get-ReviewPrScope.ps1' -ContextPath <normalized-context-json>
```

This fetches source and target into dedicated `refs/cross-review/pr/<number>/*`
refs without switching branches. GitHub fetches `refs/pull/<number>/head` from
the target repository, so forks work without adding a remote. Use returned
`source_commit` and `target_commit` for estimation and both reviewers. The local
refs are diagnostic fetch destinations and may move; never let a concurrent fetch
change the estimate or approved scope. Neither reviewer receives a PR number or
the synthetic merge commit.

The helper checks fetched source against metadata. Neither provider's reported
base tracks the target tip: GitHub `base.sha` stays at the base as of the last
head push, and Azure `lastMergeTargetCommit` may lag. The freshly fetched target
is authoritative for both. On a moved-PR error, refresh the full metadata using
the same access method, revalidate, and retry up to twice. Stop if it keeps moving.
Never present a preflight for mismatched revisions. Delete temporary context files
on cancellation/cleanup. Handle fetch permission failures as described below.

For non-PR branch scope, use `Resolve-ReviewBase.ps1`. It reads the selected
remote's advertised default branch (any valid name), fetches it, and returns
`target_ref`, `target_local_ref`, `target_commit`, and `is_default_branch`.
Without a remote, use an existing main/master branch. Stop when no base resolves;
when already on the resolved default branch there is nothing to review. Freeze
the result as usual. A failed remote lookup/fetch is an error.

## Fetch permission recovery

If a required PR or default-branch fetch fails because the host sandbox denies
network access or writes to Git metadata (for example `.git/FETCH_HEAD`), request
narrow host approval and retry only the required fetch operation. When fetching
through `Get-ReviewPrScope.ps1` or `Resolve-ReviewBase.ps1`, isolate that helper
invocation in its own approval request; do not bundle setup or reviewer commands.
Retain the validated repository, remote, refs, and context arguments. Use the
host's command approval mechanism (in Codex, `exec_command` with
`sandbox_permissions: require_escalated` and a fetch-specific justification).
Do not request Full access, persistent blanket Git permissions, an approval
bypass, or a writable reviewer sandbox.

If approval is denied or unavailable, stop and report the required fetch access.
Authentication, network/service, invalid-ref, and identity/PR guard failures are
errors, not reasons to request broader host permissions. After a successful
retry, use the helper's validated frozen commits and continue to estimation and
the normal review confirmation. Fetch approval does not authorize the review or
any later setup operation; those retain their existing permission requirements.

## Preflight and saved identity

Show a separate line immediately after review scope in every preflight:

```text
Repository provider: GitHub (github.com)
Repository provider: Azure DevOps (dev.azure.com)
Repository provider: Unknown (<host or local remote>)
Repository provider: Local Git (no remote)
```

Choose one line using detected identity, including uncommitted and branch modes.
Show `Repository: <host/owner/repo>` for GitHub or Azure organization/project/repo.
Show source and target repository identities for fork PRs alongside their refs
and frozen commits. Separately show `PR metadata: <provider> MCP` or
`<provider> CLI (fallback: <reason>)`; disclose no-match, skipped-by-precedence,
or unsupported/no-remote lookup as appropriate. This is detection information,
not a claim that PR lookup occurred.

Copy `repository.provider`, `repository.host`, and GitHub `repository.owner`
into run-context and adjudication; include PR URL, `source_repository`, and
`target_repository` in both PR scope objects. Preserve legacy Azure project
fields. Record metadata access separately in tooling. Show provider and host
in the final report as well. Follow the artifact contract for compatibility.

## Discussion snapshot

Capture discussion only after both independent reviews finish. Use the shared
`Get-PrCommentSnapshot.ps1` dispatcher:

```powershell
# Azure: existing arguments remain supported.
& '<skill_dir>/scripts/Get-PrCommentSnapshot.ps1' -Provider azure_devops `
  -PullRequestId <number> -OrganizationUrl <url> -Project <project> `
  -RepositoryId <id> -OutputPath <artifact_dir>/pr-comments.json

# GitHub, including Enterprise:
& '<skill_dir>/scripts/Get-PrCommentSnapshot.ps1' -Provider github `
  -PullRequestId <number> -HostName <validated-host> `
  -RepositoryFullName <validated-owner/repo> -OutputPath <artifact_dir>/pr-comments.json
```

Prefer a capable MCP operation, supplying `-RawResponsePath <file>`, otherwise
use the provider CLI and disclose why. Azure retains its raw thread-array/value
envelope contract. GitHub raw input must be a complete GraphQL response (or a
`repository` envelope), including repository `nameWithOwner`, URL, PR number,
and `comments`, `reviews`, and `reviewThreads` connections. Each connection
needs `nodes` and `pageInfo.hasNextPage:false`, including every thread's comments.
The CLI paginates all three connections and every thread's replies separately.
Missing capabilities, GraphQL errors, incomplete pages, and access failures are
errors, never empty discussions. A deficient MCP response may fall back to CLI;
an identity mismatch stops. Delete temporary raw payloads after normalization.

GitHub preserves conversation comments, submitted review summaries, inline
threads and replies, resolved/outdated state, original/current locations,
comment URLs, and commit context. Pending review drafts are omitted. Capability
fields record which structures were captured; Azure status/iteration context
is preserved rather than fabricated into GitHub concepts. Unknown status stays
unknown. Resolve claims against the frozen source, not status alone. Existing
discussion and comment-only concerns remain outside model-effectiveness metrics.
