import fs from "node:fs";
import { runSync } from "./process.mjs";
import { hasHead, mergeBase } from "./git.mjs";
import { secretPathspecs, isSecretPath } from "./secrets.mjs";

const MAX_FILE_BYTES = 100 * 1024;

function scopeArgs(scopePaths) {
  return scopePaths.length ? scopePaths : ["."];
}

// Batch-resolve sizes for `<ref>:<file>` specs via a single `git cat-file --batch-check`.
// Returns Map<file, size>. Missing/deleted entries are omitted.
//
// `%(rest)` is empty for rev-parse specs (as opposed to bare SHAs), so we associate
// output lines with input files by position — one output line per input line.
function batchCatFileSizes(cwd, sizeRef, files) {
  if (!files.length) return new Map();
  const input = files.map((f) => `${sizeRef}:${f}`).join("\n") + "\n";
  const r = runSync("git", ["cat-file", "--batch-check=%(objectsize)"], { cwd, input });
  const sizes = new Map();
  if (r.status !== 0) return sizes;
  const lines = r.stdout.split("\n");
  for (let i = 0; i < files.length; i++) {
    const line = lines[i] ?? "";
    if (line.endsWith("missing") || !line) continue;
    const size = parseInt(line, 10);
    if (!Number.isNaN(size)) sizes.set(files[i], size);
  }
  return sizes;
}

// Batch-classify files as binary via a single `file --mime` call.
// Returns Set<file> containing binary entries.
function batchDetectBinary(cwd, files) {
  const binary = new Set();
  if (!files.length) return binary;
  const r = runSync("file", ["--mime", "--", ...files], { cwd });
  if (r.status !== 0) return binary;
  for (const line of r.stdout.split(/\r?\n/)) {
    if (!line) continue;
    // Format: "<file>: <mime-type>; charset=<x>"
    const idx = line.lastIndexOf(":");
    if (idx === -1) continue;
    const file = line.slice(0, idx);
    if (/charset=binary/.test(line)) binary.add(file);
  }
  return binary;
}

// Size of the file as it currently sits in the working tree, or 0 if absent
// (deleted in the worktree, or a symlink we shouldn't follow).
function worktreeSize(cwd, file) {
  try {
    const st = fs.lstatSync(`${cwd}/${file}`);
    return st.isFile() ? st.size : 0;
  } catch {
    return 0;
  }
}

// Plain `--numstat` collapses a rename into ONE formatted field —
// `cfg/{.env.example => .env}` — which is neither real pathname. That string
// matches no secret pattern, so renaming an allowlisted template onto a real
// secret path smuggled its contents straight into the payload. It also made
// every size lookup miss, defaulting the file to 0 bytes.
//
// `-z` emits records as `added\tremoved\t<path>\0` normally, and
// `added\tremoved\t\0<preimage>\0<postimage>\0` for renames and copies. Parse
// that and carry BOTH pathnames so either side can trip an exclusion.
function parseNumstatZ(out) {
  const rows = [];
  const tokens = (out ?? "").split("\0");
  for (let i = 0; i < tokens.length; i++) {
    const m = /^(\S+)\t(\S+)\t([\s\S]*)$/.exec(tokens[i] ?? "");
    if (!m) continue;
    const [, added, removed, inline] = m;
    if (inline) {
      rows.push({ added, removed, file: inline, paths: [inline] });
    } else {
      const from = tokens[++i];
      const to = tokens[++i];
      if (!to) continue;
      rows.push({ added, removed, file: to, paths: [from, to].filter(Boolean) });
    }
  }
  return rows;
}

function trackedExclusions({ cwd, diffArgs, paths, scopePaths, sizeRef, options, newSideIsWorktree }) {
  const r = runSync(
    "git",
    ["diff", "--numstat", "-z", ...diffArgs, "--", ...scopeArgs(scopePaths), ...paths],
    { cwd }
  );
  if (r.status !== 0) return { skip: [], skippedLog: [] };

  const rows = parseNumstatZ(r.stdout);

  // Batch size lookup for tracked files, since `git cat-file -s` per file is O(N) spawns.
  const sizedFiles = options.includeLarge
    ? []
    : rows.filter((r) => !(r.added === "-" && r.removed === "-")).map((r) => r.file);
  const sizes = batchCatFileSizes(cwd, sizeRef, sizedFiles);

  const skip = [];
  const skippedLog = [];
  for (const { added, removed, file, paths } of rows) {
    // Either side of a rename can be the secret. Exclude both pathnames so the
    // diff cannot be reintroduced through the one we didn't name.
    const secretSide = paths.find((p) => isSecretPath(p, { includeSecrets: options.includeSecrets }));
    if (secretSide) {
      for (const p of paths) skip.push(`:!${p}`);
      skippedLog.push(`secret: ${secretSide}`);
      continue;
    }
    if (added === "-" && removed === "-") {
      if (!options.includeBinary) {
        skip.push(`:!${file}`);
        skippedLog.push(`binary tracked: ${file}`);
      }
      continue;
    }
    if (!options.includeLarge) {
      // The payload carries BOTH sides of the diff, so the cap must consider
      // whichever is bigger. Sizing only the base blob let a file that was 6
      // bytes at HEAD and is now 200KB in the worktree sail past the cap — the
      // exact case the guard exists to catch. `--cached` diffs end at the index
      // blob, which `sizeRef` already measures, so they skip the stat.
      const baseSize = sizes.get(file) ?? 0;
      const newSize = newSideIsWorktree ? worktreeSize(cwd, file) : 0;
      const size = Math.max(baseSize, newSize);
      if (size > MAX_FILE_BYTES) {
        skip.push(`:!${file}`);
        skippedLog.push(`large tracked (${size}B): ${file}`);
      }
    }
  }
  return { skip, skippedLog };
}

