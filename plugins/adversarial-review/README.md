# adversarial-review

The plugin behind [Peer Pressure](../../README.md).

Cross-model consultation, plan review, and code review. The peer is always the agent CLI that is *not* running the skill. Claude Code uses Codex, and Codex uses Claude Code, so the second view comes from a different model.

## Skills

- **`consult-peer`** gets one independent, non-binding opinion on one focused question. The host states its initial assessment first, then sends a neutral payload that excludes its conclusion and the user's preferred answer.
- **`plan-review`** drafts a plan, adds a required `Scope / Out of scope` section, sends it for critique, fixes findings, and iterates to approval.
- **`code-review`** runs the same loop over a git diff (uncommitted, staged, or against a branch) and keeps findings tied to the change intent.

Consultation makes one peer request, except for one identical retry after a runtime-marked transient failure. No repository context is passed, and the peer prompt forbids tool use. The skill refuses to transmit credentials, tokens, private keys, personal data, customer content, or other sensitive context. Each request can use the peer account's quota.

Both review skills checkpoint every 3 rounds and use a host-native prompt for each decision. If more than 50% of a round's findings are out of scope, the skill stops for user direction before it continues.

The runtime exposes consultation and review commands. Consultation is payload-only. Review backends do not receive a write-capable mode.

## Layout

`bin/` holds the `adversarial-review` bash shim. It forwards to `scripts/orchestration.mjs`, so one `Bash(adversarial-review *)` allowlist rule covers every subcommand. The shim is a Claude Code convenience. Codex does not put plugin `bin/` on `PATH`, so its skills call the runtime by the absolute path that `detect` returns in `invocation.review`.

Install and usage: [repository README](../../README.md).
Architecture and dev loop: [AGENTS.md](../../AGENTS.md).
