# Cursor Reviewer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Cursor Agent CLI as an explicit optional reviewer with the stable aliases `composer`, `grok`, `kimi`, and `glm`, while preserving the existing default Claude Code and Codex pairing.

**Architecture:** Add a Cursor backend behind the existing agent interface, extend the global CLI selector with the single allowed override `--peer cursor`, and keep alias resolution inside the Cursor backend. Cursor receives prompts through stdin, runs in ask mode from a fresh empty temporary workspace, and gains repository access only through an explicit `--add-dir` root.

**Tech Stack:** Node.js 20 standard library, Bash hermetic test suite, Cursor Agent CLI `2026.08.04-aaa8809`.

## Global Constraints

- No `--peer` flag preserves Claude Code to Codex and Codex to Claude Code.
- The only accepted explicit peer is `cursor`. Cursor never becomes a host or default reviewer.
- `composer` maps to `composer-2.5`.
- `grok` maps to `cursor-grok-4.5-high`.
- `kimi` maps to `kimi-k3-max`.
- `glm` maps to `glm-5.2-max`.
- Support only Cursor CLI `2026.08.04-aaa8809` until the real functional smoke test is repeated.
- Cursor runs with `--print --output-format json --mode ask --sandbox enabled --trust --disable-project-configs --disable-auto-update`.
- Cursor payloads use stdin and retain the shared `2_000_000` byte payload cap.
- Cursor uses a fresh empty temporary primary workspace for every invocation and removes it after every returned result.
- Repository context adds only the absolute repository root with `--add-dir` and prepends the same root to stdin.
- Cursor timeouts use `600_000` milliseconds, kill the direct child with `SIGKILL`, and are terminal and non-retryable.
- Cursor output uses a 32 MiB buffer and accepts only one JSON object with a non-empty string `result`.
- Do not change release versions or refactor unrelated code.
- Use `rtk` for every shell command. Use `apply_patch` for source edits.
- Follow TDD for runtime behavior. Record the failing and passing commands and outputs.

---

### Task 1: Cursor backend and hermetic agent fixture

**Files:**

- Create: `plugins/adversarial-review/scripts/lib/agents/cursor.mjs`
- Create: `tests/bin/agent`
- Modify: `plugins/adversarial-review/scripts/lib/agents/index.mjs`
- Modify: `tests/run-tests.sh`

**Interfaces:**

- Produces `SUPPORTED_CURSOR_VERSION = "2026.08.04-aaa8809"`.
- Produces `CURSOR_MODELS`, a frozen alias-to-ID table with `composer`, `grok`, `kimi`, and `glm`.
- Produces a Cursor `agent` object with `id`, `displayName`, `command`, `minVersion`, `detect()`, `confinement()`, and `run()`.
- Extends `getAgent("cursor")` without changing `peerFor(host)` behavior.
- `run({ prompt, payload, cwd, model, timeoutMs })` treats `model` as the public alias and returns the existing backend result fields plus narrowly scoped Cursor diagnostics.

- [ ] **Step 1: Add failing backend and fixture tests**

Add one `cursor backend` group to `tests/run-tests.sh`. Before the group runs, require both checks below. The sentinel prevents a PATH regression from reaching a paid CLI.

```bash
export PEER_PRESSURE_TEST_AGENT=peer-pressure-test-agent
expected_agent="$TESTS_DIR/bin/agent"
[ "$(command -v agent)" = "$expected_agent" ] || exit 1
[ "$(agent --fixture-id)" = "peer-pressure-test-agent" ] || exit 1
```

The group must directly import `cursor.mjs` and exercise these observable behaviors through the fake `agent` executable:

```text
exact version accepted: 2026.08.04-aaa8809
older date rejected: unsupported_build
newer date rejected: unsupported_build
wrong suffix rejected: unsupported_build
absent suffix rejected: unsupported_build
unparseable output rejected: unsupported_version_format
missing executable rejected: not_installed
nonzero version command rejected: authentication_failed
help containing --model but not --mode reports --mode missing
all required public flags are token-matched
composer -> composer-2.5
grok -> cursor-grok-4.5-high
kimi -> kimi-k3-max
glm -> glm-5.2-max
```

