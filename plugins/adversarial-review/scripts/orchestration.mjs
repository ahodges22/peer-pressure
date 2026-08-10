#!/usr/bin/env node
// Single entrypoint for codex orchestration. Subcommands emit JSON to stdout
// so the SKILL can parse results without string-matching free-form prose.

import crypto from "node:crypto";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { parseArgs } from "node:util";
import { fileURLToPath } from "node:url";

import { parseBundle } from "./lib/bundle.mjs";
import { writeAllSync } from "./lib/io.mjs";
import { peerFor, parseStatus, classifyTransient, PayloadTooLargeError } from "./lib/agents/index.mjs";
import { CURSOR_MODELS } from "./lib/agents/cursor.mjs";
import { detectHost, HOST_CLAUDE_CODE, HOSTS } from "./lib/host.mjs";
import { checkTmpWritePreapproved } from "./lib/permissions.mjs";
import { buildCodePayload, buildCodeSelfCollectPayload } from "./lib/diff.mjs";
import { findSecretFilesInWorkingTree } from "./lib/secrets.mjs";
import {
  branchAheadOf, currentHead, defaultBranch, diffStat,
  isInsideWorkTree, repoRoot, statusShort
} from "./lib/git.mjs";

const ROOT = path.resolve(fileURLToPath(new URL("..", import.meta.url)));
const PROMPTS = path.join(ROOT, "scripts", "prompts");
const RUNTIME = path.join(ROOT, "scripts", "orchestration.mjs");

// How the skills should spell subsequent calls, echoed back by `detect` so a
// skill never has to guess. Claude Code puts the plugin's bin/ on PATH; Codex
// does not, so there the runtime is addressed by absolute path.
function invocationFor(host) {
  if (host === HOST_CLAUDE_CODE) {
    return { review: "adversarial-review" };
  }
  return { review: `node ${RUNTIME}` };
}

const REVIEW_STATUSES = new Set(["APPROVED", "CHANGES_REQUIRED"]);

function emit(obj, code = 0) {
  writeAllSync(1, JSON.stringify(obj, null, 2) + "\n");
  process.exit(code);
}

// AGENTS.md promises "errors are JSON, not text" and the SKILLs parse `error`
// off stdout. Validation failures must honour that too, or Claude sees a bare
// string where it expects a contract.
function die(msg) {
  emit({ ok: false, error: "invalid_usage", detail: msg }, 1);
}

function usage() {
  return [
    "Usage:",
    "  adversarial-review detect",
    "  adversarial-review inspect-repo",
    "  adversarial-review new-ctx --kind code|plan|consult",
    "  adversarial-review plan-review --context-file PATH",
    "  adversarial-review code-review --mode uncommitted|staged|branch [--base REF] [--paths \"a b\"] [--context-file PATH] [--repo-context] [--self-collect] [--include-secrets] [--include-large] [--include-binary] [--allow-skipped-large]",
    "  adversarial-review consult --context-file PATH [--model NAME]",
    "",
    "The context file is a single file with fenced sections for the selected command.",
    "",
    `Global: --host <${HOSTS.join("|")}> overrides host auto-detection.`,
    "Global: --peer cursor selects Cursor as the reviewer and requires --model composer|grok|kimi|glm for consultation and review commands.",
    "Without --peer, Claude Code uses Codex and Codex uses Claude Code.",
    "Run `detect` first: it reports the host, the peer, and the exact command prefix to use for every later call."
  ].join("\n");
}

function loadPrompt(name, subs = {}) {
  const raw = fs.readFileSync(path.join(PROMPTS, `${name}.txt`), "utf8");
  return Object.entries(subs).reduce(
    (acc, [k, v]) => acc.replaceAll(`{{${k}}}`, v),
    raw
  );
}

function readFileIf(p) {
  if (!p) return "";
  const abs = path.resolve(p);
  if (!fs.existsSync(abs)) die(`file not found: ${p}`);
  return fs.readFileSync(abs, "utf8");
}

