// Cursor Agent CLI as an explicit reviewer backend.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";

import { assertPayloadSize } from "./common.mjs";

export const SUPPORTED_CURSOR_VERSION = "2026.08.04-aaa8809";
export const CURSOR_METADATA_DIR = path.join(os.homedir(), ".cursor", "projects");

export const CURSOR_MODELS = Object.freeze({
  composer: "composer-2.5",
  grok: "cursor-grok-4.6-high",
  kimi: "kimi-k3-max",
  glm: "glm-5.2-max"
});

const REQUIRED_FLAGS = [
  "--print", "--output-format", "--mode", "--sandbox",
  "--trust", "--workspace", "--add-dir", "--model"
];
const COMMAND_ONLY_FLAGS = ["--disable-project-configs", "--disable-auto-update"];

const VERSION_REMEDIATION = "agent update";
const INSTALL_REMEDIATION = ["curl https://cursor.com/install -fsS | bash", "agent login"];
const VERSION_PATTERN = /^(\d{4})\.(\d{2})\.(\d{2})(?:-([0-9A-Za-z.-]+))?$/;

function hasFlag(help, flag) {
  const escaped = flag.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`${escaped}(?=\\s|=|,|$)`).test(help);
}

function probeFlags() {
  const result = spawnSync("agent", ["--help"], { encoding: "utf8", maxBuffer: 4 * 1024 * 1024 });
  if (result.error || result.status !== 0) return { ok: false, missing: REQUIRED_FLAGS };
  const help = `${result.stdout ?? ""}${result.stderr ?? ""}`;
  const missing = REQUIRED_FLAGS.filter((flag) => !hasFlag(help, flag));
  if (missing.length > 0) return { ok: false, missing };

  // Cursor accepts security and update-control flags that it omits from help.
  // `status` validates those options locally without starting a model request.
  for (const flag of COMMAND_ONLY_FLAGS) {
    const probe = spawnSync("agent", [flag, "status"], {
      encoding: "utf8",
      maxBuffer: 4 * 1024 * 1024
    });
    if (probe.error) return { ok: false, missing: [flag] };
    if (probe.status !== 0) {
      const diagnostics = `${probe.stdout ?? ""}${probe.stderr ?? ""}`;
      if (/unknown option/i.test(diagnostics)) return { ok: false, missing: [flag] };
      return { ok: false, reason: "authentication_failed", missing: [] };
    }
  }
  return { ok: true, missing: [] };
}

function versionFailure(reason, version) {
  return {
    ok: false,
    reason,
    version,
    minimum: SUPPORTED_CURSOR_VERSION,
    setupHints: [VERSION_REMEDIATION]
  };
}

function compareVersionDates(left, right) {
  const leftMatch = VERSION_PATTERN.exec(left);
  const rightMatch = VERSION_PATTERN.exec(right);
  if (!leftMatch || !rightMatch) return null;
  for (let i = 1; i <= 3; i++) {
    const difference = Number(leftMatch[i]) - Number(rightMatch[i]);
    if (difference !== 0) return Math.sign(difference);
  }
  return 0;
}

function deniedMetadataWrite(text) {
  return /(?:EPERM|EACCES|permission denied|operation not permitted)/i.test(text) &&
    (text.includes(CURSOR_METADATA_DIR) || /[\\/]\.cursor[\\/]projects(?:[\\/]|\b)/i.test(text));
}

function cleanup(workspace) {
  try {
    fs.rmSync(workspace, { recursive: true, force: true });
    return undefined;
  } catch (error) {
    return error instanceof Error ? error.message : String(error);
  }
}

export function buildRunOptions({ workspace, input, timeoutMs = 600_000 }) {
  return {
    cwd: workspace,
    input,
    encoding: "utf8",
    timeout: timeoutMs,
    killSignal: "SIGKILL",
    maxBuffer: 32 * 1024 * 1024
  };
}