Add run-contract assertions for:

```text
stdin equals prompt plus payload byte-for-byte for a 300,000-byte payload
no positional prompt or request file exists
all production flags are present
payload-only runs have no --add-dir
repository runs pass the absolute root through --add-dir and stdin
each run uses a distinct workspace under os.tmpdir()
workspace removal follows success, nonzero failure, timeout return, and JSON failure
JSON result extraction
is_error:true changes effective rc to failure
non-JSON, prefixed JSON, missing result, and empty result fail closed
nonzero exit takes precedence over malformed stdout and remains peer_failed input
ENOBUFS is marked as a terminal output-size failure
model rejection includes alias, mapped ID, and agent --list-models
cleanup exceptions become a non-fatal diagnostic
```

The fake executable must require `PEER_PRESSURE_TEST_AGENT=peer-pressure-test-agent` for review invocations, log the marker, support `--version`, `--help`, `--fixture-id`, and accept these test controls:

```text
FAKE_AGENT_VERSION
FAKE_AGENT_VERSION_RC
FAKE_AGENT_HELP_OMIT
FAKE_AGENT_ARGLOG
FAKE_AGENT_INPUTLOG
FAKE_AGENT_WORKSPACE_LOG
FAKE_AGENT_STATUS
FAKE_AGENT_RC
FAKE_AGENT_IS_ERROR
FAKE_AGENT_API_ERROR_STATUS
FAKE_AGENT_OUTPUT_MODE=json|non-json|prefixed-json|missing-result|empty-result
FAKE_AGENT_WRITE_WORKSPACE
FAKE_AGENT_MODEL_REJECT
```

- [ ] **Step 2: Run the suite and verify RED**

Run:

```bash
rtk tests/run-tests.sh
```

Expected: the existing 94 tests pass and the new Cursor group fails because `cursor.mjs` and `tests/bin/agent` do not exist.

- [ ] **Step 3: Implement the fake Cursor executable**

Create `tests/bin/agent` as an executable Bash fixture. Its default successful envelope is:

```json
{"type":"result","subtype":"success","is_error":false,"result":"STATUS: APPROVED\n\nfake-cursor reply body.","session_id":"stub"}
```

It must parse `--workspace` and `--model`, log stdin without changing it, optionally write one file under the workspace, and never make a network request.

- [ ] **Step 4: Implement strict Cursor detection**

In `cursor.mjs`, define these exact public flags and aliases:

```js
export const SUPPORTED_CURSOR_VERSION = "2026.08.04-aaa8809";

export const CURSOR_MODELS = Object.freeze({
  composer: "composer-2.5",
  grok: "cursor-grok-4.5-high",
  kimi: "kimi-k3-max",
  glm: "glm-5.2-max"
});

const REQUIRED_FLAGS = [
  "--print", "--output-format", "--mode", "--sandbox",
  "--trust", "--workspace", "--add-dir", "--model"
];
```

Parse only the first version line with:

```js
/^(\d{4})\.(\d{2})\.(\d{2})(?:-([0-9A-Za-z.-]+))?$/
```

Require the complete version string to equal `SUPPORTED_CURSOR_VERSION`. A valid mismatch returns `unsupported_build`; an unmatched value returns `unsupported_version_format`. Both include `version`, `supportedVersion`, and only this version remediation:

```text
agent install 2026.08.04-aaa8809
```

A spawn error returns `not_installed`. A nonzero version command returns `authentication_failed` and may suggest `agent login`. Match help flags only when followed by whitespace, `=`, `,`, or end of text.

- [ ] **Step 5: Implement the Cursor run contract**

Build arguments in this order:

```js
[
  "--print",
  "--output-format", "json",
  "--mode", "ask",
  "--sandbox", "enabled",
  "--trust",
  "--disable-project-configs",
  "--disable-auto-update",
  "--workspace", workspace,
  ...(cwd ? ["--add-dir", path.resolve(cwd)] : []),
  "--model", CURSOR_MODELS[model]
]
```