// The host decides the peer, so a host we cannot identify means we cannot pick a
// reviewer. Guessing risks handing the review to the host's own model, which
// silently defeats the point of adversarial review, so fail closed instead.
function requireHost() {
  const h = detectHost({ override: HOST_OVERRIDE });
  if (!h.ok) {
    emit({
      ok: false,
      error: h.reason,
      detail: h.detail,
      ...(h.candidates ? { candidates: h.candidates } : {}),
      supported: HOSTS,
      ...(h.hint ? { hint: h.hint } : {})
    }, 2);
  }
  return h;
}

// The peer must be installed AND new enough. An old CLI rejects the flags the
// backend emits and would otherwise fail as an opaque `peer_failed`.
function peerDetectionError(reason) {
  return {
    too_old: "peer_too_old",
    not_installed: "peer_unavailable",
    authentication_failed: "authentication_failed",
    unsupported_build: "unsupported_build",
    unsupported_version_format: "unsupported_version_format"
  }[reason] ?? "peer_unavailable";
}

function requirePeer(host, peerOverride) {
  const peer = peerFor(host, peerOverride);
  const detection = peer.detect();
  if (!detection.ok) {
    emit({
      ok: false,
      error: peerDetectionError(detection.reason),
      host,
      peer: peer.id,
      peerName: peer.displayName,
      ...(detection.version ? { version: detection.version } : {}),
      ...(detection.minimum ? { minimum: detection.minimum } : {}),
      ...(detection.supportedVersion ? { supportedVersion: detection.supportedVersion } : {}),
      ...(detection.missingFlags ? { missingFlags: detection.missingFlags } : {}),
      ...(detection.setupHints ? { setupHints: detection.setupHints } : {})
    }, 2);
  }
  return { peer, detection };
}

function runPeer({ promptName, promptSubs, payload, cwd, model, peerOverride }) {
  const { host } = requireHost();
  const { peer } = requirePeer(host, peerOverride);

  let result;
  try {
    result = peer.run({
      prompt: loadPrompt(promptName, promptSubs),
      payload,
      cwd,
      model,
      timeoutMs: 600_000,
      skipGitRepoCheck: !cwd
    });
  } catch (err) {
    if (err instanceof PayloadTooLargeError) emit({ ok: false, error: "payload_too_large", size: err.size }, 2);
    throw err;
  }

  if (result.rc !== 0) {
    const diagnostics = result.cleanupError ? { cleanupError: result.cleanupError } : {};
    if (result.outputTooLarge) {
      emit({
        ok: false, error: "peer_output_too_large", peer: peer.id, rc: result.rc,
        stderr: result.stderr, stdout: result.stdout, output: result.output, ...diagnostics
      }, 3);
    }
    if (result.modelRejected) {
      emit({
        ok: false, error: "cursor_model_unavailable", peer: peer.id, rc: result.rc,
        modelAlias: result.modelAlias, modelId: result.modelId,
        modelListCommand: result.modelListCommand,
        stderr: result.stderr, stdout: result.stdout, output: result.output, ...diagnostics
      }, 3);
    }
    if (result.strictJsonFailure) {
      emit({
        ok: false, error: "peer_failed", peer: peer.id, rc: result.rc,
        strictJsonFailure: true,
        stderr: result.stderr, stdout: result.stdout, output: result.output, ...diagnostics
      }, 3);
    }
    if (result.timedOut) {
      emit({
        ok: false, error: "peer_failed", peer: peer.id, rc: result.rc, timedOut: true,
        ...(result.apiErrorStatus ? { apiErrorStatus: result.apiErrorStatus } : {}),
        stderr: result.stderr, stdout: result.stdout, output: result.output, ...diagnostics
      }, 3);
    }
    // A momentarily saturated provider is worth exactly one more attempt, and
    // the skill cannot tell that from a genuine failure by reading prose. Say so
    // explicitly so the retry is a contract rather than a guess.
    const transient = classifyTransient(result);
    emit({
      ok: false, error: "peer_failed", peer: peer.id, rc: result.rc,
      ...(result.apiErrorStatus ? { apiErrorStatus: result.apiErrorStatus } : {}),
      ...(transient
        ? {
            retryable: true,
            retryReason: transient.retryReason,
            retryInstruction: "rerun_same_command_once"
          }
        : {}),
      stderr: result.stderr, stdout: result.stdout, output: result.output, ...diagnostics
    }, 3);
  }
  return {
    output: result.output,
    peer,
    ...(result.cleanupError ? { cleanupError: result.cleanupError } : {})
  };
}

