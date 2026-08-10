---
name: code-review
description: Adversarial code review loop driven by a peer agent CLI. Submits code diffs to the other agent CLI for critical review, fixes findings, and iterates until approved. Use after implementing high-stakes changes.
---

# Adversarial Code Review

Iterative adversarial code review. Submit a git diff to the **peer agent** for critique, fix material findings, repeat until approved or the user stops.

The peer is always the agent CLI that is **not** running this skill - Claude Code is reviewed by Codex, Codex is reviewed by Claude Code. A reviewer that shares the author's model shares the author's blind spots. The runtime picks the peer for you; never override it.

The default workflow always uses that host-derived peer. Use the explicit Cursor workflow only when the user explicitly requests Cursor with one alias: `composer`, `grok`, `kimi`, or `glm`.

`$ARGUMENTS` optionally specifies scope, focus areas, or `--base <branch>` for branch comparison.

All peer interaction goes through the runtime, so a single `Bash(adversarial-review *)` allowlist rule covers every call in Claude Code.

## User decision prompts (host-specific)

Use the host's native interaction method for each question that requires a user answer:

- **Claude Code:** use the `AskUserQuestion` tool.
- **Codex:** use `request_user_input` when it is available.
- If Codex does not make `request_user_input` available in the current mode, ask one clear plain-text question, present the same options, and stop. Do not continue until the user replies.

Never skip a checkpoint, scope confirmation, or caveat decision because a structured prompt tool is unavailable.

## Allowed invocations (exhaustive)

Use ONLY the invocations below. Do NOT invent flags, rename them, or use variants like `--review-type`, `--payload-file`, `--input`, or `--mode plan`. If an invocation you have in mind is not in this list, it is wrong - re-read the skill.

| Purpose | Command |
|---------|---------|
| Pre-flight check | `{invocation.review} detect` |
| Cursor pre-flight check | `{invocation.review} detect --peer cursor` |
| Inspect repo | `{invocation.review} inspect-repo` |
| Generate unique context path | `{invocation.review} new-ctx --kind code` |
| Code review (iteration 1) | `{invocation.review} code-review --mode <uncommitted\|staged\|branch> [--base REF] [--paths "..."] --repo-context [--self-collect] --first` |
| Code review (subsequent) | `{invocation.review} code-review --mode <...> [--base REF] [--paths "..."] --context-file <path> --repo-context [--self-collect]` |
| Cursor code review (iteration 1) | `{invocation.review} code-review --peer cursor --model <selected-alias> --mode <uncommitted\|staged\|branch> [--base REF] [--paths "..."] --repo-context [--self-collect] --first` |
| Cursor code review (subsequent) | `{invocation.review} code-review --peer cursor --model <selected-alias> --mode <...> [--base REF] [--paths "..."] --context-file <path> --repo-context [--self-collect]` |

The default `code-review` command accepts only `--mode`, `--base`, `--paths`, `--context-file`, `--first`, `--model`, `--repo-context`, `--self-collect`, `--include-secrets`, `--include-large`, `--include-binary`, and `--allow-skipped-large`. Cursor additionally accepts `--peer cursor`, but its `--model` must be one selected alias: `composer`, `grok`, `kimi`, or `glm`. Do not pass an arbitrary Cursor model ID.

**`--self-collect`** is an optional optimization for `--repo-context` mode: instead of bundling the full diff into the payload, it ships a compact manifest (mode, scope, changed-file list) and lets the peer read what it needs from the repo directly. Use it when the diff is large enough that bundling it eats payload tokens the peer could spend reading exactly the relevant files. Requires `--repo-context`. Skip it for small/medium diffs - bundling the full diff is faster and more deterministic.

This skill reviews **git diffs only**. For reviewing a plan before implementation, use `/plan-review`.

When fixing findings, prefer the smallest change that fully resolves the real issue. Do not refactor, generalize, or add abstractions unless the simpler fix would leave a concrete correctness, reliability, or maintainability problem behind.