Create `workspace` with `fs.mkdtempSync(path.join(os.tmpdir(), "cursor-review-"))`. Pass no positional prompt. Send one stdin string:

```js
const input = cwd
  ? `Repository root: ${path.resolve(cwd)}\nResolve every relative payload path against this root.\n\n${prompt}\n\n${payload}`
  : `${prompt}\n\n${payload}`;
```

Use `encoding: "utf8"`, `timeout: timeoutMs`, `killSignal: "SIGKILL"`, and `maxBuffer: 32 * 1024 * 1024`. Validate `payload` with `assertPayloadSize` before workspace creation.

For exit status zero, require stdout to parse as one JSON object with a non-empty string `result`. Treat `is_error: true` as failure and preserve `api_error_status`. For nonzero status, preserve the process failure even when stdout is malformed. Classify `ETIMEDOUT`, signals, `ENOBUFS`, and mapped-model rejection explicitly for orchestration. Always attempt recursive cleanup in `finally`; cleanup failure adds a diagnostic and does not replace the process result.

- [ ] **Step 6: Register Cursor and verify GREEN**

Add Cursor to `AGENTS` in `index.mjs`. Keep `peerFor(host)` unchanged when called without an override.

Run:

```bash
rtk tests/run-tests.sh
```

Expected: all tests, including the Cursor backend group, pass with no warnings.

- [ ] **Step 7: Commit Task 1**

```bash
rtk git add plugins/adversarial-review/scripts/lib/agents/cursor.mjs plugins/adversarial-review/scripts/lib/agents/index.mjs tests/bin/agent tests/run-tests.sh
rtk git commit --no-gpg-sign -m "feat: add Cursor reviewer backend"
```

---

### Task 2: Explicit Cursor selection across runtime commands

**Files:**

- Modify: `plugins/adversarial-review/scripts/orchestration.mjs`
- Modify: `plugins/adversarial-review/scripts/lib/agents/index.mjs`
- Modify: `tests/run-tests.sh`

**Interfaces:**

- Extends global arguments with `--peer cursor`.
- Keeps `--host` precedence and behavior unchanged.
- `peerFor(host, override)` returns Cursor only for `override === "cursor"`; any other explicit value is invalid usage.
- `detect --peer cursor` does not require a model.
- `consult`, `plan-review`, and `code-review` require a valid Cursor alias when `--peer cursor` is present.
- Default Claude and Codex model strings remain pass-through values.

- [ ] **Step 1: Add failing runtime integration tests**

Add a `Cursor peer override` group to `tests/run-tests.sh`. Cover these commands:

```bash
cli detect --peer cursor
cli consult --peer cursor --model composer --context-file "$QUESTION_CTX"
cli plan-review --peer cursor --model grok --context-file "$PLAN_CTX" --first
cli code-review --peer cursor --model kimi --mode uncommitted --first
cli code-review --peer cursor --model glm --mode uncommitted --repo-context --first
```

Assert these behaviors:

```text
detect reports host, peer cursor, exact version, and Cursor confinement
default Claude Code host still selects Codex
default Codex host still selects Claude
explicit cursor failures never invoke codex or claude
missing alias returns invalid_usage and lists composer,grok,kimi,glm
unknown alias returns invalid_usage and lists composer,grok,kimi,glm
unknown explicit peer returns invalid_usage
all four aliases reach the correct Cursor model ID
the selected peer and alias survive a second identical command after a transient first result
the retry uses the same stdin and a fresh temporary workspace
timeout errors are terminal and contain no retryable field
ENOBUFS returns peer_output_too_large and contains no retryable field
model rejection returns cursor_model_unavailable with alias, mapped ID, and agent --list-models
repository context uses an absolute root in --add-dir and stdin
payload-only commands expose no repository root
```