function runReview(options) {
  const result = runPeer(options);
  const { output, peer } = result;
  const status = parseStatus(output, REVIEW_STATUSES);
  if (!status) {
    emit({
      ok: false, error: "missing_status_line", peer: peer.id, output,
      ...(result.cleanupError ? { cleanupError: result.cleanupError } : {})
    }, 4);
  }
  return { ...result, status };
}

function cmdDetect(peerOverride) {
  const h = requireHost();
  const peer = peerFor(h.host, peerOverride);
  const d = peer.detect();
  emit({
    ok: d.ok,
    host: h.host,
    hostSource: h.source,
    peer: peer.id,
    peerName: peer.displayName,
    // Every later call in this session should be spelled exactly like this, so
    // the skill never has to work out whether bin/ is on PATH.
    invocation: invocationFor(h.host),
    ...(d.ok
      ? { version: d.version, versionCheck: d.versionCheck, minimum: d.minimum }
      : {
          error: peerDetectionError(d.reason),
          ...(d.version ? { version: d.version } : {}),
          ...(d.minimum ? { minimum: d.minimum } : {}),
          ...(d.supportedVersion ? { supportedVersion: d.supportedVersion } : {}),
          ...(d.missingFlags ? { missingFlags: d.missingFlags } : {}),
          ...(d.setupHints ? { setupHints: d.setupHints } : {})
        }),
    reviewConfinement: peer.confinement(),
    // Claude Code prompts the host before it writes the review context file to
    // the temp dir; Codex has no equivalent, so the check is meaningless there.
    ...(h.host === HOST_CLAUDE_CODE ? { permissions: checkTmpWritePreapproved() } : {})
  }, d.ok ? 0 : 2);
}

function cmdNewCtx(argv) {
  const { values } = parseArgs({
    args: argv,
    options: { kind: { type: "string" } },
    allowPositionals: false
  });
  if (!["code", "plan", "consult"].includes(values.kind)) die("--kind code|plan|consult is required");
  const slug = crypto.randomBytes(8).toString("hex");
  const file = path.join(os.tmpdir(), `adversarial-${values.kind}-ctx-${slug}.txt`);
  emit({ ok: true, path: file, slug });
}

function cmdInspectRepo() {
  const cwd = process.cwd();
  if (!isInsideWorkTree(cwd)) emit({ inWorkTree: false });
  const root = repoRoot(cwd);
  const db = defaultBranch(cwd);
  const status = statusShort(cwd);
  let ahead = 0;
  let aheadError;
  if (db) {
    const r = branchAheadOf(cwd, db);
    if ("ahead" in r) ahead = r.ahead; else aheadError = r.error;
  }
  emit({
    inWorkTree: true,
    root,
    head: currentHead(cwd),
    defaultBranch: db,
    hasDirty: status.trim().length > 0,
    ahead,
    ...(aheadError ? { aheadError } : {}),
    status,
    diff: { stagedStat: diffStat(cwd, ["--cached"]), unstagedStat: diffStat(cwd, []) },
    hasSubmodules: root ? fs.existsSync(`${root}/.gitmodules`) : false
  });
}

function validateCursorModel(peerOverride, model) {
  if (peerOverride !== "cursor") return;
  const accepted = Object.keys(CURSOR_MODELS);
  if (!model || !Object.hasOwn(CURSOR_MODELS, model)) {
    die(`--model ${accepted.join("|")} is required with --peer cursor`);
  }
}

