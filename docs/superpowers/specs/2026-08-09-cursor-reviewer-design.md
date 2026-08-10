# Cursor Reviewer Design

## Goal

Add Cursor Agent CLI as an explicit reviewer override for consultation, plan
review, and code review. Preserve the current default reviewer pairings:
Claude Code uses Codex, and Codex uses Claude Code.

## Scope / Out of scope

In scope:

- Add optional `--peer cursor` selection to all review commands.
- Add the four stable model aliases and central mappings.
- Add the read-only Cursor backend, detection, JSON handling, and cleanup.
- Update the three skills, both READMEs, the fake CLI, and tests.
- Preserve existing default peer behavior.

Out of scope:

- Multi-model panels or arbitrary Cursor model IDs.
- Cursor as a host or default reviewer.
- Release-version changes.
- Unrelated refactoring.

Users select Cursor with a stable peer name and one stable model alias:

```text
--peer cursor --model composer
--peer cursor --model grok
--peer cursor --model kimi
--peer cursor --model glm
```

The implementation maps these aliases to the current high or maximum reasoning
models in one backend-owned table:

| Alias | Cursor model ID |
|---|---|
| `composer` | `composer-2.5` |
| `grok` | `cursor-grok-4.5-high` |
| `kimi` | `kimi-k3-max` |
| `glm` | `glm-5.2-max` |

This table is the only place that needs an edit when Cursor replaces a model.

## Command Contract

`--peer cursor` is a global override. It is valid with `detect`, `consult`,
`plan-review`, and `code-review`. No `--peer` flag keeps the current host-based
selection behavior. Other explicit peer values are invalid because they could
select the host's own CLI and break model independence.

`detect --peer cursor` checks the Cursor backend without a model. Review and
consultation commands require one of the four aliases when Cursor is selected.
An absent or unknown Cursor alias returns the existing `invalid_usage` JSON
error and lists the accepted aliases. Models passed to the default Codex and
Claude backends keep their current pass-through behavior.

The three skills accept an explicit user request for a Cursor alias. They add
`--peer cursor` to detection and preserve both `--peer cursor` and the selected
`--model` value on every request and retry in the workflow.

An explicit Cursor override never falls back to Codex or Claude. Missing CLI,
authentication failure, unsupported or unparseable version, missing capability,
model rejection, and invocation failure return their structured Cursor error and
abort that review round. Host-based peer selection is used only when `--peer`
was absent.

## Backend Structure

Add `scripts/lib/agents/cursor.mjs` with the same backend interface as the
Codex and Claude implementations. Register it in the agent registry. Reviewer
selection accepts the optional Cursor override before it falls back to the
host-to-peer map.

That fallback applies only when no override was supplied. Once `cursor` is
explicit, detection and execution stay on the Cursor backend or fail closed.

Cursor detection runs `agent --version` and probes `agent --help`
for every option used by the backend. The probe requires `--print`,
`--output-format`, `--mode`, `--sandbox`, `--trust`, `--workspace`, `--add-dir`,
and `--model`. Support only the full Cursor CLI version
`2026.08.04-aaa8809` because that is the installed build whose stdin,
configuration isolation, trust, and MCP paths were inspected and will be
smoke-tested. Any other version is untested, not assumed compatible.

Parse only the first version-output line with
`^(\d{4})\.(\d{2})\.(\d{2})(?:-([0-9A-Za-z.-]+))?$`. Compare the numeric
calendar fields for diagnostics, then require the complete string to equal
`SUPPORTED_CURSOR_VERSION`. Any other valid version fails with
`unsupported_build`; an unmatched string fails with
`unsupported_version_format`. The error reports both detected and supported
versions. Its only version-remediation command is
`agent install 2026.08.04-aaa8809`, whose version-install behavior was inspected
in the current CLI source. It never suggests `agent update` for a version
mismatch. Authentication failures can still suggest `agent login`.

The backend also passes the build-verified hidden options
`--disable-project-configs`, `--exclude-workspace-context`, and
`--disable-auto-update`. The first prevents
project `.cursor/cli.json` configuration from changing the invocation. The
second strips workspace rules, skills, transcripts, and notes from the session.
The third prevents a review invocation from updating itself past the supported
version. These hidden options are covered by exact-version matching and the
required real-CLI smoke check rather than the public-help probe.

The inspected CLI rejects unknown options with a nonzero exit before model
execution. Therefore removal or renaming of either hidden option produces a
loud `peer_failed` result even after detection. Exact release-date matching
prevents a future build with changed semantics from reaching execution until it
passes the decoy smoke and the supported date is updated.

The capability probe recognizes a flag only as a complete help token, followed
by whitespace, `=`, `,`, or end of text. It must not let `--model` satisfy
`--mode`, or let longer renamed options satisfy shorter required options. If the
probe fails, detection reports each missing flag by name so the user can
distinguish an incompatible build from authentication or installation failure.

