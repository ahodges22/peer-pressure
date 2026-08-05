## Why

Peer Pressure can challenge a completed plan or code change, but it cannot ask the opposite agent for an independent view of an open question. Users need a one-shot consultation path that preserves cross-model independence without treating advice as approval.

## What Changes

- Add a `consult-peer` skill for explicit requests to obtain the opposite agent's opinion on one question, diagnosis, tradeoff, or approach.
- Add a payload-only `consult` runtime command with required question input, optional context and candidate approaches, and a required recommendation label on the first substantive response line.
- Separate generic peer execution from review-specific status parsing while preserving existing plan-review and code-review behavior.
- Require the host to state its initial assessment before the peer call, exclude that assessment from the peer payload, sanitize the selected context, and synthesize the labeled peer view with its own final recommendation.
- Update hermetic tests and user-facing plugin descriptions for consultation.
- Keep the existing plugin ID and all review workflows compatible.

## Capabilities

### New Capabilities

- `peer-consultation`: One-shot, non-binding consultation with the agent CLI that is not the host.

### Modified Capabilities

None.

## Impact

- Runtime: `plugins/adversarial-review/scripts/orchestration.mjs` and a new consultation prompt.
- Skill surface: a new directory under `plugins/adversarial-review/skills/`.
- Tests: `tests/run-tests.sh` and existing fake peer CLI fixtures as needed.
- Documentation and metadata: repository and plugin README files, marketplace metadata, and the Codex plugin interface.
- External behavior: each consultation consumes one peer CLI model request. No new dependency or plugin migration is required.
