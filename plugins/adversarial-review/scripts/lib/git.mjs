import { runSync } from "./process.mjs";

export function isInsideWorkTree(cwd) {
  const r = runSync("git", ["rev-parse", "--is-inside-work-tree"], { cwd });
  return r.status === 0 && r.stdout.trim() === "true";
}

export function repoRoot(cwd) {
  const r = runSync("git", ["rev-parse", "--show-toplevel"], { cwd });
  return r.status === 0 ? r.stdout.trim() : null;
}

export function hasHead(cwd) {
  return runSync("git", ["rev-parse", "HEAD"], { cwd }).status === 0;
}

export function currentHead(cwd) {
  const r = runSync("git", ["rev-parse", "HEAD"], { cwd });
  return r.status === 0 ? r.stdout.trim() : null;
}

// Returns a ref that's usable in `git rev-list base..HEAD` and `git merge-base base HEAD`.
// Prefers a local branch (`main`/`master`) so the pretty name is what the user expects,
// but falls back to a remote-tracking ref (`origin/main`) when the local branch is absent.
// Returns null when no default branch is discoverable at all.
export function defaultBranch(cwd) {
  const sym = runSync("git", ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], { cwd });
  if (sym.status === 0) {
    const full = sym.stdout.trim(); // e.g. "origin/main"
    const short = full.replace(/^origin\//, "");
    const localHas = runSync("git", ["rev-parse", "--verify", "--quiet", short], { cwd });
    if (localHas.status === 0) return short;
    const remoteHas = runSync("git", ["rev-parse", "--verify", "--quiet", full], { cwd });
    if (remoteHas.status === 0) return full;
  }
  for (const name of ["main", "master"]) {
    const local = runSync("git", ["rev-parse", "--verify", "--quiet", name], { cwd });
    if (local.status === 0) return name;
    const remote = runSync("git", ["rev-parse", "--verify", "--quiet", `origin/${name}`], { cwd });
    if (remote.status === 0) return `origin/${name}`;
  }
  return null;
}

export function mergeBase(cwd, baseRef) {
  const r = runSync("git", ["merge-base", baseRef, "HEAD"], { cwd });
  return r.status === 0 ? r.stdout.trim() : null;
}

export function statusShort(cwd) {
  const r = runSync("git", ["status", "--short", "--untracked-files=all"], { cwd });
  return r.status === 0 ? r.stdout : "";
}

export function diffStat(cwd, args = []) {
  const r = runSync("git", ["diff", "--stat", ...args], { cwd });
  return r.status === 0 ? r.stdout : "";
}

// Returns { ahead: number } on success, or { error: string } when rev-list fails
// (e.g. unknown ref). Callers decide whether that should surface to the user.
export function branchAheadOf(cwd, base) {
  const r = runSync("git", ["rev-list", "--count", `${base}..HEAD`], { cwd });
  if (r.status !== 0) return { error: (r.stderr || "").trim() || "rev-list failed" };
  return { ahead: parseInt(r.stdout.trim(), 10) || 0 };
}