## Step 0 - Pre-flight check (mandatory hard gate)

For the default workflow, this is the **only** step where the command spelling depends on the host, because it is what tells you the spelling for everything else. Pick the line that matches the CLI you are running in:

```bash
# Claude Code - the plugin's bin/ is on PATH:
adversarial-review detect

# Codex - bin/ is NOT on PATH; address the runtime directly.
# Resolve this path relative to THIS SKILL.md file, not the shell's cwd:
node ../../scripts/orchestration.mjs detect
```

On success returns:

```json
{ "ok": true, "host": "...", "peer": "codex" | "claude", "peerName": "...",
  "invocation": { "review": "..." },
  "version": "...", "reviewConfinement": { ... } }
```

**Use `invocation.review` verbatim as the command prefix for every remaining call in this skill.** Wherever this document writes `{invocation.review}`, substitute that string. Do not re-derive it and do not fall back to a bare command name.

On failure STOP and diagnose:
- **`command not found`**: plugin not installed, or you used the Claude Code form inside Codex. Try the `node ../../scripts/orchestration.mjs` form.
- **`"error": "unknown_host"` / `"ambiguous_host"`**: the runtime could not tell which CLI is driving it (this happens when one agent CLI runs inside another). Re-run with the `--host` value named in the `hint` field.
- **`"error": "peer_unavailable"` / `"peer_too_old"`**: the peer CLI is missing, unauthenticated, or too old. Present each `setupHints` entry as an actionable step, then re-run `detect` to confirm.

Do not continue past Step 0 until `detect` returns `ok: true`.

### Explicit Cursor workflow

When the user explicitly requests Cursor with `composer`, `grok`, `kimi`, or `glm`:

1. Run `{invocation.review} detect --peer cursor`.
2. Stop unless the result has `ok: true`. Use `invocation.review` verbatim for every later call.
3. Run `{invocation.review} code-review --peer cursor --model <selected-alias> ...` for the initial review and preserve those flags on subsequent iterations.
4. Preserve `--peer cursor` and `--model <selected-alias>` on every review command and the one allowed retry.
5. Stop on every explicit-Cursor detection or execution failure. Never fall back to Codex or Claude.

Do not use this branch for a request that does not explicitly name Cursor and one supported alias. The default workflow remains host-derived.

**Permission heads-up (Claude Code host only):** the `permissions` field is present only when `host` is `claude-code`. If it is present and `permissions.tmp_write_preapproved` is `false`, tell the user once (plain text is fine here, this is not a decision prompt):

> Heads up: subsequent iterations write the review context file under your system temp directory (`{permissions.tmpdir}/adversarial-code-ctx-<slug>.txt`), so you'll see a file-write permission prompt. It's scratch space for the review - safe to approve. To pre-approve it for future runs, add `{permissions.expected_rule}` to `permissions.allow` in `~/.claude/settings.json`. Two things matter about that rule: it must use `Edit(...)`, because Claude Code checks file permissions against `Edit` and `Read` rules only and silently ignores `Write(...)` path rules; and the leading `//` is required, since a single `/` anchors to the project root rather than the filesystem root.

Substitute the literal `{permissions.tmpdir}` and `{permissions.expected_rule}` values from the `detect` response. If `permissions.legacy_write_rules` is present, the user has an obsolete `Write(...)` rule that Claude Code never consults - tell them to replace it with `permissions.expected_rule`.

Skip this message when `tmp_write_preapproved` is `true` or the `permissions` field is absent.

## Step 1 - Inspect repo

Initialize: `iteration = 0`, `finding_ledger = []`.

```bash
{invocation.review} inspect-repo
```

Returns JSON with `inWorkTree`, `hasDirty`, `ahead`, `defaultBranch`, `status`, `hasSubmodules`. If `inWorkTree` is false, stop - this skill requires a git repo. Tell the user to `cd` into the repo they want to review.

