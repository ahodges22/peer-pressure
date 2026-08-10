# Cursor Confinement Revision Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the Cursor reviewer functional for the approved account by removing the server-rejected workspace-context flag and accurately documenting the resulting repository trust boundary.

**Architecture:** Keep the existing Cursor backend, exact build pin, empty primary workspace, ask mode, CLI sandbox, disabled project CLI configuration, and absolute repository `--add-dir`. Remove only `--exclude-workspace-context`. Repository-context reviews remain available, but users must trust repository Cursor configuration because rule, skill, note, transcript, and MCP isolation is not proven.

**Tech Stack:** Node.js 20 standard library, Bash hermetic test suite, Cursor Agent CLI `2026.08.04-aaa8809`, Markdown documentation.

## Global Constraints

- Preserve the default Claude Code to Codex and Codex to Claude reviewer pairings.
- Preserve the four stable aliases and their current model IDs.
- Do not change detection, output parsing, timeout, cleanup, or retry behavior.
- Do not add a replacement confinement mechanism without a separate approved design.
- Use strict test-first development for the runtime change.
- Do not add README source-text assertions. Verify documentation by inspection and repository searches.
- Do not claim that repository Cursor configuration is isolated.
- Do not make a paid Cursor request without explicit user approval.
- Do not edit release-managed version fields.

---

### Task 1: Remove the unsupported Cursor argument

**Files:**

- Modify: `tests/run-tests.sh:699-708`
- Modify: `plugins/adversarial-review/scripts/lib/agents/cursor.mjs:142-155`

- [ ] **Step 1: Change the exact-argument test first**

In the `cursor backend` group, change the expected argument list to omit `--exclude-workspace-context`. Add an explicit negative assertion so the unsupported option cannot return unnoticed:

```js
assert.deepEqual(args, [
  "--print", "--output-format", "json", "--mode", "ask", "--sandbox", "enabled", "--trust",
  "--disable-project-configs", "--disable-auto-update",
  "--workspace", workspace, "--model", "composer-2.5"
]);
assert(!args.includes("--exclude-workspace-context"));
```

- [ ] **Step 2: Run the focused suite and confirm RED**

Run:

```bash
rtk tests/run-tests.sh
```

Expected: the `Cursor backend detection and run contracts` assertion fails because production still passes `--exclude-workspace-context`. Record the failing count and assertion in the task report.

- [ ] **Step 3: Remove only the unsupported production argument**

In `cursor.mjs`, change the argument sequence to:

```js
"--trust",
"--disable-project-configs",
"--disable-auto-update",
"--workspace", workspace,
```

Do not change argument order elsewhere.

- [ ] **Step 4: Run the suite and syntax checks for GREEN**

Run:

```bash
rtk tests/run-tests.sh
rtk node --check plugins/adversarial-review/scripts/lib/agents/cursor.mjs
rtk git diff --check
```

Expected: all hermetic tests pass, the module parses, and the diff has no whitespace errors.

- [ ] **Step 5: Review and commit Task 1**

Inspect the scoped diff and verify that it changes only the unsupported argument and its direct contract test:

```bash
rtk git diff -- plugins/adversarial-review/scripts/lib/agents/cursor.mjs tests/run-tests.sh
rtk git add plugins/adversarial-review/scripts/lib/agents/cursor.mjs tests/run-tests.sh
rtk git commit --no-gpg-sign -m "fix: remove unsupported Cursor context flag"
```

---

### Task 2: Document the weaker repository trust boundary

**Files:**

- Modify: `README.md:48-83`
- Modify: `plugins/adversarial-review/README.md:19-54`
- Modify: `docs/superpowers/plans/2026-08-09-cursor-reviewer.md:14-25`
- Modify: `docs/superpowers/plans/2026-08-09-cursor-reviewer.md:477-491`

- [ ] **Step 1: Correct both user-facing READMEs**

After the existing CLI-level confinement paragraph, add equivalent concise text to both READMEs:

```text
Payload-only Cursor work exposes only an empty temporary workspace.
Repository-context work also grants Cursor read access to the repository. Cursor
rules, skills, notes, transcripts, or MCP configuration in that repository can
influence the session, so use repository context only with repositories whose
Cursor configuration you trust.
```

Keep the existing statement that ask mode and Cursor's sandbox provide a CLI-level boundary, not an OS-enforced read-only boundary.

- [ ] **Step 2: Reconcile the original implementation plan with the approved design**

In `2026-08-09-cursor-reviewer.md`:

1. Remove `--exclude-workspace-context` from the global constraint and implementation snippets.
2. Replace isolation-smoke wording with a functional-smoke requirement.
3. State that the smoke proves stdin delivery and repository file access only.
4. State that repository Cursor rules, skills, notes, transcripts, and MCP isolation remain unverified.

Use this final verification wording:

```text
Ask the user for explicit approval before one paid real Cursor smoke invocation
with the `composer` alias and exact production flags. The smoke must prove that
Cursor receives the stdin sentinel and can read a known repository file through
the absolute `--add-dir`. It must not be used as evidence that repository Cursor
rules, skills, notes, transcripts, or MCP configuration are isolated.
```

- [ ] **Step 3: Check all confinement claims**

Run:

```bash
rtk rg -n "exclude-workspace-context|ignore the conflicting rule|MCP marker absent|rules.*isolat|MCP.*isolat" README.md plugins/adversarial-review/README.md docs/superpowers/plans/2026-08-09-cursor-reviewer.md
rtk git diff --check
```

Expected: no active plan or user documentation requires the removed option or claims successful repository-configuration isolation. Historical smoke-failure evidence in the approved design can still name the rejected option.

- [ ] **Step 4: Inspect and commit Task 2**

Run:

```bash
rtk git diff -- README.md plugins/adversarial-review/README.md docs/superpowers/plans/2026-08-09-cursor-reviewer.md
rtk git add README.md plugins/adversarial-review/README.md docs/superpowers/plans/2026-08-09-cursor-reviewer.md
rtk git commit --no-gpg-sign -m "docs: document Cursor repository trust boundary"
```

---

### Task 3: Verify the revised implementation

**Files:**

- Verify: `plugins/adversarial-review/scripts/lib/agents/cursor.mjs`
- Verify: `tests/run-tests.sh`
- Verify: `README.md`
- Verify: `plugins/adversarial-review/README.md`

- [ ] **Step 1: Run non-paid local verification**

Run:

```bash
rtk agent --version
rtk agent --list-models
rtk tests/run-tests.sh
rtk node --check plugins/adversarial-review/scripts/lib/agents/cursor.mjs
rtk git diff --check
rtk git status --short --branch
```

Expected:

- Cursor reports exactly `2026.08.04-aaa8809`.
- The model list contains `composer-2.5`, `cursor-grok-4.5-high`, `kimi-k3-max`, and `glm-5.2-max`.
- All hermetic tests pass.
- The backend parses and the working tree has no uncommitted task changes.

- [ ] **Step 2: Request approval for one replacement paid smoke**

Stop and ask the user before the request. If approved, create a fresh temporary Git repository with one known file and invoke the production backend with the `composer` alias, stdin sentinel, repository context, and exact production flags.

The smoke passes only if:

1. The process returns a successful JSON result.
2. The result repeats the stdin sentinel.
3. The result reports the exact contents of the known repository file.

Do not add rule or MCP decoys. Do not infer configuration isolation from this smoke. If it fails, use `superpowers:systematic-debugging` before changing code.

- [ ] **Step 3: Run adversarial code review**

Use `adversarial-review:code-review` on the complete branch diff. Resolve each merge-blocking finding with executable evidence and repeat until approved or the user stops at a review checkpoint.

- [ ] **Step 4: Run the final evidence gate**

After the paid smoke and adversarial review pass, run:

```bash
rtk tests/run-tests.sh
rtk node --check plugins/adversarial-review/scripts/lib/agents/cursor.mjs
rtk git diff --check
rtk git status --short --branch
```

Report exact test counts, the smoke result, review verdict, commit IDs, and any unverified boundary. Do not claim repository Cursor configuration isolation.