For every Cursor detection failure, set Codex and Claude argument logs and assert both remain empty. Cover missing CLI, authentication failure, unsupported build, unsupported version format, and a missing required flag.

- [ ] **Step 2: Run the suite and verify RED**

Run:

```bash
rtk tests/run-tests.sh
```

Expected: the Cursor override group fails because the runtime rejects `--peer` or still selects the host-derived peer.

- [ ] **Step 3: Extend global flag extraction**

Replace the host-only extraction result with this shape while preserving flag precedence:

```js
{ host, peer, argv }
```

Accept `--peer cursor` and `--peer=cursor` anywhere in the command line. Reject a missing peer value and every value other than `cursor` with the existing `invalid_usage` JSON contract.

Update help text to show:

```text
Global: --host <claude-code|codex> overrides host auto-detection.
Global: --peer cursor selects Cursor as the reviewer and requires --model composer|grok|kimi|glm for consultation and review commands.
Without --peer, Claude Code uses Codex and Codex uses Claude Code.
```

- [ ] **Step 4: Route detection and execution through the override**

Extend the registry with:

```js
export function peerFor(host, override) {
  if (override === undefined) return getAgent(peerIdFor(host));
  if (override === "cursor") return getAgent("cursor");
  throw new Error(`unknown peer '${override}'`);
}
```

Pass the parsed override into `cmdDetect`, `requirePeer`, `runPeer`, `runReview`, and all three command handlers. Once Cursor is explicit, never call host-derived `peerFor(host)` as a fallback.

When Cursor is selected for a model request, validate the public alias before invoking the backend:

```js
const accepted = Object.keys(CURSOR_MODELS);
if (!model || !Object.hasOwn(CURSOR_MODELS, model)) {
  die(`--model ${accepted.join("|")} is required with --peer cursor`);
}
```

Do not apply this alias validation to the default Codex or Claude backends.

- [ ] **Step 5: Preserve Cursor-specific failure contracts**

Map Cursor detection reasons without falling back:

```text
not_installed -> peer_unavailable
authentication_failed -> authentication_failed
unsupported_build -> unsupported_build
unsupported_version_format -> unsupported_version_format
```

Return `missingFlags`, `version`, `supportedVersion`, and `setupHints` when present. For Cursor run failures:

```text
timeout -> peer_failed, timedOut true, non-retryable
ENOBUFS -> peer_output_too_large, non-retryable
mapped model rejection -> cursor_model_unavailable, non-retryable
strict JSON contract failure -> peer_failed, non-retryable
is_error true with a narrow transient status or signature -> existing one-retry metadata
ordinary nonzero exit -> existing peer_failed shape
```

Include non-fatal cleanup diagnostics in both successful and failed JSON when the backend reports them.

- [ ] **Step 6: Verify GREEN**

Run:

```bash
rtk tests/run-tests.sh
```

Expected: the full suite passes, defaults remain unchanged, and all Cursor override tests use only `tests/bin/agent`.

- [ ] **Step 7: Commit Task 2**

```bash
rtk git add plugins/adversarial-review/scripts/orchestration.mjs plugins/adversarial-review/scripts/lib/agents/index.mjs tests/run-tests.sh
rtk git commit --no-gpg-sign -m "feat: select Cursor reviewer explicitly"
```

---

### Task 3: Skills, documentation, and final design record

**Files:**

- Modify: `plugins/adversarial-review/skills/consult-peer/SKILL.md`
- Modify: `plugins/adversarial-review/skills/plan-review/SKILL.md`
- Modify: `plugins/adversarial-review/skills/code-review/SKILL.md`
- Modify: `README.md`
- Modify: `plugins/adversarial-review/README.md`
- Modify: `docs/superpowers/specs/2026-08-09-cursor-reviewer-design.md`
- Modify: `tests/run-tests.sh`

**Interfaces:**

- Each skill accepts an explicit user request for one Cursor alias.
- Every Cursor workflow runs detection with `--peer cursor` and preserves both `--peer cursor` and `--model <alias>` on the initial command and an identical retry.
- Default skill behavior still forbids manual peer selection and uses the opposite host CLI.
- Human README prose is updated without adding source-text-only README assertions.

