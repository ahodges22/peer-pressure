#!/usr/bin/env bash
# Smoke tests for the adversarial-review runtime.
#
# Hermetic: fake peer CLIs in tests/bin are prepended to PATH, so no test
# spends tokens, needs auth, or touches the network. Run from anywhere:
#
#   tests/run-tests.sh
#
# Every fixture sets GIT_CONFIG_GLOBAL=/dev/null. A developer's global gitignore
# can otherwise make secret-exclusion assertions pass without exercising the
# expected path.
# NOT pipefail: nearly every assertion here exercises an error path, where the
# runtime deliberately exits non-zero (die → 1, large_files_skipped → 5,
# secret_files_in_tree → 6, ...). Under pipefail, `cli ... | grep -q`
# reports the runtime's exit status rather than grep's, so a matching assertion
# still evaluates false and every error-path test silently "fails".
set -u

TESTS_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$TESTS_DIR/.." && pwd)"
CLI_JS="$REPO_ROOT/plugins/adversarial-review/scripts/orchestration.mjs"

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null
export PATH="$TESTS_DIR/bin:$PATH"   # shadows the real `codex`/`claude` so no test spends tokens

# Host detection reads the environment, so an unpinned suite behaves differently
# depending on where it runs: CLAUDECODE is set when a developer runs it from
# inside Claude Code, and NEITHER marker is set in CI — where every test would
# then fail with unknown_host. Pin the host for the bulk of the suite; the
# host-detection group below overrides these deliberately, per invocation.
unset CLAUDECODE CODEX_THREAD_ID
export ADVERSARIAL_REVIEW_HOST=claude-code

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no(){ printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
group(){ printf '\n== %s ==\n' "$1"; }

cli(){ node "$CLI_JS" "$@" 2>&1; }

# Fresh git repo with one commit; echoes its path.
newrepo(){
  local d="$WORK/$1"
  mkdir -p "$d"
  git -C "$d" init -q -b main .
  git -C "$d" config user.email t@example.com
  git -C "$d" config user.name  t
  echo seed > "$d/seed.txt"
  git -C "$d" add seed.txt
  git -C "$d" commit -q -m init
  echo "$d"
}

# --------------------------------------------------- review skill host parity
group "review skill user check-ins work on both hosts"
for skill in \
  "$REPO_ROOT/plugins/adversarial-review/skills/plan-review/SKILL.md" \
  "$REPO_ROOT/plugins/adversarial-review/skills/code-review/SKILL.md"
do
  name=$(basename "$(dirname "$skill")")
  grep -q '## User decision prompts (host-specific)' "$skill" \
    && grep -q 'Claude Code.*AskUserQuestion' "$skill" \
    && grep -q 'Codex.*request_user_input' "$skill" \
    && grep -q 'ask one clear plain-text question' "$skill" \
    && ok "$name defines a host-specific prompt contract" \
    || no "$name lacks a complete host-specific prompt contract"

  grep -q 'Every user prompt.*AskUserQuestion\|call the `AskUserQuestion` tool' "$skill" \
    && no "$name still requires the Claude-only prompt tool" \
    || ok "$name has no unconditional AskUserQuestion dependency"
done

# --------------------------------------------------------- README contract
group "README matches the shipped review workflow"
ROOT_README="$REPO_ROOT/README.md"
PLUGIN_README="$REPO_ROOT/plugins/adversarial-review/README.md"

grep -q 'Node.js 20+' "$ROOT_README" \
  && grep -q 'Codex CLI 0.125.0+' "$ROOT_README" \
  && grep -q 'Claude Code 2.0.0+' "$ROOT_README" \
  && ok "README states the enforced runtime and CLI floors" \
  || no "README runtime or CLI floors are stale"

grep -q 'Scope / Out of scope' "$ROOT_README" \
  && grep -q 'more than 50%' "$ROOT_README" \
  && grep -q 'host-native prompt' "$ROOT_README" \
  && grep -q 'more than 50%' "$PLUGIN_README" \
  && ok "README documents scope and host-neutral checkpoints" \
  || no "README omits current scope or checkpoint behavior"

grep -q 'do not send a review or consume model tokens' "$ROOT_README" \
  && ok "README describes local-only commands accurately" \
  || no "README local-only command description is stale"

if grep -Eq '^## (Safety|Troubleshooting)$' "$ROOT_README" "$PLUGIN_README"; then
  no "removed README sections returned"
elif grep -q '—' "$ROOT_README" "$PLUGIN_README"; then
  no "README contains an em dash"
else
  ok "README has no removed sections or em dashes"
fi

# ---------------------------------------------------------------- version floor
group "peer version floor"
R=$(newrepo vf); cd "$R"
FAKE_CODEX_VERSION=0.124.0 cli detect | grep -q '"reason": "too_old"\|peer_too_old' \
  && ok "0.124.0 rejected" || no "old codex not rejected"
FAKE_CODEX_VERSION=0.125.0 cli detect | grep -q '"ok": true' \
  && ok "0.125.0 accepted (floor is inclusive)" || no "floor version rejected"
FAKE_CODEX_VERSION=0.145.0 cli detect | grep -q '"versionCheck": "ok"' \
  && ok "current version reports versionCheck ok" || no "versionCheck missing"
FAKE_CODEX_VERSION="nightly-abc" cli detect | grep -q '"versionCheck": "unparsed"' \
  && ok "unparseable version allowed but flagged" || no "dev build handling wrong"
# A well-formed plan bundle, so the version gate is what trips — not input validation.
printf '===== PLAN START =====\nship the thing\n===== PLAN END =====\n' > "$WORK/plan-ctx.txt"
out=$(FAKE_CODEX_VERSION=0.100.0 cli plan-review --context-file "$WORK/plan-ctx.txt")
echo "$out" | grep -q 'peer_too_old' && ok "review path surfaces peer_too_old" \
  || no "review path did not gate on version: $(echo "$out" | head -2)"

# ------------------------------------------------------------ large-file guard
group "large-file guard sizes both sides of the diff"
R=$(newrepo lf); cd "$R"
printf 'tiny\n' > grew.txt; git add grew.txt; git commit -q -m small
python3 -c "print('x'*200000)" > grew.txt          # small at HEAD, huge in worktree
cli code-review --mode uncommitted | grep -q 'large_files_skipped' \
  && ok "small-at-HEAD, large-in-worktree is caught" || no "worktree growth still evades cap"

R=$(newrepo lf2); cd "$R"
python3 -c "print('x'*200000)" > shrank.txt; git add shrank.txt; git commit -q -m big
printf 'tiny\n' > shrank.txt                        # huge at HEAD, small in worktree
cli code-review --mode uncommitted | grep -q 'large_files_skipped' \
  && ok "large-at-HEAD, small-in-worktree still caught" || no "base-side regression"

R=$(newrepo lf3); cd "$R"
printf 'a\n' > small.txt
cli code-review --mode uncommitted | grep -q '"ok": true' \
  && ok "ordinary small diff is not gated" || no "false positive on small diff"

R=$(newrepo lf4); cd "$R"
printf 'tiny\n' > grew.txt; git add grew.txt; git commit -q -m small
python3 -c "print('x'*200000)" > grew.txt
cli code-review --mode uncommitted --include-large | grep -q '"ok": true' \
  && ok "--include-large opt-in still works" || no "--include-large broken"

R=$(newrepo lf5); cd "$R"                            # no HEAD at all
python3 -c "print('x'*200000)" > big.txt; git add big.txt
cli code-review --mode uncommitted | grep -q 'large_files_skipped' \
  && ok "no-HEAD repo still enforces the cap" || no "no-HEAD guard regressed"

# --------------------------------------------------------------- secret policy
group "secret exclusion"
node -e '
import("'"$REPO_ROOT"'/plugins/adversarial-review/scripts/lib/secrets.mjs").then(m => {
  const block = [".env",".env.local","server.pem","id_rsa",".ssh/id_ed25519",".aws/credentials",
                 ".npmrc",".netrc",".pgpass",".git-credentials","credentials.json",
                 "service-account.json","terraform.tfvars","secret.yaml","secrets.yaml",
                 "vault.yml","kubeconfig.yaml","SERVER.PEM","htpasswd"];
  const allow = [".env.example",".env.template","terraform.tfvars.example","src/SecretManager.ts",
                 "README.md","config.yaml","package.json"];
  const bad = [...block.filter(p => !m.isSecretPath(p,{includeSecrets:false})).map(p => "missed:"+p),
               ...allow.filter(p =>  m.isSecretPath(p,{includeSecrets:false})).map(p => "false-positive:"+p)];
  if (bad.length) { console.log(bad.join(" ")); process.exit(1); }
  if (m.isSecretPath(".env",{includeSecrets:true})) { console.log("include-secrets bypass broken"); process.exit(1); }
})' >/dev/null 2>&1 && ok "patterns: 19 blocked, 7 allowed, opt-in bypass intact" || no "secret pattern regression"

R=$(newrepo sec); cd "$R"
echo ".env" > .gitignore; echo "TOKEN=x" > .env
cli code-review --mode uncommitted --repo-context | grep -q 'secret_files_in_tree' \
  && ok "repo-context preflight fails closed on gitignored .env" || no "preflight regressed"
cli code-review --mode uncommitted --self-collect | grep -q 'requires --repo-context' \
  && ok "--self-collect requires --repo-context" || no "self-collect validation broken"

# --------------------------------------------------------------- bundle parsing
group "context bundle parsing"
node --input-type=module -e '
const { parseBundle } = await import("'"$REPO_ROOT"'/plugins/adversarial-review/scripts/lib/bundle.mjs");
const ctx=["===== PLAN START =====","real work","the format is:","===== PLAN END =====",
           "MUST SURVIVE","===== PLAN END =====",
           "===== LATEST FIXES START =====","fix A","===== LATEST FIXES END ====="].join("\n");
const b=parseBundle(ctx,["PLAN","LATEST FIXES"]);
if(!b.PLAN.includes("MUST SURVIVE")) { console.log("truncated at embedded marker"); process.exit(1); }
if(b["LATEST FIXES"]!=="fix A") { console.log("sibling section mis-parsed"); process.exit(1); }
if(parseBundle("no markers here",["PLAN"]).PLAN!=="") { console.log("missing section should be empty"); process.exit(1); }
' >/dev/null 2>&1 && ok "embedded end-marker does not truncate the section" || no "parseBundle regression"

# ----------------------------------------------------- rename-based secret leak
group "secret exclusion survives renames"
R=$(newrepo rn1); cd "$R"
mkdir -p cfg
printf 'KEY=placeholder\nA=1\nB=2\nC=3\nD=4\nE=5\nF=6\n' > cfg/.env.example
echo plain > keep.txt
git add -A; git commit -q -m seed
git mv cfg/.env.example cfg/.env
printf 'KEY=REAL_SECRET_VALUE\nA=1\nB=2\nC=3\nD=4\nE=5\nF=6\n' > cfg/.env
echo changed > keep.txt
node --input-type=module -e '
const d = await import("'"$REPO_ROOT"'/plugins/adversarial-review/scripts/lib/diff.mjs");
const { payload, skipped } = d.buildCodePayload({ cwd: process.cwd(), mode: "uncommitted",
  options: { includeSecrets:false, includeLarge:false, includeBinary:false } });
if (payload.includes("REAL_SECRET_VALUE")) { console.log("secret leaked via rename"); process.exit(1); }
if (!skipped.some(x => x.includes("cfg/.env"))) { console.log("rename not reported as skipped"); process.exit(1); }
if (!payload.includes("keep.txt")) { console.log("ordinary file lost"); process.exit(1); }
' >/dev/null 2>&1 && ok "template→secret rename is excluded, ordinary files still reviewed" \
  || no "SECRET LEAK: rename bypassed exclusion"

# ------------------------------------------------------------------ basic paths
group "basic subcommands"
R=$(newrepo basic); cd "$R"
cli detect       | grep -q '"ok": true'        && ok "detect"       || no "detect"
cli inspect-repo | grep -q '"inWorkTree": true'&& ok "inspect-repo" || no "inspect-repo"
cli new-ctx --kind code | grep -q '"ok": true' && ok "new-ctx"      || no "new-ctx"
cli new-ctx --kind bogus| grep -q "required"   && ok "new-ctx rejects bad --kind" || no "new-ctx validation"
cli bogus-subcommand    | grep -q "unknown subcommand" && ok "unknown subcommand rejected" || no "dispatcher"
cli execute             | grep -q "unknown subcommand" && ok "removed execute command is rejected" || no "execute command still exposed"
cli --help              | grep -q " execute" && no "help still advertises execute" || ok "help lists review commands only"
cli detect              | grep -Eq '"execute"|executeConfinement' \
  && no "detect still advertises execution" || ok "detect exposes review invocation only"

group "large JSON output survives the pipe"
# The child must write to a PIPE — that is the only condition under which the
# old `process.stdout.write` + `process.exit` pair truncated at 64KB.
cat > "$WORK/emit-child.mjs" <<EOF
import { writeAllSync } from "$REPO_ROOT/plugins/adversarial-review/scripts/lib/io.mjs";
writeAllSync(1, JSON.stringify({ ok: true, output: "y".repeat(300000) }) + "\n");
process.exit(0);
EOF
emitted=$(node "$WORK/emit-child.mjs" | wc -c | tr -d ' ')
node "$WORK/emit-child.mjs" | node -e '
let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{ JSON.parse(s); });' 2>/dev/null \
  && [ "$emitted" -gt 300000 ] \
  && ok "300KB piped output arrives intact and parses (was capped at 65536)" \
  || no "emit truncation regression (got ${emitted:-0} bytes)"

