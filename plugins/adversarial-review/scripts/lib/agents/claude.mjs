// Claude Code CLI as the peer agent. Used when the host is Codex.

import { spawnSync } from "node:child_process";

import { assertPayloadSize, detectVersion } from "./common.mjs";

// Floor is deliberately low. The real compatibility risk is flag availability,
// not a version number, so detect() probes `--help` for the exact flags run()
// emits rather than trusting a semver guess. See REQUIRED_FLAGS.
export const MIN_CLAUDE_VERSION = "2.0.0";

// Every flag run() depends on. A Claude Code build missing any of these would
// fail deep inside the CLI with an opaque usage error, so surface it at detect
// time with the flag named.
const REQUIRED_FLAGS = [
  "--print",
  "--output-format",
  "--append-system-prompt",
  "--tools",
  "--allowed-tools",
  "--safe-mode",
  "--no-session-persistence",
  "--model"
];

const NOT_INSTALLED_HINTS = [
  "Install Claude Code: `npm install -g @anthropic-ai/claude-code`",
  "Authenticate: run `claude` once and complete login"
];

function probeFlags() {
  const r = spawnSync("claude", ["--help"], { encoding: "utf8", maxBuffer: 4 * 1024 * 1024 });
  if (r.error || r.status !== 0) return { ok: false, missing: null };
  const help = `${r.stdout ?? ""}${r.stderr ?? ""}`;
  const missing = REQUIRED_FLAGS.filter((f) => !help.includes(f));
  return { ok: missing.length === 0, missing };
}

export const agent = {
  id: "claude",
  displayName: "Claude Code CLI",
  command: "claude",
  minVersion: MIN_CLAUDE_VERSION,

  detect() {
    const base = detectVersion({
      command: "claude",
      minVersion: MIN_CLAUDE_VERSION,
      notInstalledHints: NOT_INSTALLED_HINTS,
      tooOldHints: (version) => [
        `Claude Code CLI ${version} is too old: adversarial-review requires >= ${MIN_CLAUDE_VERSION}.`,
        "Upgrade: `npm install -g @anthropic-ai/claude-code@latest`",
        "Then re-run detect to confirm."
      ]
    });
    if (!base.ok) return base;

    const flags = probeFlags();
    if (!flags.ok && flags.missing) {
      return {
        ok: false,
        reason: "unsupported_build",
        version: base.version,
        missingFlags: flags.missing,
        setupHints: [
          `This Claude Code build does not accept: ${flags.missing.join(", ")}.`,
          "Upgrade: `npm install -g @anthropic-ai/claude-code@latest`"
        ]
      };
    }
    return base;
  },

  confinement() {
    return {
      sandbox: "tool-policy",
      osEnforced: false,
      detail:
        "For payload-only reviews, the reviewer runs with all tools disabled. For repo-context " +
        "reviews, it receives read-only tools. Enforced by the CLI, not by the OS."
    };
  },

  /**
   * Run `claude --print` with the payload piped to stdin.
   * Returns { rc, output, stdout, stderr }.
   */
  run({
    prompt,
    payload,
    cwd,
    model,
    timeoutMs = 180_000
  }) {
    assertPayloadSize(payload);

    const args = ["--print", "--output-format", "json", "--no-session-persistence"];

    // The reviewer must be independent of the host's configuration, so
    // --safe-mode strips CLAUDE.md, skills, plugins, hooks and MCP servers.
    args.push("--safe-mode");
    // Both flags are variadic, so each value is passed as ONE comma-separated
    // token. A space-separated list would let the parser swallow the flag that
    // follows.
    if (cwd) {
      args.push("--tools", "Read,Grep,Glob", "--allowed-tools", "Read,Grep,Glob");
    } else {
      args.push("--tools", "");
    }

    if (model) args.push("--model", model);
    args.push("--append-system-prompt", prompt);

    const r = spawnSync("claude", args, {
      cwd: cwd ?? undefined,
      input: payload,
      encoding: "utf8",
      timeout: timeoutMs,
      maxBuffer: 32 * 1024 * 1024
    });

    const stdout = r.stdout ?? "";
    const stderr = r.stderr ?? "";
    let rc = r.status ?? -1;
    let output = stdout;

    // `claude --print` exits 0 even when the turn failed. An API 5xx comes back
    // as rc 0, subtype "success", and the error text in `result`, with `is_error`
    // as the only reliable signal. Trusting the exit code alone would report a
    // server error as a completed review.
    let apiErrorStatus;
    try {
      const parsed = JSON.parse(stdout);
      output = typeof parsed.result === "string" ? parsed.result : stdout;
      if (parsed.is_error === true) {
        if (rc === 0) rc = 1;
        if (parsed.api_error_status) apiErrorStatus = parsed.api_error_status;
      }
    } catch {
      // Not JSON: fall back to raw stdout and whatever the exit code said.
    }

    const timedOut = r.error?.code === "ETIMEDOUT" || Boolean(r.signal);
    return { rc, output, stdout, stderr, timedOut, ...(apiErrorStatus ? { apiErrorStatus } : {}) };
  }
};
