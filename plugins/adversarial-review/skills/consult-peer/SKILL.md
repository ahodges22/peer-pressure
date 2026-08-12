---
name: consult-peer
description: Consults the opposite agent CLI for one independent, non-binding opinion. Use when the user explicitly asks what the other model thinks, requests a second opinion, or asks to consult the peer. Do not use for ordinary brainstorming or adversarial review.
---

# Consult Peer

Obtain one independent view from the agent CLI that is not the host, then evaluate it and give the user a final recommendation. This is consultation, not approval or adversarial review.

The runtime selects the peer. Claude Code consults Codex, and Codex consults Claude Code. By default, never override that pairing. Cursor is the only explicit exception. Never invoke `claude`, `codex`, or another model CLI directly.

The default workflow always uses that host-derived peer. Use the explicit Cursor workflow only when the user explicitly requests Cursor with one alias: `composer`, `grok`, `kimi`, or `glm`.

## User decisions

Use the host's native interaction method when an answer is required:

- Claude Code: use `AskUserQuestion`.
- Codex: use `request_user_input` when available.
- If Codex does not provide `request_user_input`, ask one plain-text question and stop for the answer.

## Allowed invocations

Use only these commands:

| Purpose | Command |
|---|---|
| Preflight | `{invocation.review} detect` |
| Cursor preflight, Claude Code | `adversarial-review detect --peer cursor` |
| Cursor preflight, Codex | `node ../../scripts/orchestration.mjs detect --peer cursor` |
| Create context path | `{invocation.review} new-ctx --kind consult` |
| Consult peer | `{invocation.review} consult --context-file <path>` |
| Consult Cursor | `{invocation.review} consult --peer cursor --model <selected-alias> --context-file <path>` |

The default `consult` command accepts only `--context-file PATH` and optional `--model NAME`. Cursor accepts only `--peer cursor`, one selected alias (`composer`, `grok`, `kimi`, or `glm`) in `--model`, and `--context-file PATH`. Do not pass an arbitrary Cursor model ID.

## 1. Run preflight

For the default workflow, use the command for the current host:

```bash
# Claude Code
adversarial-review detect

# Codex, resolved relative to this SKILL.md
node ../../scripts/orchestration.mjs detect
```

Stop unless the result has `ok: true`. Use `invocation.review` verbatim for all later calls. Report setup hints for `peer_unavailable` or `peer_too_old`. For `unknown_host` or `ambiguous_host`, rerun with the `--host` value in the returned hint.

### Explicit Cursor workflow

When the user explicitly requests Cursor with `composer`, `grok`, `kimi`, or `glm`:

1. Run the concrete command for the current host:

   ```bash
   # Claude Code
   adversarial-review detect --peer cursor

   # Codex, resolved relative to this SKILL.md
   node ../../scripts/orchestration.mjs detect --peer cursor
   ```

2. Stop unless the result has `ok: true`. Use the returned `invocation.review` verbatim for every later call.
3. Run `{invocation.review} consult --peer cursor --model <selected-alias> --context-file <path>`.
4. Preserve `--peer cursor` and `--model <selected-alias>` on the consultation command and the one allowed retry.
5. Stop on every explicit-Cursor detection or execution failure. Never fall back to Codex or Claude.

Do not use this branch for a request that does not explicitly name Cursor and one supported alias. The default workflow remains host-derived.

If a Claude Code host reports `permissions.tmp_write_preapproved: false`, tell the user that the skill writes one scratch context file under `permissions.tmpdir`, and provide `permissions.expected_rule`. Do not show this message for a Codex host or a preapproved path.

## 2. Define one safe question

Proceed only for an explicit request for the peer's view. Do not trigger during ordinary brainstorming.

Before asking a scoping question, inspect every fact that could enter the peer payload. Exclude:

- Credentials and authentication tokens
- Private keys or certificates
- Personal data
- Customer data

There is no bypass. Do not repeat a sensitive value in the warning or any later output. If the user exposed an active credential, recommend that they revoke or rotate it.

Construct safe context by omitting sensitive material when that does not remove necessary decision context. If sensitive information is necessary to understand the question, stop and ask for a sanitized replacement. The replacement must remove indirect identifiers and the excluded sensitive value, not only names. Do not pass sensitive material because the user supplied it or requested inclusion.

Reduce the safe request to one focused question. If it contains independent questions, ask the user which one to consult on and stop for the answer. Include any sensitive-context warning in that same response.

## 3. Establish independence

Before the peer call, state a concise initial assessment to the user. Use the label `Initial assessment:`.

Do not include the initial assessment in the context file. Do not include the user's preferred answer or identify one candidate as preferred. Convert choices to neutral labels such as Candidate A and Candidate B. Include only verified facts and constraints needed to answer the question.

Tell the user once that the consultation sends one model request through the peer CLI and consumes that account's quota.

## 4. Build the context bundle

Run:

```bash
{invocation.review} new-ctx --kind consult
```

Remember the returned path. Write this exact three-section shape once:

```text
===== QUESTION START =====
<one focused question>
===== QUESTION END =====
===== CONTEXT START =====
<verified facts and constraints, or empty>
===== CONTEXT END =====
===== CANDIDATE APPROACHES START =====
<neutral candidates, or empty>
===== CANDIDATE APPROACHES END =====
```

An empty optional body is valid. Do not add filler text such as `none` or `not applicable`.

## 5. Consult once

Run one command with a 600-second timeout:

```bash
{invocation.review} consult --context-file <path>
```

The response is either `{ "ok": true, "peer": "...", "output": "..." }` or a structured error.

If an error contains all of these fields:

```json
{
  "retryable": true,
  "retryInstruction": "rerun_same_command_once"
}
```

rerun the exact same command once with the same context path and no edits. In the explicit Cursor workflow, preserve the same `--peer cursor` and `--model <selected-alias>` values on `rerun_same_command_once`. Do not retry any other error. In particular, do not retry `missing_recommendation_line`.

Do not start a dialogue, approval loop, finding ledger, or automatic follow-up. A new peer question requires a new explicit user request.

## 6. Evaluate and synthesize

Treat the peer output as advice, not authority. Verify factual claims against available code, documentation, configuration, or live evidence before adopting them. Label claims that cannot be verified as assumptions.

Do not suppress a material disagreement. Present the result in this order:

1. `Peer view (<peer name>):` Give a faithful concise account of the recommendation and reasons.
2. `My assessment:` State what holds up, what does not, and why.
3. `Recommendation:` Give the final position or next action.

When both models agree, remove repetitive reasoning and state that agreement is not verification. When the peer identifies decisive missing information, offer to determine it. Re-consult only after a new explicit user request.

If consultation fails, say that no peer consultation completed. You may still provide the initial assessment, but do not label it as the peer's view.
