// Codex CLI as the peer agent. Used when the host is Claude Code.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

import { assertPayloadSize, detectVersion } from "./common.mjs";

// Keep one supported floor for predictable `codex exec` behavior and error
// reporting across both review skills.
export const MIN_CODEX_VERSION = "0.125.0";

const NOT_INSTALLED_HINTS = [
  "Install Codex: `npm install -g @openai/codex` (or `brew install codex` on macOS)",
  "Authenticate: `codex login`"
];

export const agent = {
  id: "codex",
  displayName: "Codex CLI",
  command: "codex",
  minVersion: MIN_CODEX_VERSION,

  detect() {
    return detectVersion({
      command: "codex",
      minVersion: MIN_CODEX_VERSION,
      notInstalledHints: NOT_INSTALLED_HINTS,
      tooOldHints: (version) => [
        `Codex CLI ${version} is too old — adversarial-review requires >= ${MIN_CODEX_VERSION}.`,
        "Upgrade: `npm install -g @openai/codex@latest` (or `brew upgrade codex` on macOS)",
        "Then re-run detect to confirm."
      ]
    });
  },

  confinement() {
    return {
      sandbox: "read-only",
      osEnforced: true,
      detail:
        "Codex runs under an OS-enforced read-only sandbox. Reads are not path-restricted, " +
        "so it can read files outside the repo (e.g. ~/.ssh, ~/.aws)."
    };
  },

  /**
   * Run `codex exec` with a pre-built payload piped to stdin.
   * Returns { rc, output, stdout, stderr }.
   */
  run({
    prompt,
    payload,
    cwd,
    model,
    timeoutMs = 180_000,
    skipGitRepoCheck
  }) {
    assertPayloadSize(payload);

    const outputFile = fs.mkdtempSync(path.join(os.tmpdir(), "codex-out-")) + "/last-message";
    const workdir = cwd ?? fs.mkdtempSync(path.join(os.tmpdir(), "codex-workdir-"));
    const ephemeral = !cwd;

    const args = ["exec", "--ephemeral", "-s", "read-only"];
    if (skipGitRepoCheck ?? !cwd) args.push("--skip-git-repo-check");
    if (model) args.push("-m", model);
    args.push(prompt, "--output-last-message", outputFile);

    const r = spawnSync("codex", args, {
      cwd: workdir,
      input: payload,
      encoding: "utf8",
      timeout: timeoutMs,
      maxBuffer: 32 * 1024 * 1024
    });

    let output = "";
    try { output = fs.readFileSync(outputFile, "utf8"); } catch {}

    try { fs.rmSync(path.dirname(outputFile), { recursive: true, force: true }); } catch {}
    if (ephemeral) { try { fs.rmSync(workdir, { recursive: true, force: true }); } catch {} }

    const timedOut = r.error?.code === "ETIMEDOUT" || Boolean(r.signal);
    return { rc: r.status ?? -1, output, stdout: r.stdout ?? "", stderr: r.stderr ?? "", timedOut };
  }
};