# --------------------------------------------------------------- host detection
# These invocations deliberately override the suite-wide pin, so each one clears
# ADVERSARIAL_REVIEW_HOST and sets only the markers it means to test.
group "host detection picks the peer"
R=$(newrepo hd); cd "$R"
hcli(){ env -u ADVERSARIAL_REVIEW_HOST -u CLAUDECODE -u CODEX_THREAD_ID "$@" node "$CLI_JS" detect 2>&1; }

hcli CLAUDECODE=1 | grep -q '"peer": "codex"' \
  && ok "Claude Code host is reviewed by Codex" || no "claude-code did not select codex"
hcli CODEX_THREAD_ID=t1 | grep -q '"peer": "claude"' \
  && ok "Codex host is reviewed by Claude Code" || no "codex did not select claude"

# Env vars are inherited, so one CLI running inside another sets both markers.
# Guessing here could hand the review to the host's own model — the exact failure
# adversarial review exists to prevent — so it must fail closed.
hcli CLAUDECODE=1 CODEX_THREAD_ID=t1 | grep -q '"error": "ambiguous_host"' \
  && ok "both markers set fails closed rather than guessing" || no "nested hosts not rejected"
hcli | grep -q '"error": "unknown_host"' \
  && ok "no marker fails closed" || no "missing markers not rejected"

