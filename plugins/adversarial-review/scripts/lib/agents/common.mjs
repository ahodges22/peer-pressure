// Shared plumbing for peer agent backends.

import { spawnSync } from "node:child_process";

export const MAX_PAYLOAD_BYTES = 2_000_000;

export class PayloadTooLargeError extends Error {
  constructor(size) {
    super(`payload ${size} bytes exceeds ${MAX_PAYLOAD_BYTES / 1024}KB limit`);
    this.size = size;
  }
}

export function assertPayloadSize(payload) {
  const size = Buffer.byteLength(payload, "utf8");
  if (size > MAX_PAYLOAD_BYTES) throw new PayloadTooLargeError(size);
  return size;
}

export function parseSemver(text) {
  const m = /(\d+)\.(\d+)\.(\d+)/.exec(text ?? "");
  return m ? [Number(m[1]), Number(m[2]), Number(m[3])] : null;
}

export function compareSemver(a, b) {
  for (let i = 0; i < 3; i++) if (a[i] !== b[i]) return a[i] - b[i];
  return 0;
}

/**
 * `<command> --version` plus a minimum-version floor.
 *
 * An unparseable version string means a nightly or dev build. Allow it, because failing
 * closed would block prereleases, but report that the floor was not actually
 * enforced so the caller can say so rather than implying a check that never ran.
 */
export function detectVersion({ command, minVersion, notInstalledHints, tooOldHints }) {
  let r;
  try {
    r = spawnSync(command, ["--version"], { encoding: "utf8" });
  } catch (err) {
    return { ok: false, reason: "not_installed", detail: err.message, setupHints: notInstalledHints };
  }
  if (r.error || r.status !== 0) {
    return { ok: false, reason: "not_installed", setupHints: notInstalledHints };
  }

  const version = (r.stdout ?? "").trim();
  const parsed = parseSemver(version);
  if (parsed && compareSemver(parsed, parseSemver(minVersion)) < 0) {
    return {
      ok: false,
      reason: "too_old",
      version,
      minimum: minVersion,
      setupHints: tooOldHints(version)
    };
  }

  return {
    ok: true,
    version,
    versionCheck: parsed ? "ok" : "unparsed",
    minimum: minVersion
  };
}

export function parseStatus(output, valid) {
  const first = (output ?? "").trimStart().split(/\r?\n/)[0] ?? "";
  const m = first.match(/^STATUS:\s+(\S+)/);
  return m && valid.has(m[1]) ? m[1] : null;
}

// HTTP statuses worth one more attempt: rate limiting, and the 5xx family that
// providers return when a model is momentarily saturated. 529 is Anthropic's
// "Overloaded". Anything else (401, 403, 400, ...) is a real condition that a
// retry would only repeat.
const TRANSIENT_STATUS = new Set([408, 409, 425, 429, 500, 502, 503, 504, 522, 524, 529]);

// Text signatures of a connection that dropped mid-stream. Kept deliberately
// narrow: a broad match here would tell the caller to re-run a review that
// failed for a real reason, wasting a full second round-trip and hiding the
// actual cause behind a duplicate failure.
const TRANSIENT_TEXT =
  /\b(overloaded|rate[ _-]?limit|too many requests|service unavailable|bad gateway|gateway timeout|temporarily unavailable|stream (?:closed|ended|disconnected|interrupted)|premature close|socket hang ?up|ECONNRESET|ETIMEDOUT|EPIPE|ENETUNREACH|EAI_AGAIN)\b/i;

/**
 * Decide whether a failed peer run is worth exactly one more attempt.
 *
 * Returns null when the failure is not transient.
 */
export function classifyTransient({ rc, apiErrorStatus, output, stderr, timedOut } = {}) {
  if (timedOut) return { retryReason: "provider_timeout" };
  if (apiErrorStatus && TRANSIENT_STATUS.has(Number(apiErrorStatus))) {
    return { retryReason: `provider_http_${apiErrorStatus}` };
  }
  // rc 0 with no other signal is not a failure at all.
  if (rc === 0 && !apiErrorStatus) return null;
  const haystack = `${output ?? ""}\n${stderr ?? ""}`;
  const m = TRANSIENT_TEXT.exec(haystack);
  return m ? { retryReason: "transient_provider_stream", matched: m[0].toLowerCase() } : null;
}
