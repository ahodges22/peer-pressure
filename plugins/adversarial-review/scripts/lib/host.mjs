// Which agent CLI is running this plugin, and therefore which *other* agent CLI
// should perform the review.
//
// The whole premise of adversarial review is that the reviewer is not the author.
// Running the host's own model against its own output preserves fresh-context
// independence but loses model independence — the reviewer shares the author's
// blind spots. So the peer is always the CLI that is *not* the host.

export const HOST_CLAUDE_CODE = "claude-code";
export const HOST_CODEX = "codex";

export const HOSTS = [HOST_CLAUDE_CODE, HOST_CODEX];

// Environment markers, verified empirically against Claude Code 2.1.x and Codex
// 0.145.x. `CLAUDE_PLUGIN_ROOT` is hook-only, so it cannot be used here.
// `CODEX_SANDBOX*` is set only under sandboxed modes, so it is not a reliable
// marker either — `CODEX_THREAD_ID` is present under `danger-full-access` too.
const MARKERS = {
  [HOST_CLAUDE_CODE]: "CLAUDECODE",
  [HOST_CODEX]: "CODEX_THREAD_ID"
};

// The peer is the other one. Kept as an explicit map rather than "whichever is
// not the host" so adding a third host later is a deliberate edit, not an
// accidental pairing.
const PEER_OF = {
  [HOST_CLAUDE_CODE]: "codex",
  [HOST_CODEX]: "claude"
};

export const HOST_ENV_OVERRIDE = "ADVERSARIAL_REVIEW_HOST";

/**
 * Resolve the host.
 *
 * Precedence: explicit --host flag > ADVERSARIAL_REVIEW_HOST > env markers.
 *
 * Env inheritance makes marker detection ambiguous in nested setups: a Codex
 * session launched from inside Claude Code inherits CLAUDECODE, so both markers
 * are present and neither is authoritative. Guessing there would silently point
 * the review at the wrong CLI — and in the worst case at the host's own model,
 * which is exactly the failure mode this plugin exists to prevent. Fail closed
 * and make the caller say which it is.
 *
 * Returns { ok: true, host, peerId, source } or { ok: false, reason, ... }.
 */
export function detectHost({ env = process.env, override } = {}) {
  const explicit = override ?? env[HOST_ENV_OVERRIDE];
  if (explicit) {
    if (!HOSTS.includes(explicit)) {
      return {
        ok: false,
        reason: "unknown_host",
        detail: `'${explicit}' is not a supported host`,
        supported: HOSTS,
        source: override ? "flag" : "env"
      };
    }
    return {
      ok: true,
      host: explicit,
      peerId: PEER_OF[explicit],
      source: override ? "flag" : "env"
    };
  }

  const present = HOSTS.filter((h) => Boolean(env[MARKERS[h]]));

  if (present.length === 1) {
    return { ok: true, host: present[0], peerId: PEER_OF[present[0]], source: "env-marker" };
  }

  if (present.length > 1) {
    return {
      ok: false,
      reason: "ambiguous_host",
      detail:
        `both ${present.map((h) => MARKERS[h]).join(" and ")} are set, which happens when ` +
        "one agent CLI is running inside another. Environment variables are inherited, so " +
        "the marker alone cannot say which CLI is actually driving this plugin.",
      candidates: present,
      hint: `Pass --host <${HOSTS.join("|")}> or set ${HOST_ENV_OVERRIDE}.`
    };
  }

  return {
    ok: false,
    reason: "unknown_host",
    detail:
      `no host marker found (looked for ${HOSTS.map((h) => MARKERS[h]).join(", ")}). ` +
      "This usually means the runtime was invoked directly from a plain shell rather than " +
      "from inside Claude Code or Codex.",
    supported: HOSTS,
    hint: `Pass --host <${HOSTS.join("|")}> or set ${HOST_ENV_OVERRIDE}.`
  };
}

export function peerIdFor(host) {
  return PEER_OF[host];
}