- [ ] **Step 1: Add failing executable-skill contract checks**

Extend the existing skill contract groups in `tests/run-tests.sh`. For each skill, extract its allowed commands and assert that the Cursor branch contains:

```text
detect --peer cursor
consult|plan-review|code-review --peer cursor --model <alias>
composer|grok|kimi|glm validation
same --peer and --model values on rerun_same_command_once
no fallback after explicit Cursor detection or execution failure
```

Do not add tests that assert README wording. README files are human documentation.

- [ ] **Step 2: Run the suite and verify RED**

Run:

```bash
rtk tests/run-tests.sh
```

Expected: only the new Cursor skill-contract checks fail.

- [ ] **Step 3: Update the three skill contracts**

In each skill, keep the default host-to-peer language. Add one explicit branch:

```text
When the user explicitly requests Cursor with composer, grok, kimi, or glm:
1. Run {invocation.review} detect --peer cursor.
2. Preserve --peer cursor and --model <selected-alias> on every consultation or review command.
3. Preserve both values on the one allowed identical retry.
4. Stop on every explicit-Cursor failure. Never fall back to Codex or Claude.
```

Update the exhaustive allowed-invocation tables and flag lists. Do not allow arbitrary Cursor model IDs. Do not change the default workflow for users who did not request Cursor.

- [ ] **Step 4: Update both READMEs**

Document Cursor as optional, not a host and not a default. Include this mapping table:

```text
composer -> composer-2.5
grok -> cursor-grok-4.5-high
kimi -> kimi-k3-max
glm -> glm-5.2-max
```

Add installation and authentication commands from Cursor documentation. State:

```text
Supported build: 2026.08.04-aaa8809
Restore: agent install 2026.08.04-aaa8809
Model diagnostics: agent --list-models
Each round starts one Cursor CLI invocation, but a tool-using turn can make multiple provider calls.
Ask mode and Cursor's sandbox enforce read-only behavior at the CLI level, not an OS read-only boundary.
The direct child timeout is 600 seconds. A descendant retaining an output pipe can keep spawnSync blocked and delay cleanup.
```

Do not recommend `agent update` for a build mismatch.

- [ ] **Step 5: Replace the stale design draft with the approved design**

Make `docs/superpowers/specs/2026-08-09-cursor-reviewer-design.md` match `/tmp/adversarial-plan-cursor-reviewer.md`, with the two user-approved corrections:

```text
Keep the 300,000-byte stdin integrity test without claiming it exceeds current macOS ARG_MAX.
Use focused skill contract checks and do not add README source-text assertions.
```

- [ ] **Step 6: Verify GREEN**

Run:

```bash
rtk tests/run-tests.sh
rtk git diff --check
```

Expected: all tests pass, no em dash exists in tracked text, and the diff has no whitespace errors.

- [ ] **Step 7: Commit Task 3**

```bash
rtk git add plugins/adversarial-review/skills README.md plugins/adversarial-review/README.md docs/superpowers/specs/2026-08-09-cursor-reviewer-design.md tests/run-tests.sh
rtk git commit --no-gpg-sign -m "docs: add Cursor reviewer workflow"
```

---

## Final Verification Gate

After all tasks and task reviews are complete:

1. Run `rtk agent --list-models` outside the hermetic suite and verify all four mapped IDs are present. This sends no model request.
2. Run the complete `rtk tests/run-tests.sh` suite.
3. Ask the user for explicit approval before one paid real Cursor smoke invocation with the `composer` alias and exact production flags. The smoke must prove that Cursor receives the stdin sentinel and can read a known repository file through the absolute `--add-dir`. It must not be used as evidence that repository Cursor rules, skills, notes, transcripts, or MCP configuration are isolated.
4. Run adversarial code review against the complete branch diff. Fix merge-blocking findings and repeat until approved or the user stops at a checkpoint.
