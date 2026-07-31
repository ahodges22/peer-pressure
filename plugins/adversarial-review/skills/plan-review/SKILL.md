---
name: plan-review
description: Adversarial plan review loop driven by a peer agent CLI. Drafts a plan, submits it to the other agent CLI for critique, addresses findings, and iterates until approved. Use before high-stakes implementations.
---

# Adversarial Plan Review

Draft a plan, submit it to the **peer agent** for adversarial critique, address merge-blocking findings, repeat until the peer approves or the user stops at a checkpoint.

The peer is always the agent CLI that is **not** running this skill - Claude Code is reviewed by Codex, Codex is reviewed by Claude Code. That is the entire point: a reviewer that shares the author's model shares the author's blind spots. The runtime picks the peer for you; never override it.

`$ARGUMENTS` contains the task or feature to plan. If it is empty, ambiguous, or missing the concrete task to plan, stop and ask the user what feature/task to review before drafting anything.

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
| Generate unique context path | `{invocation.review} new-ctx --kind plan` |
| Plan review (iteration 1) | `{invocation.review} plan-review --context-file <path> --first` |
| Plan review (subsequent) | `{invocation.review} plan-review --context-file <path>` |

The ONLY flags `plan-review` accepts are: `--context-file PATH`, `--first`, `--model NAME`. Anything else will cause an immediate error.

## Step 0 - Pre-flight check (mandatory hard gate)

This is the **only** step where the command spelling depends on the host, because it is what tells you the spelling for everything else. Pick the line that matches the CLI you are running in:

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

**Permission heads-up (Claude Code host only):** the `permissions` field is present only when `host` is `claude-code`. If it is present and `permissions.tmp_write_preapproved` is `false`, tell the user once (plain text is fine here, this is not a decision prompt):

> Heads up: this skill writes its review context file under your system temp directory (`{permissions.tmpdir}/plan-ctx-<slug>.txt`) each iteration, so you'll see a file-write permission prompt. It's scratch space for the review - safe to approve. To pre-approve it for future runs, add `{permissions.expected_rule}` to `permissions.allow` in `~/.claude/settings.json`. Two things matter about that rule: it must use `Edit(...)`, because Claude Code checks file permissions against `Edit` and `Read` rules only and silently ignores `Write(...)` path rules; and the leading `//` is required, since a single `/` anchors to the project root rather than the filesystem root.

Substitute the literal `{permissions.tmpdir}` and `{permissions.expected_rule}` values from the `detect` response. If `permissions.legacy_write_rules` is present, the user has an obsolete `Write(...)` rule that Claude Code never consults - tell them to replace it with `permissions.expected_rule`.

Skip this message when `tmp_write_preapproved` is `true` or the `permissions` field is absent.

## Step 1 - Draft the plan (or load an existing draft)

Branch on the shape of `$ARGUMENTS`:

- **If `$ARGUMENTS` is a path to a readable `.md` file** (typical: `~/.claude/plans/<slug>.md` produced by plan mode, or a user-supplied plan file), **read it and use its contents verbatim as the initial draft.** Do not re-draft from scratch. Tell the user: "Using draft plan from `<path>`."
- **Otherwise**, analyze `$ARGUMENTS` as a task description and draft the simplest plan that credibly satisfies the requirements, covering:

  - Objective and scope
  - Files to create/modify (with rationale)
  - Implementation approach and key design decisions
  - Edge cases, risks, and mitigations
  - Testing strategy

Do not add abstractions, scaffolding, or process steps that do not resolve a concrete risk.

### Scope / Out of scope (mandatory before first peer submission)

Before sending to the peer, the plan MUST contain an explicit `## Scope / Out of scope` subsection near the top. This anchors the review - the peer has been told to reject findings that propose work beyond the stated scope, and you need an explicit scope for that rule to bite.

- **Draft-from-task path:** include this subsection when drafting the plan. Two bullet lists: in-scope (what this plan will change) and out-of-scope (adjacent concerns the plan deliberately does not address - e.g., "auth hardening", "general observability improvements", "migration to framework X"). Be specific: "out of scope: everything else" is not useful.
- **Loaded-draft path:** if the loaded plan already has a Scope / Out of scope subsection, keep it verbatim. If it doesn't, add one by inferring the narrowest reasonable scope from the plan's objective and file list, then show the inferred scope to the user with: "I inferred this scope from the draft - confirm or correct before review." Only proceed after the user confirms or corrects.

The scope subsection must be part of the PLAN content sent to the peer in every iteration. Do not strip it from later iterations.

## Step 2 - Initialize

Initialize: `iteration = 0`, `finding_ledger = []`.

## Step 3 - Submit to the peer

Increment iteration. Display: `[Plan Review: iteration N]`.

