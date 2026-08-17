# adversarial-review

The plugin behind [Peer Pressure](../../README.md).

Cross-model consultation, plan review, and code review. By default, Claude Code
uses Codex and Codex uses Claude Code, so the second view comes from a different
model. The Cursor Agent CLI is available as an optional reviewer.

## Skills

- **`consult-peer`** gets one independent, non-binding opinion on one focused question. The host states its initial assessment first, then sends a neutral payload that excludes its conclusion and the user's preferred answer.
- **`plan-review`** drafts a plan, adds a required `Scope / Out of scope` section, sends it for critique, fixes findings, and iterates to approval.
- **`code-review`** runs the same loop over a git diff (uncommitted, staged, or against a branch) and keeps findings tied to the change intent.

Consultation makes one peer request, except for one identical retry after a runtime-marked transient failure. No repository context is passed, and the peer prompt forbids tool use. The skill refuses to transmit credentials, tokens, private keys, personal data, customer content, or other sensitive context. Each request can use the peer account's quota.

Both review skills checkpoint every 3 rounds and use a host-native prompt for each decision. If more than 50% of a round's findings are out of scope, the skill stops for user direction before it continues.

The runtime exposes consultation and review commands. Consultation is payload-only. Review backends do not receive a write-capable mode.

## Optional Cursor reviewer

Cursor is an optional reviewer override. It is not a plugin host and does not
change the default Claude Code to Codex or Codex to Claude pairing. Request
Cursor explicitly with a model alias:

```text
composer -> composer-2.5
grok -> cursor-grok-4.6-high
kimi -> kimi-k3-max
glm -> glm-5.2-max
```

Install and authenticate the Cursor Agent CLI:

```bash
curl https://cursor.com/install -fsS | bash
agent login
```

Minimum tested build: `2026.08.04-aaa8809`. Newer builds are accepted when
they provide the required command flags.

Update an older build with `agent update`.

Model diagnostics: `agent --list-models`.

Each round starts one Cursor CLI invocation, but a tool-using turn can make
multiple provider calls. Ask mode and Cursor's sandbox enforce read-only
behavior at the CLI level, not an OS read-only boundary. The direct child
timeout is 600 seconds. A descendant retaining an output pipe can keep
`spawnSync` blocked and delay cleanup.

Cursor also writes project and session metadata under `~/.cursor/projects`,
even when the review uses an empty temporary workspace. A host sandbox must
grant the Cursor command write access to that path. Permission failures return
`cursor_metadata_write_denied` with the required path instead of a generic peer
failure.

Payload-only Cursor work exposes only an empty temporary workspace.
Repository-context work also grants Cursor read access to the repository. Cursor
rules, skills, notes, transcripts, or MCP configuration in that repository can
influence the session, so use repository context only with repositories whose
Cursor configuration you trust.

## Layout

`bin/` holds the `adversarial-review` bash shim. It forwards to `scripts/orchestration.mjs`, so one `Bash(adversarial-review *)` allowlist rule covers every subcommand. The shim is a Claude Code convenience. Codex does not put plugin `bin/` on `PATH`, so its skills call the runtime by the absolute path that `detect` returns in `invocation.review`.

Install and usage: [repository README](../../README.md).
Architecture and dev loop: [AGENTS.md](../../AGENTS.md).