# Explicit override outranks the markers, including a contradicting one.
hcli CLAUDECODE=1 ADVERSARIAL_REVIEW_HOST=codex | grep -q '"peer": "claude"' \
  && ok "env override beats a conflicting marker" || no "env override ignored"
env -u ADVERSARIAL_REVIEW_HOST -u CLAUDECODE -u CODEX_THREAD_ID \
  node "$CLI_JS" detect --host codex 2>&1 | grep -q '"hostSource": "flag"' \
  && ok "--host flag is honoured and reported" || no "--host flag ignored"
env -u ADVERSARIAL_REVIEW_HOST CLAUDECODE=1 ADVERSARIAL_REVIEW_HOST=claude-code \
  node "$CLI_JS" detect --host codex 2>&1 | grep -q '"host": "codex"' \
  && ok "--host flag outranks the env override" || no "flag/env precedence wrong"
hcli ADVERSARIAL_REVIEW_HOST=nonsense | grep -q '"error": "unknown_host"' \
  && ok "unsupported host value rejected" || no "bad host value accepted"

# The invocation prefix is what the skills key off; Codex has no bin/ on PATH.
hcli CLAUDECODE=1 | grep -q '"review": "adversarial-review"' \
  && ok "Claude Code invocation uses the PATH command" || no "claude-code invocation wrong"
