import fs from "node:fs";
import { runSync } from "./process.mjs";

// Secret-file exclusion policy. Mirrors the bash wrapper's patterns so the
// allowed-file set stays consistent across iterations.

// Git pathspec prefilter. Deliberately NOT a mirror of SECRET_RE: a pathspec
// cannot express SECRET_ALLOWLIST_RE, so anything excluded here could never be
// allowed back through, and `.env` is omitted for exactly that reason. Treat
// this list as a cheap first pass only. isSecretPath is the authority, and every
// candidate pathname must pass through it. `:(icase)` mirrors the regex's
// case-insensitivity, so `.PEM` is excluded too.
const SECRET_PATHSPECS = [
  ":(icase):!*.pem",
  ":(icase):!*.key",
  ":(icase):!*.p12",
  ":(icase):!*.pfx",
  ":(icase):!*.jks",
  ":(icase):!*.keystore",
  ":(icase):!*.ovpn",
  ":(icase):!*.tfvars",
  ":(icase):!kubeconfig*",
  ":(icase):!**/secret.yml",
  ":(icase):!**/secret.yaml",
  ":(icase):!**/secrets.yml",
  ":(icase):!**/secrets.yaml",
  ":(icase):!**/vault.yml",
  ":(icase):!**/vault.yaml",
  ":(icase):!**/id_rsa",
  ":(icase):!**/id_dsa",
  ":(icase):!**/id_ecdsa",
  ":(icase):!**/id_ed25519",
  ":(icase):!**/.npmrc",
  ":(icase):!**/.netrc",
  ":(icase):!**/_netrc",
  ":(icase):!**/.pypirc",
  ":(icase):!**/.pgpass",
  ":(icase):!**/.git-credentials",
  ":(icase):!**/credentials",
  ":(icase):!**/credentials.json",
  ":(icase):!**/service-account*.json",
  ":(icase):!**/htpasswd",
  ":(icase):!**/.htpasswd"
];

// Filename-level secret detection. NOTE: this is a filename heuristic, not a
// content scanner: a token pasted into an ordinary source file will not be
// caught. See findSecretFilesInWorkingTree's caveat.
//
// Covers: env files; key/cert archives; SSH private keys; cloud and package
// registry credential files; kubeconfigs; Kubernetes secret manifests (both
// `secret.yaml` and `secrets.yaml`, since the singular form is the conventional
// manifest name); Vault configs; Terraform variable files.
const SECRET_RE = new RegExp(
  [
    "(^|/)\\.env($|\\.)",
    "\\.(pem|key|p12|pfx|jks|keystore|ovpn|tfvars)$",
    "(^|/)id_(rsa|dsa|ecdsa|ed25519)$",
    "(^|/)(\\.npmrc|\\.netrc|_netrc|\\.pypirc|\\.pgpass|\\.git-credentials)$",
    "(^|/)credentials(\\.json)?$",
    "(^|/)service-account[^/]*\\.json$",
    "(^|/)\\.?htpasswd$",
    "kubeconfig",
    "(^|/)secrets?\\.ya?ml$",
    "(^|/)vault\\.ya?ml$"
  ].join("|"),
  "i"
);

// Allowlist for filenames that match the broad secret pattern but are known
// templates carrying no real values.
const SECRET_ALLOWLIST_RE =
  /(^|\/)(\.env|.*\.tfvars|credentials|.*\.ya?ml)\.(example|sample|dist|default|template)$|\.(example|sample|template)$/i;

export function secretPathspecs({ includeSecrets }) {
  return includeSecrets ? [] : SECRET_PATHSPECS;
}

export function isSecretPath(path, { includeSecrets }) {
  if (includeSecrets) return false;
  if (!SECRET_RE.test(path)) return false;
  if (SECRET_ALLOWLIST_RE.test(path)) return false;
  return true;
}

// Preflight scan for --repo-context mode. The Codex CLI's read-only sandbox
// does not enforce path-scoped read restrictions, so the manifest-level
// secret exclusion alone is not a security boundary when Codex is given
// repo access. Walks tracked + untracked (incl. gitignored) files in the
// superproject and every checked-out submodule, returning sorted unique
// matches against the secret pattern (allowlist applied).
export function findSecretFilesInWorkingTree(root) {
  const all = new Set();

  // `--others` without `--exclude-standard` lists every untracked path,
  // including those in .gitignore, so gitignored .env files still surface.
  //
  // A scan that cannot enumerate the tree must never report "no secrets found",
  // so an unreadable listing throws rather than contributing nothing. Every
  // other runSync caller in this codebase guards on status; this one did not,
  // and a null stdout crashed with a TypeError instead of a stated reason.
  for (const args of [["ls-files", "--cached"], ["ls-files", "--others"]]) {
    const r = runSync("git", args, { cwd: root });
    if (r.status !== 0) throw new Error(`git ${args.join(" ")} failed in ${root}`);
    for (const f of (r.stdout ?? "").split(/\r?\n/)) if (f) all.add(f);
  }

  if (fs.existsSync(`${root}/.gitmodules`)) {
    // `git submodule foreach` iterates every checked-out submodule (active
    // or not) and we explicitly list cached + untracked inside each. The
    // `--recurse-submodules` flag on `ls-files` only walks ACTIVE
    // submodules and only supports cached/stage modes, which is why the
    // bash version used `submodule foreach` and we mirror that here.
    const sub = runSync(
      "git",
      [
        "submodule", "foreach", "--recursive", "--quiet",
        'git ls-files --cached --others 2>/dev/null | sed "s|^|${displaypath}/|"'
      ],
      { cwd: root }
    );
    if (sub.status !== 0) throw new Error(`git submodule foreach ls-files failed in ${root}`);
    for (const f of (sub.stdout ?? "").split(/\r?\n/)) if (f) all.add(f);
  }

  const found = [];
  for (const f of all) {
    if (isSecretPath(f, { includeSecrets: false })) found.push(f);
  }
  found.sort();
  return found;
}