function untrackedFilesInScope({ cwd, scopePaths }) {
  const r = runSync("git", ["ls-files", "--others", "--exclude-standard"], { cwd });
  if (r.status !== 0) return [];
  const all = r.stdout.split(/\r?\n/).filter(Boolean);
  if (!scopePaths.length) return all;
  return all.filter((f) => scopePaths.some((p) => {
    const trimmed = p.replace(/\/$/, "");
    return f === trimmed || f.startsWith(`${trimmed}/`);
  }));
}

// For each untracked file: decide keep/skip using batched binary + stat lookups,
// then emit a /dev/null -> +content diff block for the kept text files.
function appendUntracked({ cwd, files, options, skippedLog }) {
  if (!files.length) return "";

  // Pre-filter secrets and symlinks; also stat once to get size + symlink bit.
  const candidates = [];
  for (const f of files) {
    if (isSecretPath(f, { includeSecrets: options.includeSecrets })) {
      skippedLog.push(`secret: ${f}`);
      continue;
    }
    let stat;
    try {
      stat = fs.lstatSync(`${cwd}/${f}`);
    } catch {
      continue;
    }
    if (stat.isSymbolicLink()) {
      skippedLog.push(`symlink: ${f}`);
      continue;
    }
    candidates.push({ file: f, size: stat.size });
  }

  const binaryFiles = batchDetectBinary(cwd, candidates.map((c) => c.file));

  const parts = [];
  for (const { file, size } of candidates) {
    if (binaryFiles.has(file)) {
      if (options.includeBinary) {
        const r = runSync("git", ["diff", "--no-index", "--binary", "/dev/null", file], { cwd });
        if (r.stdout) parts.push(r.stdout);
      } else {
        skippedLog.push(`binary untracked: ${file}`);
      }
      continue;
    }
    if (!options.includeLarge && size > MAX_FILE_BYTES) {
      skippedLog.push(`large untracked: ${file}`);
      continue;
    }
    const content = fs.readFileSync(`${cwd}/${file}`, "utf8");
    const prefixed = content.split("\n").map((l) => `+${l}`).join("\n");
    parts.push(`--- /dev/null\n+++ b/${file}\n${prefixed}`);
  }
  return parts.join("\n");
}

function contextBlock({ unresolved, latestFixes }) {
  return [
    "===== UNRESOLVED FINDINGS =====",
    (unresolved ?? "").trim(),
    "===== END UNRESOLVED FINDINGS =====",
    "===== LATEST FIXES =====",
    (latestFixes ?? "").trim(),
    "===== END LATEST FIXES ====="
  ].join("\n");
}

// Emit the tracked-diff portion for a single `git diff` invocation pair
// (compute size/binary exclusions first, then run the actual diff with `:!...` pathspecs).
function emitTrackedDiff({ cwd, diffArgs, sizeRef, scopePaths, secretExcludes, options, skippedLog, newSideIsWorktree = false }) {
  const { skip, skippedLog: log } = trackedExclusions({
    cwd, diffArgs, paths: secretExcludes, scopePaths, sizeRef, options, newSideIsWorktree
  });
  skippedLog.push(...log);
  const r = runSync(
    "git",
    ["diff", ...diffArgs, "--", ...scopeArgs(scopePaths), ...secretExcludes, ...skip],
    { cwd }
  );
  return r.stdout ?? "";
}