function cmdPlanReview(argv, peerOverride) {
  const { values } = parseArgs({
    args: argv,
    options: {
      "context-file": { type: "string" },
      "model": { type: "string" },
      "first": { type: "boolean" }
    },
    allowPositionals: false
  });
  validateCursorModel(peerOverride, values.model);
  if (!values["context-file"]) die("--context-file PATH is required");

  const bundle = parseBundle(readFileIf(values["context-file"]), ["PLAN", "UNRESOLVED FINDINGS", "LATEST FIXES"]);
  if (!bundle.PLAN) die("context file missing PLAN section");

  const payload = [
    "===== PLAN START =====", bundle.PLAN, "===== PLAN END =====",
    "===== UNRESOLVED FINDINGS =====",
    values.first ? "" : bundle["UNRESOLVED FINDINGS"],
    "===== END UNRESOLVED FINDINGS =====",
    "===== LATEST FIXES =====",
    values.first ? "" : bundle["LATEST FIXES"],
    "===== END LATEST FIXES ====="
  ].join("\n") + "\n";

  const { status, output, cleanupError } = runReview({
    promptName: "plan-review",
    promptSubs: { REPO_RESTRICTION: "Review ONLY the stdin payload. Do not read files from the repository." },
    payload,
    model: values.model,
    peerOverride
  });
  emit({ ok: true, status, output, ...(cleanupError ? { cleanupError } : {}) });
}