hcli CODEX_THREAD_ID=t1 | grep -q '"review": "node .*orchestration.mjs"' \
  && ok "Codex invocation addresses the runtime by path" || no "codex invocation wrong"

# Codex review calls must stay read-only and must not set unattended write
# options that belonged to the removed execution feature.
printf '===== PLAN START =====\nship the thing\n===== PLAN END =====\n' > "$WORK/codex-ro-ctx.txt"
CAL="$WORK/codex-args.log"; : > "$CAL"
FAKE_CODEX_ARGLOG="$CAL" env ADVERSARIAL_REVIEW_HOST=claude-code \
  node "$CLI_JS" plan-review --context-file "$WORK/codex-ro-ctx.txt" >/dev/null 2>&1
grep -q -- '-s read-only' "$CAL" && ok "Codex reviewer uses read-only sandbox" \
  || no "Codex reviewer is not read-only"
grep -Eq -- 'workspace-write|approval_policy=never' "$CAL" \
  && no "Codex reviewer still receives write-mode options" || ok "Codex write-mode options removed"

# ------------------------------------------------------------ claude peer backend
group "claude peer backend"
R=$(newrepo cp); cd "$R"
printf '===== PLAN START =====\nship the thing\n===== PLAN END =====\n' > "$WORK/cp-ctx.txt"
ccli(){ env ADVERSARIAL_REVIEW_HOST=codex "$@" node "$CLI_JS" "${CCLI_ARGS[@]}" 2>&1; }
CCLI_ARGS=(plan-review --context-file "$WORK/cp-ctx.txt")

