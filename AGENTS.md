# AGENTS.md

Guidance for agents (and humans) contributing to this plugin. The end-user
README covers install + usage; this file covers the dev loop and the
non-obvious things you'd otherwise re-discover the hard way.

## Dev loop

This repo IS the marketplace source for `peer-pressure`, for **both**
hosts. Local file changes do **not** reach the running plugin automatically -
each host loads from its own cache, populated by a marketplace fetch:

- Claude Code: `~/.claude/plugins/cache/peer-pressure/adversarial-review/<version>/`
- Codex: `~/.codex/plugins/cache/peer-pressure/adversarial-review/<version>/`

The full update path:

```
git push origin main                                   # or whatever branch the marketplace tracks
/plugin marketplace update peer-pressure    # in Claude Code
/reload-plugins
```

Codex depends on how the marketplace was added:

```bash
codex plugin marketplace upgrade                       # Git marketplaces only

# A marketplace added from a LOCAL PATH is skipped by `upgrade` ("No configured
# Git marketplaces to upgrade") and stays pinned at the cached version. Re-add
# the plugin to pick up a new one:
codex plugin remove adversarial-review@peer-pressure
codex plugin add adversarial-review@peer-pressure
```

If `plugin.json`'s `version` didn't bump, the cache may not refresh. Do **not**
bump it by hand: release-please owns every version field in this repo. See
[Releasing](#releasing).

For faster iteration without the round-trip, run the Node entry point
directly against your working copy:

```bash
node plugins/adversarial-review/scripts/orchestration.mjs <subcommand>
```

Only `plan-review` and `code-review` invoke the peer CLI and cost tokens.
`detect`, `inspect-repo`, and `new-ctx` are local-only. Note that `detect` still
spawns the peer (`--version`, and `--help` for the Claude flag probe), which is
local.

Running the runtime directly from a plain shell has no host marker, so it exits
with `unknown_host`. Pass `--host claude-code` or `--host codex` when iterating
by hand.

## The host/peer model

The single most important invariant: **the reviewer is the agent CLI that is not
the host.** Claude Code is reviewed by Codex; Codex is reviewed by Claude Code.
If that pairing ever collapses to "host reviews itself", the plugin still appears
to work while delivering a review that shares every one of the author's blind
spots - a silent failure with no visible symptom. Guard it accordingly.

`lib/host.mjs` resolves the host from env markers (`CLAUDECODE`,
`CODEX_THREAD_ID`), and `lib/agents/index.mjs` maps host → peer.

Detection fails closed in two cases, both deliberate:

- **`ambiguous_host`** - both markers present. Env vars are inherited, so running
  one CLI inside another sets both, and no marker is authoritative. This is not a
  hypothetical: it is exactly what happens when you test Codex from a Claude Code
  Bash tool.
- **`unknown_host`** - neither marker present, e.g. invoked from a plain shell.

Both are resolvable with `--host` or `ADVERSARIAL_REVIEW_HOST`; precedence is
flag > env override > markers.

### Adding or changing a peer backend

Backends live in `lib/agents/` and expose `id`, `displayName`, `command`,
`minVersion`, `detect()`, `run()`, and `confinement()`. Two things are easy
to get wrong:

- **Do not key failure on the exit code alone.** `claude --print` exits 0 even
  when the turn failed, with `is_error: true` and the error text in `result`
  (`subtype` still reads `"success"`). The Codex backend can trust `rc`; the
  Claude backend must parse the JSON envelope. A backend that gets this wrong
  reports an API outage as a completed review.
- **Transient failures are flagged, not retried in the runtime.** `classifyTransient`
  in `lib/agents/common.mjs` marks a failed REVIEW with `retryable: true`,
  `retryReason`, and `retryInstruction: "rerun_same_command_once"`; the SKILL does
  the single re-run. Keep the classifier narrow - telling a skill to retry a real
  failure burns a full round-trip and hides the true cause behind a duplicate
  error.
- **`confinement()` must describe what is actually enforced.** Codex reviews
  use an OS-enforced read-only sandbox. Claude Code payload-only reviews disable
  all tools. Repository-context reviews give Claude Code read-only tools, but no
  OS sandbox confines those reads.

## Architecture

```
plugins/adversarial-review/
├── bin/                    # thin bash shims that exec the Node entry
│   └── adversarial-review  # (Claude Code only: Codex does not put bin/ on PATH)
├── scripts/
│   ├── orchestration.mjs   # entry point: parses argv, dispatches cmdFoo
│   ├── lib/                # reusable helpers, split by concern
│   │   ├── agents/         # peer backends behind one detect()/run()/confinement() interface
│   │   │   ├── claude.mjs  # Claude Code peer (used when the host is Codex)
│   │   │   ├── codex.mjs   # Codex peer (used when the host is Claude Code)
│   │   │   ├── common.mjs  # version floor, payload cap, parseStatus
│   │   │   └── index.mjs   # registry: peerFor(host)
│   │   ├── bundle.mjs      # parseBundle (fenced context-file sections)
│   │   ├── host.mjs        # detectHost: env markers -> host -> peer
│   │   ├── permissions.mjs # Claude-Code-host tmpdir rule pre-approval check
│   │   ├── diff.mjs        # buildCodePayload, buildCodeSelfCollectPayload
│   │   ├── git.mjs         # repoRoot, hasHead, mergeBase, status helpers
│   │   ├── io.mjs          # writeAllSync (synchronous, non-truncating stdout)
│   │   ├── process.mjs     # runSync wrapper
│   │   └── secrets.mjs     # SECRET_RE, isSecretPath, findSecretFilesInWorkingTree
│   └── prompts/            # codex prompt templates with {{KEY}} substitution
│       ├── code-review.txt
│       └── plan-review.txt
├── hooks/                  # PostToolUse on ExitPlanMode → suggests plan-review
│   ├── hooks.json
│   └── post-exit-plan-mode
├── skills/                 # 2 SKILL.md files (one per review skill)
├── .claude-plugin/plugin.json   # Claude Code manifest
└── .codex-plugin/plugin.json    # Codex manifest (needs an explicit "skills" key)
```

Conventions:

- **Add features in the Node lib, not the bash shims.** The shims are
  permission-allowlist-stable forwarders; they should never grow logic.
- **Subcommands** live in `cmdFoo` functions in `orchestration.mjs`.
  Each parses its own `parseArgs` block, validates inputs, builds payload,
  calls `runReview` or domain-specific runner, and `emit`s a JSON result.
- **Prompt substitution** uses `{{KEY}}` placeholders. Empty substitutions
  are how optional blocks (e.g. `{{REPO_COLLECTION_RULES}}`) collapse cleanly.
- **Errors are JSON, not text.** All failure paths call `emit({ ok: false,
  error: "<stable_code>", ... }, exitCode)`. SKILLs parse `error` directly.
- **The plan-mode hook needs `jq`,** and it is the only component that does.
  Without `jq` it exits 0 with no output, so the user simply never gets the
  plan-review suggestion and nothing indicates why. That degradation is
  deliberate (a hook must not break the host) but it does mean a missing `jq`
  is invisible. The hook's `case` gate on `*/.claude/plans/*.md` is the only
  barrier between a spoofed transcript line and an arbitrary path reaching
  Claude's context; `tests/run-tests.sh` pins it with a readable decoy file
  outside the plans directory, because a decoy that does not exist passes on
  the later readability check no matter how broken the gate is.
- **Tests live in `tests/run-tests.sh`.** Run them before shipping:

  ```bash
  tests/run-tests.sh     # a few seconds, non-zero exit on failure
  ```

  They are hermetic: `tests/bin/codex` and `tests/bin/claude` shadow the real CLIs
  on `PATH`, so no test spends tokens, needs auth, or hits the network. Knobs on
  the stubs (`FAKE_CODEX_*`, `FAKE_CLAUDE_*` - version, status, rc, arglog, plus
  `FAKE_CLAUDE_IS_ERROR` and `FAKE_CLAUDE_HELP_OMIT`) drive version-floor, flag-probe
  and failure paths. CI runs this on ubuntu + macos.

  The suite pins `ADVERSARIAL_REVIEW_HOST=claude-code` and unsets both markers,
  because host detection is environment-driven: unpinned, the suite would behave
  one way under a developer's Claude Code session and fail wholesale in CI, where
  neither marker exists. The host-detection group overrides that per invocation.

  Two traps if you extend the suite:
  - **Do not add `pipefail`.** Most assertions exercise error paths where the
    runtime exits non-zero on purpose; under `pipefail`, `cli ... | grep -q` returns
    the runtime's status instead of grep's and every such test silently fails.
  - **Name any new stub after the real binary.** A stub called `fake-codex` never
    shadows anything, and the tests quietly call the real Codex CLI instead.

  The manual recipes below remain useful for one-off checks.

## Smoke recipes

Run from a scratch repo, not this one (the secret preflight will trip on
fixtures intentionally).

### Secret-exposure preflight

```bash
mkdir -p /tmp/scratch && cd /tmp/scratch && git init -q
echo ".env" > .gitignore && echo "SECRET=x" > .env
git add .gitignore && git commit -q -m init

# Should refuse:
node ~/Repos/peer-pressure/plugins/adversarial-review/scripts/orchestration.mjs \
  code-review --mode uncommitted --repo-context
# Expect: { ok: false, error: "secret_files_in_tree", files: [".env"], hint: ... }

# Should bypass:
node ... code-review --mode uncommitted --repo-context --include-secrets
# Expect: { ok: true, status: "APPROVED", ... }
```

### `--self-collect` validation

```bash
node ... code-review --mode uncommitted --self-collect
# Expect: ERROR: --self-collect requires --repo-context  (exit 1)
```

### Detect / inspect-repo (no Codex call)

```bash
node ... detect --host claude-code
# Expect: { ok: true, host: "claude-code", peer: "codex",
#           invocation: { review: "adversarial-review", ... }, permissions: { ... } }

node ... detect --host codex
# Expect: { ok: true, host: "codex", peer: "claude",
#           invocation: { review: "node /abs/.../orchestration.mjs", ... } }
#         (no `permissions` block: that check is Claude-Code-host only)

node ... inspect-repo
# Expect: { inWorkTree: true|false, hasDirty, ahead, defaultBranch, status, hasSubmodules }
```

## Releasing

Releases are automated by [release-please](https://github.com/googleapis/release-please)
(`.github/workflows/release.yml`). Nobody edits a version by hand.

### Commit messages are the release input

Every subject that lands on `main` must follow
[Conventional Commits](https://www.conventionalcommits.org/):

```
<type>[optional scope][!]: <description>
```

Allowed types: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`,
`refactor`, `revert`, `style`, `test`. `fix:` produces a patch bump, `feat:` a
minor bump, and a `!` suffix or a `BREAKING CHANGE:` footer produces a major
bump. Anything else contributes no bump at all.

That last point is the trap worth internalising. A non-conventional subject does
not fail at merge time, it just silently fails to trigger a release, so a fix
sits shipped-but-unreleased with nothing to indicate why. The
`commit-convention` job in `ci.yml` is what makes it fail loudly instead. It
checks the PR title **and** every individual commit, because all three merge
methods are enabled on this repo: squash uses the PR title, merge and rebase use
the commits.

### What a release does

1. Push to `main`. release-please opens or updates a release PR titled
   `chore(main): release <version>`.
2. That PR bumps the version everywhere and regenerates `CHANGELOG.md`.
3. Merge it. release-please tags `v<version>` and publishes a GitHub Release.

### The version lives in six places

`version.txt` is release-please's anchor. The other five are updated through
`extra-files` in `release-please-config.json`:

- `.release-please-manifest.json` (`.`)
- `.claude-plugin/marketplace.json` (`metadata.version` and `plugins[0].version`)
- `plugins/adversarial-review/.claude-plugin/plugin.json` (`version`)
- `plugins/adversarial-review/.codex-plugin/plugin.json` (`version`)

A jsonpath that stops matching would bump some files and not others, which is
exactly the silent skew each host's cache would then serve under one name. The
`manifests agree across hosts` job in `ci.yml` compares all six and fails the
release PR if they diverge, so that skew cannot reach `main`.

`.agents/plugins/marketplace.json` carries no version field and is therefore not
release-managed. If Codex ever starts reading one from there, add it to both the
`extra-files` list and the CI check together.

### Do not use `claude plugin tag`

It produces `adversarial-review--v<version>` tags, which is a different scheme
from the `v<version>` tags release-please creates. Two tag schemes on one repo
make "which tag is the release" unanswerable. release-please owns tagging.

### Dependencies

There is nothing to update but the GitHub Actions pins: no `package.json`, no
lockfile, no vendored code, and the runtime is Node standard library only.
`.github/dependabot.yml` therefore configures the `github-actions` ecosystem and
nothing else, grouped into one weekly PR with a `ci` prefix so the bot's own
subjects stay conventional.

## Gotcha: a global `lib/` gitignore

`scripts/lib/` is real source code. It collides with rules people commonly
carry in `~/.gitignore_global`. The Python setuptools template excludes a bare
`lib/`.

The failure mode looks like success:

- A `lib/` rule silently drops `scripts/lib/` from a commit. If
  `git ls-files plugins/adversarial-review/scripts/lib` is empty after a fresh
  clone, that is why - `git check-ignore -v <path>` names the offending file
  and line. Fix it at the source rather than adding negations here.

## Permissions worth knowing

The skills assume these are pre-approved (otherwise users see prompts):

- `Bash(adversarial-review *)`: the bash shim with all review subcommands
- `Edit(/<system-tmpdir>/**)` - covers the per-iteration context file. The
  exact rule depends on `os.tmpdir()`: Linux is `Edit(//tmp/**)`, macOS is
  `Edit(//var/folders/.../T/**)` (per-user).

Two silent-failure traps in that last rule:

- **`Edit(...)`, never `Write(...)`.** Since Claude Code 2.1.210, file permissions
  are checked against `Edit(path)` and `Read(path)` rules only; a `Write(path)`
  rule is accepted, never consulted, and warned about at startup. `Edit` covers all
  file-editing tools including Write. This plugin recommended the `Write` form
  until it was found to be inert - `permissions.legacy_write_rules` in `detect`
  flags a leftover so users can migrate.
- **The leading `//` is required.** A single `/` anchors at the settings source
  (project root), not the filesystem root.

`detect` returns `permissions.tmp_write_preapproved`, `permissions.tmpdir`,
`permissions.expected_rule`, and possibly `permissions.legacy_write_rules` - the
SKILLs use those to emit a one-time heads-up with the exact rule to add. The whole
`permissions` block is omitted when the host is Codex, which has no equivalent.