export const agent = {
  id: "cursor",
  displayName: "Cursor Agent CLI",
  command: "agent",
  minVersion: SUPPORTED_CURSOR_VERSION,

  detect() {
    let result;
    try {
      result = spawnSync("agent", ["--version"], { encoding: "utf8" });
    } catch (error) {
      return {
        ok: false,
        reason: "not_installed",
        detail: error instanceof Error ? error.message : String(error),
        setupHints: INSTALL_REMEDIATION
      };
    }
    if (result.error) {
      return {
        ok: false,
        reason: "not_installed",
        detail: result.error.message,
        setupHints: INSTALL_REMEDIATION
      };
    }
    if (result.status !== 0) {
      return {
        ok: false,
        reason: "authentication_failed",
        setupHints: ["agent login"]
      };
    }

    const version = (result.stdout ?? "").split(/\r?\n/, 1)[0].trim();
    if (!VERSION_PATTERN.test(version)) return versionFailure("unsupported_version_format", version);
    if (compareVersionDates(version, SUPPORTED_CURSOR_VERSION) < 0) return versionFailure("too_old", version);

    const flags = probeFlags();
    if (!flags.ok) {
      if (flags.reason === "authentication_failed") {
        return { ok: false, reason: flags.reason, setupHints: ["agent login"] };
      }
      return {
        ok: false,
        reason: "unsupported_build",
        version,
        minimum: SUPPORTED_CURSOR_VERSION,
        missingFlags: flags.missing,
        setupHints: [VERSION_REMEDIATION]
      };
    }
    return {
      ok: true,
      version,
      versionCheck: version === SUPPORTED_CURSOR_VERSION ? "exact" : "compatible",
      minimum: SUPPORTED_CURSOR_VERSION
    };
  },

  confinement() {
    return {
      sandbox: "ask-mode",
      osEnforced: false,
      runtimeWrites: [CURSOR_METADATA_DIR],
      detail:
        "Cursor runs in ask mode with its CLI sandbox enabled, from a fresh temporary workspace. " +
        "This is CLI-enforced, not an OS-enforced read-only boundary. Cursor also persists project " +
        `metadata under ${CURSOR_METADATA_DIR}, which requires host write permission.`
    };
  },

  run({ prompt, payload, cwd, model, timeoutMs = 600_000 }) {
    assertPayloadSize(payload);

    const workspace = fs.mkdtempSync(path.join(os.tmpdir(), "cursor-review-"));
    const modelId = CURSOR_MODELS[model];
    const input = cwd
      ? `Repository root: ${path.resolve(cwd)}\nResolve every relative payload path against this root.\n\n${prompt}\n\n${payload}`
      : `${prompt}\n\n${payload}`;
    const args = [
      "--print",
      "--output-format", "json",
      "--mode", "ask",
      "--sandbox", "enabled",
      "--trust",
      "--disable-project-configs",
      "--disable-auto-update",
      "--workspace", workspace,
      ...(cwd ? ["--add-dir", path.resolve(cwd)] : []),
      "--model", modelId
    ];

    let response;
    let cleanupError;
    try {
      let processResult;
      try {
        processResult = spawnSync("agent", args, buildRunOptions({ workspace, input, timeoutMs }));
      } catch (error) {
        processResult = { error };
      }

      const stdout = processResult.stdout ?? "";
      const stderr = processResult.stderr ?? "";
      let rc = processResult.status ?? -1;
      const outputTooLarge = processResult.error?.code === "ENOBUFS";
      const timedOut = !outputTooLarge &&
        (processResult.error?.code === "ETIMEDOUT" || Boolean(processResult.signal));
      const spawnError = !outputTooLarge && !timedOut && processResult.error
        ? {
            ...(typeof processResult.error.code === "string" && processResult.error.code.length > 0
              ? { code: processResult.error.code }
              : {}),
            message: typeof processResult.error.message === "string" && processResult.error.message.length > 0
              ? processResult.error.message
              : String(processResult.error)
          }
        : undefined;
      let output = stdout;
      let apiErrorStatus;
      let strictJsonFailure = false;

      if (rc === 0 && !processResult.error) {
        try {
          const parsed = JSON.parse(stdout);
          if (!parsed || typeof parsed !== "object" || Array.isArray(parsed) ||
              typeof parsed.result !== "string" || parsed.result.length === 0) {
            rc = 1;
            strictJsonFailure = true;
          } else {
            output = parsed.result;
            if (parsed.is_error === true) {
              rc = 1;
              if (parsed.api_error_status !== undefined) apiErrorStatus = parsed.api_error_status;
            }
          }
        } catch {
          rc = 1;
          strictJsonFailure = true;
        }
      }

      const modelRejected = rc !== 0 && Boolean(modelId) &&
        /\b(?:unknown model|model\b[^\n]*(?:not available|not found|unavailable))/i.test(`${stdout}\n${stderr}`);
      const metadataWriteDenied = rc !== 0 && deniedMetadataWrite(
        `${stdout}\n${stderr}\n${spawnError?.message ?? ""}`
      );
      response = {
        rc,
        output,
        stdout,
        stderr,
        timedOut,
        ...(strictJsonFailure ? { strictJsonFailure: true } : {}),
        ...(apiErrorStatus !== undefined ? { apiErrorStatus } : {}),
        ...(outputTooLarge ? { outputTooLarge: true } : {}),
        ...(spawnError ? { spawnError } : {}),
        ...(metadataWriteDenied
          ? { metadataWriteDenied: true, metadataPath: CURSOR_METADATA_DIR }
          : {}),
        ...(modelRejected
          ? {
              modelRejected: true,
              modelAlias: model,
              modelId,
              modelListCommand: "agent --list-models"
            }
          : {})
      };
    } finally {
      cleanupError = cleanup(workspace);
    }
    return cleanupError ? { ...response, cleanupError } : response;
  }
};