## Step 2 - Determine review mode

Mode precedence (first match wins):

1. **`--base <branch>` specified** in `$ARGUMENTS` → `branch` mode. Use the user-supplied base.
2. **`--staged` specified** in `$ARGUMENTS` → `staged` mode (reviews only staged changes).
3. **`hasDirty == true`** in inspect-repo output → `uncommitted` mode (covers any dirty worktree state uniformly).
4. **`ahead > 0` and no dirty state** → prompt the user: "Your branch has {ahead} committed changes vs {defaultBranch} but no uncommitted work. Use `--base {defaultBranch}` to review the branch diff."
5. **Otherwise** (no dirty state, not ahead of default) → stop. Tell the user there's nothing to review and suggest they make changes first, or run `/plan-review` if they want to vet a plan instead.

If `hasSubmodules == true`, surface a note to the user that submodule working trees are not included.

### Scope handling

`$ARGUMENTS` may include explicit paths. If so, pass them as `--paths "path1 path2"` on every iteration. Otherwise omit `--paths` - the runtime defaults to the full changed set.

### Secret exclusion

The runtime automatically excludes, case-insensitively:

- env files: `.env`, `.env.*` (templates like `.env.example` are allowed through)
- key and cert material: `*.pem`, `*.key`, `*.p12`, `*.pfx`, `*.jks`, `*.keystore`, `*.ovpn`
- SSH private keys: `id_rsa`, `id_dsa`, `id_ecdsa`, `id_ed25519`
- credential files: `.npmrc`, `.netrc`, `_netrc`, `.pypirc`, `.pgpass`, `.git-credentials`, `credentials`, `credentials.json`, `service-account*.json`, `htpasswd`
- cluster and infra config: `kubeconfig*`, `secret.yml`/`secret.yaml`, `secrets.yml`/`secrets.yaml`, `vault.yml`/`vault.yaml`, `*.tfvars`

If the user asked to review one of those explicitly, pass `--include-secrets` to opt in. Source files like `SecretManager.ts` are NOT excluded.

**This is a filename heuristic, not a content scanner.** A token pasted into an ordinary source or config file is not detected and will be sent to the peer. Say so plainly if the user asks whether the review is safe for a repo with embedded credentials.

When `--repo-context` is set, the runtime also runs a preflight that walks the working tree (tracked + untracked, including gitignored, plus submodules) and refuses to invoke the peer if any secret-bearing files exist (`error: "secret_files_in_tree"`). A peer running under an OS sandbox (Codex) is still not path-restricted for reads, so manifest-level exclusions are not a security boundary in repo-context mode. When you see that error, present the `files` list and let the user pick:
- "Remove or relocate the file(s)" → stop; user fixes their tree, then re-run.
- "Run without `--repo-context`" → re-run dropping that flag (the peer sees only the diff payload).
- "Opt in to exposing them" → re-run with `--include-secrets` (the user has accepted the risk).

### Large-file handling

The runtime also skips changed files larger than 100KB by default to keep the payload reviewable. The runtime fails closed (`error: "large_files_skipped"`) before invoking the peer when any large files are skipped. When you see that error, issue a user decision prompt that lists `largeSkipped` and provides these options:
- "Include large files" → re-run the same command with `--include-large` (their full contents go into the payload).
- "Proceed without them" → re-run with `--allow-skipped-large` (they stay out; the review continues).
- "Cancel" → stop and report the skipped list.

## Step 3 - Submit code review

Increment iteration. Display: `[Code Review: iteration N]`.

**First iteration** (no context file needed):
```bash
{invocation.review} code-review --mode {uncommitted|staged|branch} [--base {base}] [--paths "..."] --repo-context [--self-collect] --first
```

**Subsequent iterations** - on the first iteration that needs a context file, generate a unique context path and reuse it for every subsequent iteration of this review. The runtime gives you one on request:

```bash
{invocation.review} new-ctx --kind code
```

