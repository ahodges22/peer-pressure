# adversarial-review

The plugin behind [Peer Pressure](../../README.md).

Adversarial plan review and code review. The reviewer is always the agent CLI that is *not* running the skill. Claude Code is reviewed by Codex, and Codex is reviewed by Claude Code, so it never grades its own homework.

## Skills

- **`plan-review`** drafts a plan, adds a required `Scope / Out of scope` section, sends it for critique, fixes findings, and iterates to approval.
- **`code-review`** runs the same loop over a git diff (uncommitted, staged, or against a branch) and keeps findings tied to the change intent.

Both skills checkpoint every 3 rounds and use a host-native prompt for each decision. If more than 50% of a round's findings are out of scope, the skill stops for user direction before it continues.

The runtime exposes review commands only. Peer backends do not receive a write-capable mode.

## Layout

`bin/` holds the `adversarial-review` bash shim. It forwards to `scripts/orchestration.mjs`, so one `Bash(adversarial-review *)` allowlist rule covers every subcommand. The shim is a Claude Code convenience. Codex does not put plugin `bin/` on `PATH`, so its skills call the runtime by the absolute path that `detect` returns in `invocation.review`.

Install and usage: [repository README](../../README.md).
Architecture and dev loop: [AGENTS.md](../../AGENTS.md).