The detect response identifies `cursor` as the peer and reports its confinement.
It does not call `--list-models`. Model catalogues depend on the authenticated
account, and the Cursor invocation reports an unavailable mapped model through
the normal peer-failure contract.

## Request and Confinement Flow

Cursor accepts its initial prompt from stdin when no positional prompt is
supplied and stdin is not a TTY. This was verified in the installed Cursor CLI
`2026.08.04` `build-prompt` implementation after Context7 and the official CLI
pages did not document input piping. The backend concatenates the complete
review prompt and payload and passes it through `spawnSync`'s `input` option.
This bypasses the operating system argument limit and does not depend on an
agentic file-read tool.

The invocation uses:

```text
agent --print --output-format json --mode ask --sandbox enabled \
  --trust --disable-project-configs --exclude-workspace-context --disable-auto-update \
  --workspace <temporary-workspace> --model <mapped-model-id>
```

Payload-only work exposes only an empty temporary workspace. Repository-context
work adds the repository with `--add-dir <repository-root>`. The temporary
workspace remains primary so repository-local Cursor configuration is not the
primary agent configuration. Each backend invocation, including an identical
retry, creates a fresh workspace. Cleanup runs in `finally` after synchronous
process execution returns. The review payload exists only in parent memory and
the stdin pipe, not in the workspace.

Cursor applies `--trust` to every workspace root, including `--add-dir`. The
backend therefore relies on all three controls together: ask mode is read-only,
workspace context is excluded, and project CLI configuration is disabled.
Inspection of Cursor CLI `2026.08.04` also shows project MCP discovery and
approval use the primary workspace, which is empty, rather than added roots.
The real-CLI isolation smoke check verifies that an added repository's rule and
MCP decoys have no effect before this support is declared ready.

For repository-context work, the backend prepends the absolute repository root
to stdin and instructs Cursor to resolve every relative payload path against
that root. The same absolute root is passed through `--add-dir`. Payload-only
work adds no root instruction and exposes no repository directory.

Create the primary workspace with `fs.mkdtempSync` under `os.tmpdir()`. Never
place it inside the repository. A unique directory per invocation prevents
concurrent reviews from colliding.

The timeout uses `SIGKILL` for the direct Cursor child. Node.js `spawnSync` can
still wait past the timeout if a descendant retains a stdout or stderr pipe, so
the timeout bounds the direct child but is not a hard wall-clock guarantee for
orphaned descendants. The design does not add asynchronous process-group
management because that would require an unrelated orchestration rewrite.

Pass the existing orchestration budget of `600_000` milliseconds to Cursor.
This ten-minute budget accommodates an ask-mode agent loop with repository read
tools and does not change the Codex or Claude budgets. A Cursor timeout is
terminal and non-retryable because an identical ten-minute paid retry is more
likely to repeat a hung tool loop than recover a short provider interruption.

`ask` mode makes the Cursor tools read-only. `--sandbox enabled` adds Cursor's
sandbox policy. This is CLI-enforced confinement, not a claimed OS-enforced
read-only boundary. The backend does not pass `--force`, `--yolo`,
`--approve-mcps`, or a write-capable mode.

## Output and Failure Handling

The backend requests one JSON result. Current Cursor CLI documentation defines
successful `--output-format json` output as one JSON object with a string
`result` field. The backend accepts only that shape. It uses the `result` field
as reviewer output. If stdout is not exactly one parseable JSON object, `result`
is absent or empty, or Cursor returns `is_error: true` with exit status zero,
the backend changes the effective status to failure. This matches the existing
protection for CLIs that report API failures inside a successful process
envelope and prevents notice text or schema drift from becoming a clean review.

Nonzero exits use the current `peer_failed` JSON shape. The shared transient
classifier decides whether one identical retry is allowed. Timeout, standard
output, standard error, parsed output, and any available API error status remain
available to the orchestration layer.

Set `maxBuffer` to 32 MiB, matching the existing peer backends. An `ENOBUFS`
result is reported as a non-retryable output-size failure, distinct from invalid
JSON, so an identical retry is not consumed.

Malformed or prefixed JSON and missing or empty `result` values are terminal,
non-retryable contract failures. `is_error: true` is retryable only when its API
status or text matches the existing narrow transient classifier. Other
`is_error: true` responses are terminal.

When Cursor rejects a mapped model, the error names the public alias, its mapped
Cursor ID, and `agent --list-models` as the diagnostic command. This keeps model
mapping drift distinct from a generic peer failure.

After every invocation that returns, cleanup calls
`fs.rmSync(workspace, { recursive: true, force: true })` inside its own
`try`/`catch`. Cursor may write session or metadata files there. Cleanup failure
is a non-fatal diagnostic and can never replace a successful result or a
structured peer error.
Cursor keeps the existing shared `2,000,000` byte payload cap. It is independent
of the operating system argument limit because delivery uses stdin. The Codex
and Claude caps do not change. Validation runs before the workspace is created.

## Documentation