export function buildCodePayload({
  cwd,
  mode,
  base,
  scopePaths = [],
  unresolved = "",
  latestFixes = "",
  options = { includeSecrets: false, includeLarge: false, includeBinary: false }
}) {
  const skippedLog = [];
  const secretExcludes = secretPathspecs(options);
  const parts = ["===== CHANGES START ====="];
  const shared = { cwd, scopePaths, secretExcludes, options, skippedLog };

  if (mode === "uncommitted") {
    if (hasHead(cwd)) {
      parts.push(emitTrackedDiff({ ...shared, diffArgs: ["HEAD"], sizeRef: "HEAD", newSideIsWorktree: true }));
    } else {
      parts.push(emitTrackedDiff({ ...shared, diffArgs: ["--cached"], sizeRef: ":0" }));
      // No HEAD exists on this branch, so sizes must be resolved against the
      // index (`:0`). Using "HEAD" here made every `cat-file` lookup fail, so
      // sizes defaulted to 0 for this pass.
      parts.push(emitTrackedDiff({ ...shared, diffArgs: [], sizeRef: ":0", newSideIsWorktree: true }));
    }
    parts.push(appendUntracked({ cwd, files: untrackedFilesInScope({ cwd, scopePaths }), options, skippedLog }));
  } else if (mode === "staged") {
    parts.push(emitTrackedDiff({ ...shared, diffArgs: ["--cached"], sizeRef: ":0" }));
  } else if (mode === "branch") {
    const mb = mergeBase(cwd, base);
    if (!mb) throw new Error(`merge-base not found for '${base}'`);
    parts.push(emitTrackedDiff({ ...shared, diffArgs: [mb], sizeRef: mb, newSideIsWorktree: true }));
    parts.push(appendUntracked({ cwd, files: untrackedFilesInScope({ cwd, scopePaths }), options, skippedLog }));
  } else {
    throw new Error(`unknown mode '${mode}'`);
  }

  parts.push("===== CHANGES END =====");
  parts.push(contextBlock({ unresolved, latestFixes }));
  // The no-HEAD path runs two diff passes over an overlapping file set, so the
  // same exclusion can be logged twice. Callers surface this list to the user.
  return { payload: parts.filter(Boolean).join("\n") + "\n", skipped: [...new Set(skippedLog)] };
}

function changedFilenamesForMode({ cwd, mode, base, scopePaths, secretExcludes }) {
  const scope = scopeArgs(scopePaths);
  const args = (diffArgs) => ["diff", "--name-only", ...diffArgs, "--", ...scope, ...secretExcludes];
  const out = new Set();

  const collect = (text) => {
    for (const line of text.split(/\r?\n/)) if (line) out.add(line);
  };

  if (mode === "uncommitted") {
    if (hasHead(cwd)) {
      collect(runSync("git", args(["HEAD"]), { cwd }).stdout);
    } else {
      collect(runSync("git", args(["--cached"]), { cwd }).stdout);
      collect(runSync("git", args([]), { cwd }).stdout);
    }
    for (const f of untrackedFilesInScope({ cwd, scopePaths })) {
      if (!isSecretPath(f, { includeSecrets: false })) out.add(f);
    }
  } else if (mode === "staged") {
    collect(runSync("git", args(["--cached"]), { cwd }).stdout);
  } else if (mode === "branch") {
    const mb = mergeBase(cwd, base);
    if (!mb) throw new Error(`merge-base not found for '${base}'`);
    collect(runSync("git", args([mb]), { cwd }).stdout);
    for (const f of untrackedFilesInScope({ cwd, scopePaths })) {
      if (!isSecretPath(f, { includeSecrets: false })) out.add(f);
    }
  } else {
    throw new Error(`unknown mode '${mode}'`);
  }

  return [...out].sort();
}

// Compact "self-collect" payload: instead of bundling the full diff, ship a
// manifest (mode, scope, secret-handling stance, changed-file snapshot) and
// rely on Codex's --repo-context read access to pull what it needs. Saves
// tokens for large diffs at the cost of leaving file inspection up to Codex.
//
// Only valid alongside --repo-context. Caller must enforce that.
export function buildCodeSelfCollectPayload({
  cwd,
  mode,
  base,
  scopePaths = [],
  unresolved = "",
  latestFixes = "",
  options = { includeSecrets: false }
}) {
  const secretExcludes = secretPathspecs(options);
  const files = changedFilenamesForMode({ cwd, mode, base, scopePaths, secretExcludes });

  const lines = ["===== CHANGES START ====="];
  lines.push("Compact review target for repo-backed code review.");

  if (mode === "uncommitted") {
    lines.push("Mode: working-tree");
    lines.push("Inspect the repository directly. Review staged changes, unstaged changes, and reviewable untracked files in scope.");
  } else if (mode === "staged") {
    lines.push("Mode: staged-only");
    lines.push("Inspect the repository directly. Review staged changes only.");
  } else if (mode === "branch") {
    const mb = mergeBase(cwd, base);
    if (!mb) throw new Error(`merge-base not found for '${base}'`);
    lines.push("Mode: branch comparison");
    lines.push(`Base ref: ${base}`);
    lines.push(`Merge-base: ${mb}`);
    lines.push("Inspect the repository directly. Review current changes relative to the merge-base and reviewable untracked files in scope.");
  } else {
    throw new Error(`unknown mode '${mode}'`);
  }

  lines.push(`Scope: ${scopePaths.length ? scopePaths.join(" ") : "all changed files"}`);
  lines.push(options.includeSecrets
    ? "Secret handling: explicit opt-in enabled."
    : "Secret handling: do not inspect known secret-bearing files unless explicitly opted in.");
  lines.push("");
  lines.push("Initial changed file snapshot:");
  if (files.length === 0) {
    lines.push("- (none detected in initial snapshot; inspect the target directly before approving)");
  } else {
    for (const f of files) lines.push(`- ${f}`);
  }
  lines.push("===== CHANGES END =====");
  lines.push(contextBlock({ unresolved, latestFixes }));
  return { payload: lines.join("\n") + "\n", skipped: [] };
}