ccli | grep -q '"status": "APPROVED"' \
  && ok "review runs through the claude backend" || no "claude review path broken"
FAKE_CLAUDE_STATUS="STATUS: CHANGES_REQUIRED" ccli | grep -q '"status": "CHANGES_REQUIRED"' \
  && ok "status line is parsed from the JSON result field" || no "claude status parsing broken"

# The regression this guards: `claude --print` exits 0 even when the turn failed,
# putting the error text in `result` with is_error:true. Keying on the exit code
# alone would report an API outage as a completed review.
FAKE_CLAUDE_IS_ERROR=true FAKE_CLAUDE_STATUS="API Error: 529 Overloaded" ccli \
  | grep -q '"error": "peer_failed"' \
  && ok "is_error:true with exit 0 is caught, not reported as success" || no "silent claude failure"
FAKE_CLAUDE_RC=1 ccli | grep -q '"error": "peer_failed"' \
  && ok "non-zero exit is surfaced" || no "claude exit code ignored"
FAKE_CLAUDE_VERSION=1.9.0 env ADVERSARIAL_REVIEW_HOST=codex node "$CLI_JS" detect 2>&1 \
  | grep -q 'peer_too_old' && ok "claude version floor enforced" || no "claude floor not enforced"

# A build missing a flag the backend emits would fail deep inside the CLI with an
# opaque usage error; detect names the flag instead.
FAKE_CLAUDE_HELP_OMIT="--safe-mode" env ADVERSARIAL_REVIEW_HOST=codex node "$CLI_JS" detect 2>&1 \
  | grep -q 'unsupported_build\|missingFlags' \
  && ok "missing required flag is named at detect time" || no "flag probe not enforced"