Update the root README and plugin README to explain that Cursor is an optional
reviewer, not a third host and not a new default. Show all four aliases and the
current mapped models. Add Cursor installation and authentication instructions.
State that each command runs one selected model and starts one Cursor CLI
invocation per round. Cursor can make more than one provider call inside a
tool-using agent turn, so the documentation does not promise one model request.
Also state that the synchronous timeout can remain blocked if a Cursor
descendant keeps an output pipe open, especially for CI users.
In that descendant-pipe case, `finally` cannot run and the empty temporary
workspace remains until the process or operating system removes it.
Document `SUPPORTED_CURSOR_VERSION`, explain that Cursor self-update outside the
plugin disables this reviewer until compatibility is re-smoked, and give
`agent install 2026.08.04-aaa8809` as the restore command. Do not recommend
`agent update` for a version newer than the pin.

Update the consultation, plan-review, and code-review skill contracts so they
preserve an explicitly selected Cursor alias throughout a workflow.

## Verification

Add a hermetic `tests/bin/agent` fixture. It must support version, help,
argument and stdin logging, JSON success, JSON error, nonzero
exit, non-JSON output, prefixed JSON, missing or empty `result`, timeout
classification inputs, transient-first-attempt state, and missing-flag
simulation.

Before any Cursor test, abort the suite unless `command -v agent` resolves to
the exact `tests/bin/agent` path and `agent --fixture-id` returns the distinctive
`peer-pressure-test-agent` marker. The fixture also requires a suite-only
sentinel environment variable and records the same marker in its invocation
log. Detection and one successful review assertion verify the marker. This
makes a PATH regression fail before any paid command can run.

Start the behavior change with failing shell-suite assertions for:

- Cursor detection through the explicit peer override.
- Every explicit-Cursor detection failure aborts without a Codex or Claude
  invocation. Cover missing CLI, authentication failure, unsupported and
  unparseable versions, and a missing required flag.
- Unchanged default Codex and Claude peer selection.
- All four alias-to-model mappings.
- Missing and unknown Cursor aliases.
- Byte-for-byte stdin delivery of a 300,000-byte payload, below the unchanged
  2,000,000-byte shared cap, with no positional prompt or request file.
- Ask mode, sandboxing, empty temporary workspace isolation, and repository
  access only when repository context is requested.
- `--disable-project-configs`, `--exclude-workspace-context`, and
  `--disable-auto-update` on every Cursor invocation.
- An absolute repository root in both `--add-dir` and stdin for
  repository-context work, with no such root for payload-only work.
- JSON result extraction and `is_error: true` failure handling.
- Fail-closed behavior for non-JSON output, prefixed JSON, and missing or empty
  `result` values.
- Structured errors and transient retry metadata.
- A 600-second Cursor timeout argument and terminal, non-retryable timeout
  classification.
- Workspace removal after success, ordinary failure, timeout return, and retry
  exhaustion. The test names the documented descendant-pipe timeout limitation.
- A fake Cursor that writes a file under `--workspace` still preserves its
  success or failure result, and recursive cleanup leaves no workspace. A forced
  cleanup exception is non-fatal.
- A second identical runtime command after a transient first failure creates a
  fresh workspace, receives the same stdin payload, and can succeed.
- Token-aware flag detection where help contains `--model` but omits `--mode`.
- Calendar-version parsing for the exact full version, older date, newer date,
  wrong or absent suffix, and unparseable output. Every mismatch reports both
  versions, suggests the pinned `agent install` command, and never suggests
  `agent update`.
- A 32 MiB output buffer and non-retryable `ENOBUFS` reporting.
- Skill preservation of the selected peer and alias.
- Focused skill contract checks preserve the selected peer and alias. Do not add
  README source-text assertions.

Before the hermetic suite, compare the four mapped IDs with the authenticated
`agent --list-models` output. This read-only check sends no model request. The
automated suite must still use only the fake CLI.

At the final verification gate, obtain explicit user approval for one paid real
Cursor smoke invocation with the exact production flags and `composer` mapping.
It uses a
temporary added repository containing a known file, a conflicting Cursor rule,
and an MCP decoy whose harmless command would create a marker in that temporary
directory. The response must contain both the stdin sentinel and known-file
sentinel, must not follow the conflicting rule, and must not create the MCP
marker. Record the tested version in `SUPPORTED_CURSOR_VERSION`. The feature
is not ready to ship until this smoke passes. If approval is not given, stop at
the verification gate and report the implementation as blocked, not complete or
experimental. Repeat the smoke before changing the supported version or
any alias mapping.
The smoke harness records any files Cursor placed in the primary workspace
before it recursively removes that directory, so real workspace-write behavior
is known without changing production cleanup semantics.

Run the complete `tests/run-tests.sh` suite after the focused assertions pass.
No test can invoke the real Cursor, Codex, or Claude CLI.

## Out of Scope

- Running several Cursor models as a panel.
- Making Cursor the default reviewer.
- Treating Cursor as a plugin host.
- Accepting arbitrary Cursor model IDs through the Cursor override.
- Changing version fields or the release process.
- Refactoring unrelated orchestration or backend code.