function cmdCodeReview(argv, peerOverride) {
  const { values } = parseArgs({
    args: argv,
    options: {
      "mode": { type: "string" },
      "base": { type: "string" },
      "paths": { type: "string" },
      "context-file": { type: "string" },
      "model": { type: "string" },
      "first": { type: "boolean" },
      "repo-context": { type: "boolean" },
      "self-collect": { type: "boolean" },
      "include-secrets": { type: "boolean" },
      "include-large": { type: "boolean" },
      "include-binary": { type: "boolean" },
      "allow-skipped-large": { type: "boolean" }
    },
    allowPositionals: false
  });
  validateCursorModel(peerOverride, values.model);

  if (!["uncommitted", "staged", "branch"].includes(values.mode)) {
    die("--mode uncommitted|staged|branch is required");
  }
  if (values.mode === "branch" && !values.base) die("--base REF is required for --mode branch");

  const repoContext = Boolean(values["repo-context"]);
  const selfCollect = Boolean(values["self-collect"]);
  if (selfCollect && !repoContext) die("--self-collect requires --repo-context");

  const root = repoRoot(process.cwd());
  if (!root) emit({ ok: false, error: "not_a_repo" }, 2);

  // Preflight: --repo-context grants Codex read access to the working tree
  // in a read-only sandbox that does not enforce path-scoped read
  // restrictions. The manifest-level secret exclusion in buildCodePayload is
  // not a security boundary in that mode, and prompt instructions are not a
  // security boundary either. Refuse if any secret-bearing files exist in
  // tree, unless the user has explicitly opted in via --include-secrets.
  if (repoContext && !values["include-secrets"]) {
    let secretFiles;
    try {
      secretFiles = findSecretFilesInWorkingTree(root);
    } catch (err) {
      // Fail closed. An incomplete scan reads identically to a clean one, and
      // this is the gate that decides whether the peer gets the working tree.
      emit({
        ok: false,
        error: "secret_preflight_failed",
        detail: err?.message ?? String(err),
        hint: "The secret preflight could not enumerate the working tree, so it cannot certify that no secret-bearing files exist. Re-run without --repo-context, or with --include-secrets to skip the check deliberately."
      }, 6);
    }
    if (secretFiles.length) {
      emit({
        ok: false,
        error: "secret_files_in_tree",
        files: secretFiles,
        hint: "--repo-context grants Codex read access to the working tree, but secret-bearing files exist in this repo. The Codex CLI read-only sandbox does not enforce path-scoped read restrictions. Resolve by removing/relocating these files, re-running without --repo-context, or passing --include-secrets to opt in. NOTE: this check matches filenames only, and it cannot detect credentials embedded in ordinary source or config files, and the Codex sandbox can read paths outside this repo (e.g. ~/.ssh, ~/.aws) regardless of this result."
      }, 6);
    }
  }

  const bundle = values["context-file"]
    ? parseBundle(readFileIf(values["context-file"]), ["UNRESOLVED FINDINGS", "LATEST FIXES"])
    : { "UNRESOLVED FINDINGS": "", "LATEST FIXES": "" };

  const scopePaths = values.paths ? values.paths.split(/\s+/).filter(Boolean) : [];
  let payload, skipped;
  try {
    const built = selfCollect
      ? buildCodeSelfCollectPayload({
          cwd: root,
          mode: values.mode,
          base: values.base,
          scopePaths,
          unresolved: values.first ? "" : bundle["UNRESOLVED FINDINGS"],
          latestFixes: values.first ? "" : bundle["LATEST FIXES"],
          options: { includeSecrets: Boolean(values["include-secrets"]) }
        })
      : buildCodePayload({
          cwd: root,
          mode: values.mode,
          base: values.base,
          scopePaths,
          unresolved: values.first ? "" : bundle["UNRESOLVED FINDINGS"],
          latestFixes: values.first ? "" : bundle["LATEST FIXES"],
          options: {
            includeSecrets: Boolean(values["include-secrets"]),
            includeLarge: Boolean(values["include-large"]),
            includeBinary: Boolean(values["include-binary"])
          }
        });
    payload = built.payload;
    skipped = built.skipped;
  } catch (err) {
    // `error` is the stable code the SKILLs match on, so the reason text belongs
    // in `detail`. Emitting err.message as the code put free-form prose where a
    // documented code was promised.
    emit({
      ok: false,
      error: err?.code ?? "payload_build_failed",
      detail: err?.message ?? String(err)
    }, 3);
  }

  // Fail closed on large-file skips so the caller sees them before Codex runs
  // on an incomplete payload. Opt in via --include-large to include their
  // contents, or --allow-skipped-large to knowingly proceed without them.
  // Self-collect mode never bundles file contents, so this gate doesn't apply.
  if (!selfCollect) {
    const largeSkipped = skipped.filter((s) => /^large (tracked|untracked)/.test(s));
    if (largeSkipped.length && !values["include-large"] && !values["allow-skipped-large"]) {
      emit({
        ok: false,
        error: "large_files_skipped",
        skipped,
        largeSkipped,
        hint: "Pass --include-large to review these files, or --allow-skipped-large to proceed without them."
      }, 5);
    }
  }

  const repoCollectionRules = selfCollect
    ? "\n\n<repo_collection_rules>\nFor this code review, the stdin payload is a compact review target, not the full diff. Inspect the repository and relevant git state directly before finalizing findings. Use the payload to understand the intended review scope, changed-file snapshot, and iteration context. Stay within the requested review target and explicit path scope if one was provided. Do not inspect known secret-bearing files unless the review explicitly opted into them. Prefer reading the affected files, related call sites, and targeted diffs yourself over asking for more payload.\n</repo_collection_rules>"
    : "";

  const { status, output, cleanupError } = runReview({
    promptName: "code-review",
    promptSubs: {
      REPO_RESTRICTION: repoContext
        ? "You may read repository files to supplement your review. Ground findings primarily in the provided payload."
        : "Review ONLY the stdin payload. Do not read files from the repository.",
      REPO_COLLECTION_RULES: repoCollectionRules
    },
    payload,
    cwd: repoContext ? root : undefined,
    model: values.model,
    peerOverride
  });
  emit({ ok: true, status, output, skipped, ...(cleanupError ? { cleanupError } : {}) });
}