This emits `{ ok, path, slug }`. Remember `path` for the remainder of the review; don't regenerate it per iteration (that would lose iteration-to-iteration continuity). Using a fresh path per review avoids collisions when the user has multiple reviews running concurrently.

Use the Write tool **once** per iteration to (re)create that file:

```
===== UNRESOLVED FINDINGS START =====
<open findings from ledger>
===== UNRESOLVED FINDINGS END =====
===== LATEST FIXES START =====
<what changed this iteration>
===== LATEST FIXES END =====
```

Then:
```bash
{invocation.review} code-review --mode {mode} [--base ...] [--paths ...] --context-file {path-from-new-ctx} --repo-context [--self-collect]
```

Per iteration that's at most **one Write + one Bash call**. Run with a 600s timeout (the runtime itself times out at 600s - the Bash tool invocation should match). Run it as one plain command line.

The response is JSON: `{ ok, status, output, skipped }`. Parse `status` directly. `skipped` is the list of files excluded for secrets/binary/size reasons - surface any entries to the user.

If `ok: false`, the JSON contains an `error` field (`peer_unavailable`, `peer_too_old`, `peer_failed`, `missing_status_line`, `payload_too_large`, `large_files_skipped`, `secret_files_in_tree`, `secret_preflight_failed`, `invalid_base`, `invalid_usage`, `payload_build_failed`). A human-readable reason accompanies it in `detail` where one applies. `invalid_base` means the `--base` ref has no merge-base with HEAD: ask the user for a valid ref rather than retrying. `invalid_usage` means the command line was malformed: re-read the allowed invocations above, do not improvise a flag.

**Single retry for transient provider failures only:** if the failed review JSON also contains:

```json
{ "retryable": true, "retryReason": "...", "retryInstruction": "rerun_same_command_once" }
```

rerun the exact same `{invocation.review} code-review ...` command once: same mode, same flags, same context file, no code edits, no regenerated context file, and no prompt to the user before the retry. In the explicit Cursor workflow, preserve the same `--peer cursor` and `--model <selected-alias>` values on `rerun_same_command_once`. If the retry returns `ok: true`, process that response normally. If it fails again, report both failures and ask the user how to proceed.

Never retry a response without `retryable: true`. Every other failure is a real condition that a second identical run would only repeat.

For all other failures, report the failure and ask the user how to proceed.

## Step 4 - Process feedback

Update the finding ledger:
- New findings get a stable ID (e.g., `F1-1`, `F1-2` for iteration 1).
- Findings matching a previously addressed issue are marked as regressions.
- Duplicate/rephrased findings referencing the same root cause are merged.
- Each finding has status: `open`, `addressed`, `deferred`, `disagreed-with-rationale`.

Disposition ALL findings - every finding must be explicitly `addressed`, `deferred`, or `disagreed-with-rationale`. If disagreeing, explain reasoning to the user.

**Fully approved** (all findings `addressed`): go to Step 6.
**Approved with caveats** (deferred/disagreed items): issue a user decision prompt with this content:
- `question`: "Review approved with caveats - {N} findings deferred or disagreed. How would you like to proceed?"
- `header`: "Caveats"
- Allow one selection.
- `options`:
  1. label: "Accept current state" / description: "Proceed to final summary with caveats noted"
  2. label: "Reopen selected" / description: "Choose specific findings to reopen for further iteration"

**Changes required**: fix open findings, record what changed.

**Checkpoint gate (mandatory):** After fixing, check whether `iteration % 3 == 0`. If true and merge-blocking findings remain, STOP - go to Step 5. Do not return to Step 3 until the user has responded at the checkpoint.

If no checkpoint is due, return to Step 3.

Treat the Bash step as complete as soon as the JSON returns a `status` field. Once the peer has replied, do not re-scan the whole repository.

### Triage - classify before deciding

For each finding, classify it FIRST into one of two categories, then decide:

