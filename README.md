<p align="center">
  <img src="assets/logo.svg" width="120" alt="Peer Pressure">
</p>

<h1 align="center">Peer Pressure</h1>

<p align="center">
  <em>Get an independent view from the other agent.</em><br>
  <a href="https://github.com/ahodges22/peer-pressure/actions/workflows/ci.yml"><img src="https://github.com/ahodges22/peer-pressure/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="MIT">
  <img src="https://img.shields.io/badge/node-%E2%89%A520-brightgreen.svg" alt="Node >= 20">
</p>

---

Cross-model consultation, plan review, and code review for **Claude Code and Codex**. The peer is always the agent CLI that is *not* running the skill:

| You are in | Peer agent |
|---|---|
| Claude Code | Codex |
| Codex | Claude Code |

A peer that shares your model can share your blind spots. Peer Pressure keeps the models separate, which means you need **both CLIs installed and logged in**.

## Install

Requirements: Node.js 20+, Codex CLI 0.125.0+, and Claude Code 2.0.0+.

```bash
npm install -g @openai/codex && codex login
npm install -g @anthropic-ai/claude-code && claude   # log in on first run
```

**Claude Code**

```bash
claude plugin marketplace add https://github.com/ahodges22/peer-pressure
claude plugin install adversarial-review@peer-pressure
```

**Codex**

```bash
codex plugin marketplace add https://github.com/ahodges22/peer-pressure
codex plugin add adversarial-review@peer-pressure
```

## Use

Three skills. Ask for one by name, or describe the task.

```
Ask Claude whether Redis is justified for this service

Run an adversarial plan review on: add rate limiting to the public API

Adversarially review my uncommitted changes
```

- **`consult-peer`** gets one independent, non-binding opinion from the other agent. The host states its initial assessment first, then sends one neutral question without its conclusion or the user's preferred answer. Consultation is payload-only: no repository context is passed, and the peer prompt forbids tool use.
- **`plan-review`** drafts a plan, adds a required `Scope / Out of scope` section, sends the plan for critique, fixes findings, and repeats until approved.
- **`code-review`** runs the same loop over a git diff (uncommitted, staged, or against a branch) and keeps findings tied to the change intent.

Consultation handles one focused question at a time. It refuses to transmit credentials, tokens, private keys, personal data, customer content, or other sensitive context. A successful consultation uses one peer request. Only a runtime-marked transient failure permits one identical retry.

Both review skills stop for your input every 3 rounds and use a host-native prompt for each decision. If more than 50% of a round's findings are out of scope, the skill stops early and asks whether to continue.

Findings are merge-blocking only. Out-of-scope suggestions get rejected by default, so the loop is built to converge instead of bikeshed.

> **Cost:** each consultation and every review round sends a model request through the peer CLI and can use the peer account's quota. Review loops have no hard iteration limit. They run until approval or until you stop them at a checkpoint. `detect`, `inspect-repo`, and `new-ctx` do not send a review or consume model tokens. `detect` runs a local version check and can probe `--help` for required flags.

## License

MIT - see [LICENSE](./LICENSE).