# The reviewer must not inherit the host's CLAUDE.md, skills, plugins or MCP, and
# must have no filesystem access when reviewing a payload-only diff.
AL="$WORK/claude-args.log"; : > "$AL"
FAKE_CLAUDE_ARGLOG="$AL" ccli >/dev/null 2>&1
grep -q -- '--safe-mode' "$AL" && ok "reviewer runs with --safe-mode (host config stripped)" \
  || no "reviewer inherits host configuration"
grep -q -- '--tools' "$AL" && ok "reviewer tool set is constrained" || no "reviewer tools unconstrained"
grep -q -- '--permission-mode bypassPermissions' "$AL" \
  && no "review path must never bypass permissions" || ok "review path does not bypass permissions"

# ------------------------------------------------- transient-failure retry flag
group "transient failures are marked retryable"
R=$(newrepo tr); cd "$R"
printf '===== PLAN START =====\nship the thing\n===== PLAN END =====\n' > "$WORK/tr-ctx.txt"
tcli(){ env ADVERSARIAL_REVIEW_HOST=codex "$@" node "$CLI_JS" plan-review --context-file "$WORK/tr-ctx.txt" 2>&1; }

# A saturated provider is worth one more attempt; the skill cannot tell that from
# prose, so the runtime has to say so in the contract.
FAKE_CLAUDE_IS_ERROR=true FAKE_CLAUDE_STATUS="API Error: 529 Overloaded" tcli \
  | grep -q '"retryable": true' \
  && ok "529 is marked retryable" || no "529 not marked retryable"
FAKE_CLAUDE_IS_ERROR=true FAKE_CLAUDE_STATUS="API Error: 529 Overloaded" tcli \
  | grep -q '"retryInstruction": "rerun_same_command_once"' \
  && ok "retry instruction is explicit" || no "retry instruction missing"
FAKE_CLAUDE_RC=1 FAKE_CLAUDE_STATUS="stream closed unexpectedly" tcli \
  | grep -q '"retryReason": "transient_provider_stream"' \
  && ok "stream closure is classified transient" || no "stream closure not classified"

# The inverse matters more: telling a skill to retry a genuine failure wastes a
# full round-trip and buries the real cause behind a duplicate error.
FAKE_CLAUDE_IS_ERROR=true FAKE_CLAUDE_STATUS="API Error: 401 Unauthorized" tcli \
  | grep -q '"retryable"' \
  && no "401 wrongly marked retryable" || ok "401 is not retryable"
FAKE_CLAUDE_RC=1 FAKE_CLAUDE_STATUS="STATUS: nonsense" tcli | grep -q '"retryable"' \
  && no "ordinary failure wrongly marked retryable" || ok "ordinary failure is not retryable"

node --input-type=module -e '
const { classifyTransient } = await import("'"$REPO_ROOT"'/plugins/adversarial-review/scripts/lib/agents/common.mjs");
const bad = [];
if (!classifyTransient({ rc: -1, timedOut: true })) bad.push("timeout not transient");
for (const s of [429, 500, 503, 529]) if (!classifyTransient({ rc: 1, apiErrorStatus: s })) bad.push("miss:" + s);
for (const s of [400, 401, 403, 404, 422]) if (classifyTransient({ rc: 1, apiErrorStatus: s })) bad.push("false:" + s);
if (classifyTransient({ rc: 0 })) bad.push("rc0 treated as failure");
if (bad.length) { console.log(bad.join(" ")); process.exit(1); }
' >/dev/null 2>&1 && ok "status classification: 4 transient, 5 terminal, rc0 ignored" \
  || no "classifyTransient regression"

printf '\n%s\n' "-----------------------------"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