- **(a) In-scope**: the finding identifies a concrete failure the diff introduces - new bug, regression, incomplete change, broken existing behavior the diff touches. Default: `open`, fix in next iteration.
- **(b) Out-of-scope**: the finding proposes work beyond the inferred change intent - pre-existing issues in surrounding code, general hardening opportunities, defense-in-depth additions, observability improvements, or refactors unrelated to the diff's goal. Default: `disagreed-with-rationale`. Rationale is one line: "Beyond change intent: <intent summary>." **Do not flip to `addressed` unless the finding demonstrates a concrete failure the diff itself introduces - "this would be nice to have" or "this is best practice" is not sufficient.**

Only after classification, apply the merge-blocking bar to the remaining (a) findings:
- Only iterate on issues that would independently justify blocking a merge.
- Prefer the simplest fix that closes the real risk; reject added abstraction or refactors unless they are necessary.
- If only nitpicks remain, recommend stopping at the next checkpoint.

### Early checkpoint on scope creep

If more than 50% of this iteration's findings are classified (b), STOP and checkpoint immediately regardless of iteration number - skip to Step 5. The peer is expanding scope beyond the change; continuing will compound. Recommend "Stop here" unless the user sees an in-scope finding worth pursuing.

### Scope re-evaluation after fixes

If later changes expand beyond the user's explicit scope, tell the user. Otherwise keep reviewing the full changed set without reconfirming.

### Optional delegation

If multiple independent findings touch disjoint files or subsystems, you may use sub-agents to inspect or fix one finding each in parallel. Keep the ledger, checkpointing, and every peer submission in the main agent.

## Step 5 - Checkpoint every 3 iterations

Immediately after iterations 3, 6, 9, etc., if not fully approved, stop before making more edits.

Present:
- What has been fixed so far (full ledger of addressed findings)
- What the peer is still unhappy about (remaining open findings)
- A clear recommendation (default: stop unless at least one remaining finding clearly clears the merge-blocking bar)

Issue a user decision prompt with this content:
- `question`: "Checkpoint at iteration {N}. Recommended: {recommended_option} - {short reason}. How would you like to proceed?"
- `header`: "Checkpoint"
- Allow one selection.
- `options` (put the recommended option first and append "(Recommended)" to its label):
  1. label: "Continue iterating" / description: "Continue iterating on all remaining findings"
  2. label: "Focus on selected" / description: "Choose specific findings to keep open and defer the rest"
  3. label: "Stop here" / description: "Accept the current state and produce the final summary"

If "Focus on selected": ask "Which finding IDs should stay open? I'll defer the rest."

There is no hard iteration cap. If you judge that the peer is nitpicking, say so clearly and recommend stopping.

## Step 6 - Final summary

Present a cumulative report:

- Result: approved / approved with caveats / stopped at checkpoint
- Short review timeline by iteration
- Full finding ledger with statuses and resolutions
- Statistics: iterations, findings raised, addressed, deferred, disagreed
- If the peer approved and `finding_ledger` is empty, say so explicitly: "No adversarial findings. The critic inspected <review target>." Name the actual target - the mode, the base branch when applicable, and the paths or the full changed set. A clean review and a review that never reached the peer look identical otherwise, and the user cannot tell which they got.
- Code status: changes remain uncommitted and can be reviewed with `git diff`

## Documentation verification with Context7

If a Context7 MCP server is available, use it aggressively when addressing findings. Verify APIs, config formats, and library behavior against current docs before fixing, addressing, or disagreeing with a finding. Cite the doc version when a finding hinges on doc verification.

## Rules

- Use the `invocation.review` prefix from `detect` for every peer call. Never shell out to `codex exec` or `claude -p` directly.
- Track and display iteration count.
- Enforce checkpointing every 3 iterations before any further edits or peer submissions.
- Never auto-commit - changes remain uncommitted for user to review.
- Only send unresolved findings and latest fixes to the peer - keep full history for the final report only.
- Run wrapper commands as one plain command line.