On the first iteration, generate a unique context path and reuse it for every subsequent iteration of this review. The runtime gives you one on request:

```bash
{invocation.review} new-ctx --kind plan
```

This emits `{ ok, path, slug }`. Remember `path` for the remainder of the review; don't regenerate it per iteration (that would lose iteration-to-iteration continuity). Using a fresh path per review avoids collisions when the user has multiple reviews running concurrently.

Use the Write tool **once** per iteration to (re)create that context bundle with this exact format:

```
===== PLAN START =====
<full plan text>
===== PLAN END =====
===== UNRESOLVED FINDINGS START =====
<open findings from ledger - leave empty on first iteration>
===== UNRESOLVED FINDINGS END =====
===== LATEST FIXES START =====
<what changed this iteration - leave empty on first iteration>
===== LATEST FIXES END =====
```

**First iteration:**
```bash
{invocation.review} plan-review --context-file {path-from-new-ctx} --first
```

**Subsequent iterations:**
```bash
{invocation.review} plan-review --context-file {path-from-new-ctx}
```

Per iteration this is exactly **one Write + one Bash call**. Run with a 600s timeout (the runtime itself times out at 600s - the Bash tool invocation should match). Run it as one plain command line, with no shell variables, environment assignments, or backslash continuations.

The response is JSON:

```json
{ "ok": true, "status": "APPROVED" | "CHANGES_REQUIRED", "output": "<full reviewer text>" }
```

Parse the `status` field directly. Do not re-parse the `output` string for the status.

If `ok: false`, the JSON contains an `error` field (`peer_unavailable`, `peer_too_old`, `peer_failed`, `missing_status_line`, `payload_too_large`, `invalid_usage`). A human-readable reason accompanies it in `detail` where one applies. `invalid_usage` means the command line was malformed: re-read the allowed invocations above, do not improvise a flag.
**Single retry for transient provider failures only:** if the failed review JSON also contains:

```json
{ "retryable": true, "retryReason": "...", "retryInstruction": "rerun_same_command_once" }
```

rerun the exact same `{invocation.review} plan-review ...` command once: same flags, same context file, no edits, no regenerated context file, and no prompt to the user before the retry. If the retry returns `ok: true`, process that response normally. If it fails again, report both failures and ask the user how to proceed.

Never retry a response without `retryable: true`. Every other failure is a real condition that a second identical run would only repeat.

For all other failures, report the failure and ask the user how to proceed.


## Step 4 - Process feedback

Extract findings from `output` and update the ledger:
- New findings get a stable ID (`F1-1`, `F1-2` for iteration 1).
- Findings matching a previously addressed issue are marked as regressions.
- Duplicate/rephrased findings referencing the same root cause are merged.
- Each finding has status: `open`, `addressed`, `deferred`, `disagreed-with-rationale`.

Show the user a concise summary of this iteration's findings.

Treat the Bash step as complete as soon as the JSON returns a `status` field. Do not start a new broad repo analysis pass.

Address findings by editing the plan directly from the returned feedback. Only gather additional repo or task context if a specific finding cannot be resolved from the existing plan/task details.

### Triage - classify before deciding

For each finding, classify it FIRST into one of two categories, then decide:

- **(a) In-scope**: the finding identifies a concrete failure mode of a change the plan already proposes - bug, regression, broken outcome, incomplete work, internal contradiction. Default: `open`, address in next iteration.
- **(b) Out-of-scope**: the finding proposes work beyond the plan's stated scope - "also add X", "also harden Y", "also monitor Z". Covers general security hardening, defense-in-depth, observability improvements, resilience additions, or refactors that don't fix an in-scope failure. Default: `disagreed-with-rationale`. Rationale is one line: "Beyond plan scope: <scope summary>." **Do not flip to `addressed` unless the finding demonstrates a concrete in-scope failure - "this would be nice to have" or "this is best practice" is not sufficient.**

Only after classification, apply the merge-blocking bar to the remaining (a) findings:
- Only iterate on issues that would independently justify blocking a merge.
- Prefer the simplest plan change that closes the real risk; reject extra abstraction or process unless it is necessary to close a concrete failure mode.
- If only nitpicks remain, recommend stopping at the next checkpoint.

### Early checkpoint on scope creep

If more than 50% of this iteration's findings are classified (b), STOP and checkpoint immediately regardless of iteration number - skip to Step 5. The peer is expanding scope beyond the plan; continuing will compound. Recommend "Stop here" unless the user sees an in-scope finding worth pursuing.

**If `status == "APPROVED"` and ALL ledger entries are `addressed`:** go to Step 6.

**If `status == "APPROVED"` but some findings are `deferred` or `disagreed-with-rationale`:** issue a user decision prompt with this content:
- `question`: "Review approved with caveats - {N} findings deferred or disagreed. How would you like to proceed?"
- `header`: "Caveats"
- Allow one selection.
- `options`:
  1. label: "Accept current state" / description: "Proceed to final summary with caveats noted"
  2. label: "Reopen selected" / description: "Choose specific findings to reopen for further iteration"

