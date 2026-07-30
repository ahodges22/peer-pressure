// Claude Code host-side permission pre-approval check.
//
// Only meaningful when the host is Claude Code: it governs whether the *host*
// gets a permission prompt while writing the review context file to the system
// temp dir. Codex has no equivalent, so this is skipped there.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";

// Claude Code checks file permissions against `Edit(path)` and `Read(path)`
// rules ONLY. A `Write(path)` rule is accepted, never consulted, and warned
// about at startup — `Edit` rules cover all file-editing tools including Write.
// This plugin recommended the `Write(...)` form until it was found to be inert
// as of Claude Code 2.1.210; legacy rules are detected below so users can be
// told to migrate rather than silently getting prompts they thought they had
// suppressed.
//
// The leading `//` is required: a single `/` anchors at the settings source
// (the project root for project settings), not the filesystem root.
function allowPatterns(dir) {
  return [`Edit(/${dir}/*)`, `Edit(/${dir}/**)`];
}

function legacyPatterns(dir) {
  return [`Write(/${dir}/*)`, `Write(/${dir}/**)`];
}

export function checkTmpWritePreapproved() {
  const settingsPath = path.join(os.homedir(), ".claude", "settings.json");
  const checked = [settingsPath];
  const tmpdir = os.tmpdir();
  const dir = tmpdir.replace(/\/+$/, "");
  const accepted = allowPatterns(dir);
  const legacy = legacyPatterns(dir);
  // Recommend the `**` form — it covers every file under tmpdir.
  const expected_rule = accepted[1];

  try {
    const raw = fs.readFileSync(settingsPath, "utf8");
    const cfg = JSON.parse(raw);
    const allow = cfg?.permissions?.allow;
    const list = Array.isArray(allow) ? allow : [];
    const preapproved = list.some((e) => accepted.includes(e));
    const legacyRules = list.filter((e) => legacy.includes(e));
    return {
      tmp_write_preapproved: preapproved,
      checked,
      expected_rule,
      tmpdir,
      ...(legacyRules.length && !preapproved
        ? {
            legacy_write_rules: legacyRules,
            legacy_hint:
              `Found ${legacyRules.join(", ")} in permissions.allow. Claude Code never ` +
              `consults Write(path) rules — only Edit(path) and Read(path). Replace it ` +
              `with ${expected_rule}.`
          }
        : {})
    };
  } catch {
    // ENOENT, parse error, or perms — caller treats as "not pre-approved".
    return { tmp_write_preapproved: false, checked, expected_rule, tmpdir };
  }
}
