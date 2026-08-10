# Cursor Reviewer Design

## Goal

Add Cursor Agent CLI as an explicit reviewer override for consultation, plan
review, and code review. Preserve the current default reviewer pairings:
Claude Code uses Codex, and Codex uses Claude Code.

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

## Backend Structure

Add `scripts/lib/agents/cursor.mjs` with the same backend interface as the
Codex and Claude implementations. Register it in the agent registry. Reviewer
selection accepts the optional Cursor override before it falls back to the
host-to-peer map.

Cursor detection runs `agent --version` and probes `agent --help`
for every option used by the backend. The probe requires `--print`,
`--output-format`, `--mode`, `--sandbox`, `--trust`, `--workspace`, `--add-dir`,
and `--model`. The version floor stays deliberately low because flag support,
not the date-based version string, defines compatibility. Setup hints use the
official install command and `agent login` or `agent update`.

The detect response identifies `cursor` as the peer and reports its confinement.
It does not call `--list-models`. Model catalogues depend on the authenticated
account, and the Cursor invocation reports an unavailable mapped model through
the normal peer-failure contract.

## Request and Confinement Flow

Cursor accepts its initial prompt as a command argument. The review payload can
be much larger than the operating system argument limit. The backend therefore
creates a temporary workspace, writes the complete review prompt and payload to
one request file, and gives Cursor a short instruction to read that file and
return the required response.

The invocation uses:

```text
agent --print --output-format json --mode ask --sandbox enabled \
  --trust --workspace <temporary-workspace> --model <mapped-model-id>
```

Payload-only work exposes only the temporary workspace. Repository-context work
adds the repository with `--add-dir <repository-root>`. The temporary workspace
remains the primary workspace so repository-local Cursor configuration is not
the primary agent configuration. The backend deletes the temporary workspace
after the process exits or times out.

`ask` mode makes the Cursor tools read-only. `--sandbox enabled` adds Cursor's
sandbox policy. This is CLI-enforced confinement, not a claimed OS-enforced
read-only boundary. The backend does not pass `--force`, `--yolo`,
`--approve-mcps`, or a write-capable mode.

## Output and Failure Handling

The backend requests one JSON result. It uses the `result` field as reviewer
output. If Cursor returns `is_error: true` with exit status zero, the backend
changes the effective status to failure. This matches the existing protection
for CLIs that report API failures inside a successful process envelope.

Nonzero exits use the current `peer_failed` JSON shape. The shared transient
classifier decides whether one identical retry is allowed. Timeout, standard
output, standard error, parsed output, and any available API error status remain
available to the orchestration layer.

Temporary files are removed on success and failure. Payload size validation runs
before any file is created.

## Documentation

Update the root README and plugin README to explain that Cursor is an optional
reviewer, not a third host and not a new default. Show all four aliases and the
current mapped models. Add Cursor installation and authentication instructions.
State that each command runs one selected model and incurs one Cursor model
request per round.

Update the consultation, plan-review, and code-review skill contracts so they
preserve an explicitly selected Cursor alias throughout a workflow.

## Verification

Add a hermetic `tests/bin/agent` fixture. It must support version, help,
argument logging, request-file inspection, JSON success, JSON error, nonzero
exit, timeout classification inputs, and missing-flag simulation.

Start the behavior change with failing shell-suite assertions for:

- Cursor detection through the explicit peer override.
- Unchanged default Codex and Claude peer selection.
- All four alias-to-model mappings.
- Missing and unknown Cursor aliases.
- Ask mode, sandboxing, temporary workspace isolation, and repository access
  only when repository context is requested.
- JSON result extraction and `is_error: true` failure handling.
- Structured errors and transient retry metadata.
- Skill preservation of the selected peer and alias.
- README installation, usage, model, cost, and confinement guidance.

Run the complete `tests/run-tests.sh` suite after the focused assertions pass.
No test can invoke the real Cursor, Codex, or Claude CLI.

## Out of Scope

- Running several Cursor models as a panel.
- Making Cursor the default reviewer.
- Treating Cursor as a plugin host.
- Accepting arbitrary Cursor model IDs through the Cursor override.
- Changing version fields or the release process.
- Refactoring unrelated orchestration or backend code.