If "Accept current state": go to Step 6. If "Reopen selected": ask "Which finding IDs should I reopen?" Mark only those `open` and return to Step 3.

**If `status == "CHANGES_REQUIRED"`:** address every open finding. Update the ledger. Record fixes. Show the user what changed.

**Checkpoint gate (mandatory):** After addressing findings, check whether `iteration % 3 == 0`. If true and merge-blocking findings remain, STOP - go to Step 5. Do not return to Step 3 until the user responds at the checkpoint.

If no checkpoint is due, return to Step 3.

### Optional delegation

Use sub-agents only when a specific finding requires targeted repo research. Keep the plan draft, ledger, checkpointing, and every peer submission in the main agent.

## Step 5 - Checkpoint every 3 iterations

Checkpointing is mandatory. Immediately after iterations 3, 6, 9, etc., if the review is not fully approved, stop before making more edits or launching another peer run.

Present:
- What has been fixed so far (full ledger of addressed findings)
- What the peer is still unhappy about (remaining open findings)
- A clear recommendation (default: stop unless at least one remaining finding clearly clears the merge-blocking bar)

Then issue a user decision prompt with this content:
- `question`: "Checkpoint at iteration {N}. Recommended: {recommended_option} - {short reason}. How would you like to proceed?"
- `header`: "Checkpoint"
- Allow one selection.
- `options` (put the recommended option first and append "(Recommended)" to its label):
  1. label: "Continue iterating" / description: "Continue iterating on all remaining findings"
  2. label: "Focus on selected" / description: "Choose specific findings to keep open and defer the rest"
  3. label: "Stop here" / description: "Accept the current state and produce the final summary"

If "Focus on selected": ask "Which finding IDs should stay open? I'll defer the rest."

There is no hard iteration cap. The loop continues until the peer approves or the user stops.

If you judge that the peer is nitpicking, say so clearly at the checkpoint and recommend stopping.

## Step 6 - Final summary

**CRITICAL: Do NOT use plan mode tools (EnterPlanMode, ExitPlanMode, `/plan`) in this step.** This rule governs the skill's own output - it does not prevent the skill from being *triggered* by a plan-mode exit via `$ARGUMENTS`. Output everything as plain markdown text directly in the conversation.

First, output the **complete final plan** as markdown in the conversation. Print every line of the plan - do not summarize, truncate, or say "see the file".

Then present a cumulative report:
- Result: approved / approved with caveats / stopped at checkpoint
- Short review timeline by iteration
- Full finding ledger with statuses and resolutions
- Statistics: iterations, findings raised, addressed, deferred, disagreed
- If the peer approved and `finding_ledger` is empty, say so explicitly: "No adversarial findings. The critic inspected <review target>." Name the actual target - the loaded plan path, or the task the plan was drafted from. A clean review and a review that never reached the peer look identical otherwise, and the user cannot tell which they got.

After presenting the report, pick a short descriptive slug from the task (for example, `add-foo-command` or `fix-auth-bug`). Use the Write tool to save the final plan to `/tmp/adversarial-plan-{slug}.md`, and report that path. End the skill after the review result. Do not implement the plan.

## Documentation verification with Context7

If a Context7 MCP server is available, use it aggressively when drafting and revising the plan. Verify APIs, config formats, and library behavior against current docs before adding, addressing, or disagreeing with a finding. Cite the doc version when a finding hinges on doc verification.

## Rules

- Use the `invocation.review` prefix from `detect` for every peer call. Never shell out to `codex exec` or `claude -p` directly.
- Track and display iteration count.
- Enforce checkpointing every 3 iterations before any further edits or peer submissions.
- Disposition ALL findings - every finding must be explicitly `addressed`, `deferred`, or `disagreed-with-rationale`.
- Never use plan mode tools (EnterPlanMode, ExitPlanMode, `/plan`) inside this skill - output the plan as plain markdown in the conversation. (This rule applies to the skill's own output. It does not block the skill from being invoked after a plan-mode exit via `$ARGUMENTS` pointing at a plan file.)
- If invoked with a plan file path, preserve the user-approved structure - only modify sections the peer flags as merge-blocking.
- Never write plan to project files (only to `/tmp/adversarial-plan-{slug}.md` and `/tmp/adversarial-plan-ctx-{slug}.txt`).
- Never auto-commit.
- Only send unresolved findings and latest fixes to the peer - keep full history for the final report only.
- Run wrapper commands as one plain command line. Do not use `PLUGIN_ROOT=...`, `PATHS=...`, backslash-continued lines, or shell scaffolding.