function hasRecommendationLine(output) {
  let first = String(output ?? "").split(/\r?\n/).find((line) => line.trim());
  if (!first) return false;
  first = first.trim().replace(/^(?:#{1,6}|[-+*])\s+/, "");
  return /^(?:\*\*|__|\*|_|`)?recommendation(?:\*\*|__|\*|_|`)?\s*:\s*(?:\*\*|__|\*|_|`)?/i.test(first);
}

function cmdConsult(argv, peerOverride) {
  const { values } = parseArgs({
    args: argv,
    options: {
      "context-file": { type: "string" },
      "model": { type: "string" }
    },
    allowPositionals: false
  });
  validateCursorModel(peerOverride, values.model);
  if (!values["context-file"]) die("--context-file PATH is required");

  const bundle = parseBundle(
    readFileIf(values["context-file"]),
    ["QUESTION", "CONTEXT", "CANDIDATE APPROACHES"]
  );
  if (!bundle.QUESTION) die("context file missing QUESTION section");

  const sections = [
    ["QUESTION", bundle.QUESTION],
    ["CONTEXT", bundle.CONTEXT],
    ["CANDIDATE APPROACHES", bundle["CANDIDATE APPROACHES"]]
  ].filter(([, body]) => body);
  const payload = sections.flatMap(([label, body]) => [
    `===== ${label} START =====`, body, `===== ${label} END =====`
  ]).join("\n") + "\n";

  const { output, peer, cleanupError } = runPeer({
    promptName: "consult",
    payload,
    model: values.model,
    peerOverride
  });
  if (!hasRecommendationLine(output)) {
    emit({
      ok: false, error: "missing_recommendation_line", peer: peer.id, output,
      ...(cleanupError ? { cleanupError } : {})
    }, 4);
  }
  emit({ ok: true, peer: peer.id, output, ...(cleanupError ? { cleanupError } : {}) });
}

// `--host` is global rather than per-subcommand: it answers "who is driving
// this run", which is orthogonal to what the subcommand does. Strip it before
// dispatch so no subcommand parser has to declare it.
function extractGlobalFlags(argv) {
  const out = [];
  let host;
  let peer;
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--host") { host = argv[++i]; continue; }
    if (a?.startsWith("--host=")) { host = a.slice("--host=".length); continue; }
    if (a === "--peer") {
      peer = argv[++i];
      if (!peer) die("--peer cursor is required");
      if (peer !== "cursor") die(`unknown peer '${peer}'`);
      continue;
    }
    if (a?.startsWith("--peer=")) {
      peer = a.slice("--peer=".length);
      if (!peer) die("--peer cursor is required");
      if (peer !== "cursor") die(`unknown peer '${peer}'`);
      continue;
    }
    out.push(a);
  }
  return { host, peer, argv: out };
}

const cli = extractGlobalFlags(process.argv.slice(2));
const HOST_OVERRIDE = cli.host;
const PEER_OVERRIDE = cli.peer;
const [sub, ...rest] = cli.argv;
try {
  dispatch(sub, rest);
} catch (err) {
  // parseArgs throws on unknown/malformed flags, and fs calls can throw for
  // reasons we have not enumerated. Either way the caller gets JSON. A bad flag
  // is a usage error, not a crash, so it must not be labelled as one. Every
  // ERR_PARSE_ARGS_* code means the caller mis-spelled the invocation.
  const usageError = typeof err?.code === "string" && err.code.startsWith("ERR_PARSE_ARGS_");
  emit({
    ok: false,
    error: usageError ? "invalid_usage" : "unhandled_exception",
    detail: err?.message ?? String(err)
  }, 1);
}

function dispatch(sub, rest) {
switch (sub) {
  case undefined:
  case "-h":
  case "--help":
    process.stdout.write(usage() + "\n");
    break;
  case "detect": cmdDetect(PEER_OVERRIDE); break;
  case "inspect-repo": cmdInspectRepo(); break;
  case "new-ctx": cmdNewCtx(rest); break;
  case "plan-review": cmdPlanReview(rest, PEER_OVERRIDE); break;
  case "code-review": cmdCodeReview(rest, PEER_OVERRIDE); break;
  case "consult": cmdConsult(rest, PEER_OVERRIDE); break;
  default: die(`unknown subcommand '${sub}'\n\n${usage()}`);
}
}
