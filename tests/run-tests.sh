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
# inside Claude Code, and NEITHER marker is set in CI, where every test would
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

group "consult-peer skill contract"
CONSULT_SKILL="$REPO_ROOT/plugins/adversarial-review/skills/consult-peer/SKILL.md"

if [ -f "$CONSULT_SKILL" ] \
  && grep -q '^name: consult-peer$' "$CONSULT_SKILL" \
  && grep -q 'explicitly asks\|explicit request' "$CONSULT_SKILL" \
  && grep -q 'ordinary brainstorming' "$CONSULT_SKILL"; then
  ok "consult-peer has a narrow explicit-request trigger"
else
  no "consult-peer trigger contract is missing"
fi

if [ -f "$CONSULT_SKILL" ] \
  && grep -q '{invocation.review} detect' "$CONSULT_SKILL" \
  && grep -q '{invocation.review} new-ctx --kind consult' "$CONSULT_SKILL" \
  && grep -q '{invocation.review} consult --context-file <path>' "$CONSULT_SKILL" \
  && grep -q 'Never invoke.*claude\|never invoke.*claude' "$CONSULT_SKILL"; then
  ok "consult-peer uses only the supported peer runtime"
else
  no "consult-peer invocation contract is incomplete"
fi

if [ -f "$CONSULT_SKILL" ] \
  && grep -q 'initial assessment' "$CONSULT_SKILL" \
  && grep -q 'Do not include.*initial assessment\|do not include.*initial assessment' "$CONSULT_SKILL" \
  && grep -q 'one focused question' "$CONSULT_SKILL" \
  && grep -q 'prefer' "$CONSULT_SKILL"; then
  ok "consult-peer preserves an independent peer brief"
else
  no "consult-peer independence contract is incomplete"
fi

if [ -f "$CONSULT_SKILL" ] \
  && grep -qi 'credentials' "$CONSULT_SKILL" \
  && grep -qi 'personal data' "$CONSULT_SKILL" \
  && grep -q 'no bypass\|Never bypass' "$CONSULT_SKILL" \
  && grep -q 'revoke or rotate' "$CONSULT_SKILL" \
  && grep -q 'Do not repeat a sensitive value' "$CONSULT_SKILL" \
  && grep -q 'CANDIDATE APPROACHES START' "$CONSULT_SKILL"; then
  ok "consult-peer defines safety and bundle contracts"
else
  no "consult-peer safety or bundle contract is incomplete"
fi

if [ -f "$CONSULT_SKILL" ] \
  && grep -q 'rerun_same_command_once' "$CONSULT_SKILL" \
  && grep -q 'missing_recommendation_line' "$CONSULT_SKILL" \
  && grep -q 'Peer view' "$CONSULT_SKILL" \
  && grep -q 'agreement is not verification' "$CONSULT_SKILL"; then
  ok "consult-peer defines retry and synthesis behavior"
else
  no "consult-peer retry or synthesis contract is incomplete"
fi

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

grep -q '`consult-peer`' "$ROOT_README" \
  && grep -q 'payload-only' "$ROOT_README" \
  && grep -q 'one peer request' "$ROOT_README" \
  && grep -q '`consult-peer`' "$PLUGIN_README" \
  && grep -q 'peer account.*quota' "$PLUGIN_README" \
  && ok "README documents consultation scope, confinement, and cost" \
  || no "README consultation contract is incomplete"

if grep -Eq '^## (Safety|Troubleshooting)$' "$ROOT_README" "$PLUGIN_README"; then
  no "removed README sections returned"
else
  ok "README has no removed sections"
fi

# Repo-wide, not README-only. The old guard watched two files while em dashes
# accumulated in the review prompts, the runtime comments and this suite. The
# pattern is built from a codepoint escape so the check cannot match its own
# source, and python3 is already a CI dependency for the manifest checks.
emdash_hits=$(cd "$REPO_ROOT" && python3 -c '
import pathlib, subprocess
EM = chr(0x2014)
listing = subprocess.run(["git", "ls-files", "-z"], capture_output=True, text=True).stdout
bad = []
for f in listing.split("\0"):
    if not f:
        continue
    try:
        if EM in pathlib.Path(f).read_text(encoding="utf-8"):
            bad.append(f)
    except (OSError, UnicodeDecodeError):
        continue
print(" ".join(bad))
')
if [ -n "$emdash_hits" ]; then
  no "em dash in tracked file(s): $emdash_hits"
else
  ok "no em dash in any tracked file"
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
# A well-formed plan bundle, so the version gate is what trips, not input validation.
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

# The self-collect snapshot is a list of filenames handed to a peer that then
# reads the repo itself. A tracked `.env` used to reach it, because that side was
# filtered by pathspecs alone and the pathspec list has no `.env` entry.
R=$(newrepo sc); cd "$R"
printf 'TOKEN=real\n' > .env
printf 'TOKEN=placeholder\n' > .env.example
git add -A; git commit -q -m seed
printf 'TOKEN=rotated\n' > .env
printf 'TOKEN=placeholder2\n' > .env.example
node --input-type=module -e '
const d = await import("'"$REPO_ROOT"'/plugins/adversarial-review/scripts/lib/diff.mjs");
const { payload } = d.buildCodeSelfCollectPayload({ cwd: process.cwd(), mode: "uncommitted",
  options: { includeSecrets: false } });
if (payload.includes("- .env\n")) { console.log("tracked .env listed in snapshot"); process.exit(1); }
if (!payload.includes("- .env.example")) { console.log("template wrongly filtered"); process.exit(1); }
' >/dev/null 2>&1 && ok "self-collect snapshot omits a tracked .env but keeps .env.example" \
  || no "SECRET LEAK: tracked .env reached the self-collect snapshot"

# ------------------------------------------------------- binary probe failure
group "binary detection fails safe"
# `file` is spawned to classify untracked files. When that spawn fails (argv over
# ARG_MAX, or `file` not installed) an unclassified file used to be treated as
# text and read as utf8, inlining the binary into the payload as mojibake.
R=$(newrepo bin); cd "$R"
python3 -c "open('blob.bin','wb').write(bytes(range(256))*40)"
printf 'plain\n' > keep.txt
STUBS="$WORK/nofile"; mkdir -p "$STUBS"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUBS/file"; chmod +x "$STUBS/file"
PATH="$STUBS:$PATH" node --input-type=module -e '
const d = await import("'"$REPO_ROOT"'/plugins/adversarial-review/scripts/lib/diff.mjs");
const { payload, skipped } = d.buildCodePayload({ cwd: process.cwd(), mode: "uncommitted",
  options: { includeSecrets:false, includeLarge:false, includeBinary:false } });
if (!skipped.some(x => x === "binary untracked: blob.bin")) { console.log("binary not skipped"); process.exit(1); }
if (payload.includes("blob.bin")) { console.log("binary inlined anyway"); process.exit(1); }
if (!payload.includes("keep.txt")) { console.log("text file lost"); process.exit(1); }
' >/dev/null 2>&1 && ok "unclassifiable file is skipped as binary, text files still reviewed" \
  || no "binary probe failure still inlines binaries as text"

# The working path must not regress: with `file` available, nothing changes.
cli code-review --mode uncommitted | grep -q 'binary untracked: blob.bin' \
  && ok "binary is still detected normally when file(1) works" || no "normal binary detection regressed"

# --------------------------------------------------------- stable error codes
group "failure paths emit stable error codes"
R=$(newrepo ec); cd "$R"
# AGENTS.md pins `error` to a code the SKILLs match on. These two paths used to
# emit free-form prose and an internal-crash label respectively.
cli code-review --mode branch --base no-such-ref | grep -q '"error": "invalid_base"' \
  && ok "unresolvable --base reports invalid_base" || no "invalid_base code missing"
cli code-review --mode branch --base no-such-ref | grep -q '"detail": "merge-base not found' \
  && ok "the human-readable reason moved to detail" || no "detail missing on invalid_base"
cli code-review --mode uncommitted --bogus | grep -q '"error": "invalid_usage"' \
  && ok "an unknown flag is a usage error, not an unhandled_exception" || no "bad flag still labelled a crash"

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
cli new-ctx --kind consult | grep -q '"ok": true' && ok "new-ctx consult" || no "new-ctx consult"
cli new-ctx --kind bogus| grep -q "required"   && ok "new-ctx rejects bad --kind" || no "new-ctx validation"
cli bogus-subcommand    | grep -q "unknown subcommand" && ok "unknown subcommand rejected" || no "dispatcher"
cli execute             | grep -q "unknown subcommand" && ok "removed execute command is rejected" || no "execute command still exposed"
cli --help              | grep -q " execute" && no "help still advertises execute" || ok "help lists review commands only"
cli --help              | grep -q 'consult --context-file PATH \[--model NAME\]' \
  && ok "help documents the optional consultation model" \
  || no "help omits the optional consultation model"
cli detect              | grep -Eq '"execute"|executeConfinement' \
  && no "detect still advertises execution" || ok "detect exposes review invocation only"

# --------------------------------------------------------- peer consultation
group "peer consultation runtime contract"
R=$(newrepo consult); cd "$R"
QUESTION_CTX="$WORK/consult-question.txt"
EMPTY_CTX="$WORK/consult-empty-optionals.txt"
MISSING_CTX="$WORK/consult-missing-question.txt"
printf '===== QUESTION START =====\nUse Redis or the database?\n===== QUESTION END =====\n' > "$QUESTION_CTX"
printf '===== QUESTION START =====\nUse Redis or the database?\n===== QUESTION END =====\n===== CONTEXT START =====\n\n===== CONTEXT END =====\n===== CANDIDATE APPROACHES START =====\n\n===== CANDIDATE APPROACHES END =====\n' > "$EMPTY_CTX"
printf '===== CONTEXT START =====\nNo question\n===== CONTEXT END =====\n' > "$MISSING_CTX"

CIN="$WORK/consult-codex-input.txt"
out=$(FAKE_CODEX_STATUS="RECOMMENDATION: Use the database" FAKE_CODEX_INPUTLOG="$CIN" cli consult --context-file "$QUESTION_CTX")
printf '%s' "$out" | node -e '
let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
  const x=JSON.parse(s); if(!x.ok || x.peer!=="codex" || "status" in x || !x.output.startsWith("RECOMMENDATION:")) process.exit(1);
});' 2>/dev/null \
  && ok "question-only consultation succeeds through codex without review status" \
  || no "codex consultation contract failed: $(printf '%s' "$out" | head -2)"

if [ -f "$CIN" ] && ! grep -q 'CONTEXT START\|CANDIDATE APPROACHES START' "$CIN"; then
  ok "absent optional sections are omitted from peer payload"
else
  no "absent optional sections leaked into normalized peer payload"
fi

CIN_EMPTY="$WORK/consult-codex-empty-input.txt"
FAKE_CODEX_STATUS="RECOMMENDATION: Use the database" FAKE_CODEX_INPUTLOG="$CIN_EMPTY" \
  cli consult --context-file "$EMPTY_CTX" | grep -q '"ok": true' \
  && ! grep -q 'CONTEXT START\|CANDIDATE APPROACHES START' "$CIN_EMPTY" \
  && ok "present-but-empty optional sections are omitted" \
  || no "empty optional sections changed the peer payload"

variants_ok=true
for recommendation in \
  '**RECOMMENDATION:** Use the database' \
  '# Recommendation: Use the database' \
  '- **Recommendation:** Use the database' \
  '`recommendation:` Use the database'
do
  FAKE_CODEX_STATUS="$recommendation" cli consult --context-file "$QUESTION_CTX" \
    | grep -q '"ok": true' || variants_ok=false
done
[ "$variants_ok" = true ] \
  && ok "bounded markdown recommendation variants are accepted" \
  || no "a documented recommendation variant was rejected"

FAKE_CODEX_STATUS="Here is my advice" cli consult --context-file "$QUESTION_CTX" \
  | grep -q '"error": "missing_recommendation_line"' \
  && ok "missing recommendation label fails closed" || no "missing label was accepted"
FAKE_CODEX_EMPTY=true cli consult --context-file "$QUESTION_CTX" \
  | grep -q '"error": "missing_recommendation_line"' \
  && ok "empty peer output fails closed" || no "empty peer output was accepted"
cli consult --context-file "$MISSING_CTX" | grep -q '"error": "invalid_usage"' \
  && ok "consultation requires a question" || no "missing question was accepted"
cli consult --context-file "$QUESTION_CTX" --bogus | grep -q '"error": "invalid_usage"' \
  && ok "consultation rejects unknown flags" || no "consultation accepted an unknown flag"

out=$(FAKE_CLAUDE_STATUS="RECOMMENDATION: Use the database" env ADVERSARIAL_REVIEW_HOST=codex \
  node "$CLI_JS" consult --context-file "$QUESTION_CTX" 2>&1)
printf '%s' "$out" | node -e '
let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
  const x=JSON.parse(s); if(!x.ok || x.peer!=="claude" || "status" in x) process.exit(1);
});' 2>/dev/null \
  && ok "consultation succeeds through claude without review status" \
  || no "claude consultation contract failed: $(printf '%s' "$out" | head -2)"

out=$(FAKE_CLAUDE_EMPTY=true env ADVERSARIAL_REVIEW_HOST=codex \
  node "$CLI_JS" consult --context-file "$QUESTION_CTX" 2>&1)
printf '%s' "$out" | node -e '
let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
  const x=JSON.parse(s); if(x.error!=="missing_recommendation_line" || x.output!=="") process.exit(1);
});' 2>/dev/null \
  && ok "claude empty-output fixture emits an empty result" \
  || no "claude empty-output fixture contains reply text"

CAL="$WORK/consult-codex-args.log"; : > "$CAL"
FAKE_CODEX_STATUS="RECOMMENDATION: Use the database" FAKE_CODEX_ARGLOG="$CAL" \
  cli consult --context-file "$QUESTION_CTX" >/dev/null 2>&1
grep -q -- '-s read-only' "$CAL" && grep -q -- '--skip-git-repo-check' "$CAL" \
  && ok "codex consultation is payload-only and read-only" \
  || no "codex consultation confinement changed"

AL="$WORK/consult-claude-args.log"; : > "$AL"
FAKE_CLAUDE_STATUS="RECOMMENDATION: Use the database" FAKE_CLAUDE_ARGLOG="$AL" \
  env ADVERSARIAL_REVIEW_HOST=codex node "$CLI_JS" consult --context-file "$QUESTION_CTX" >/dev/null 2>&1
grep -q -- '--tools' "$AL" && ! grep -q 'Read,Grep,Glob' "$AL" \
  && ok "claude consultation has no tools" || no "claude consultation received repository tools"

FAKE_CLAUDE_IS_ERROR=true FAKE_CLAUDE_STATUS="API Error: 529 Overloaded" \
  env ADVERSARIAL_REVIEW_HOST=codex node "$CLI_JS" consult --context-file "$QUESTION_CTX" 2>&1 \
  | grep -q '"retryInstruction": "rerun_same_command_once"' \
  && ok "consultation reuses transient retry metadata" || no "consultation lost retry metadata"

printf '===== PLAN START =====\nship the thing\n===== PLAN END =====\n' > "$WORK/review-shape-ctx.txt"
review_out=$(FAKE_CODEX_RC=1 FAKE_CODEX_STATUS="hard failure" cli plan-review --context-file "$WORK/review-shape-ctx.txt")
printf '%s' "$review_out" | node -e '
let s=""; process.stdin.on("data",d=>s+=d).on("end",()=>{
  const x=JSON.parse(s), keys=Object.keys(x).sort().join(",");
  if(keys!=="error,ok,output,peer,rc,stderr,stdout" || x.error!=="peer_failed") process.exit(1);
});' 2>/dev/null \
  && ok "review peer-failure shape is pinned before refactor" \
  || no "review peer-failure shape changed before refactor"

group "large JSON output survives the pipe"
# The child must write to a PIPE, which is the only condition under which the
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
# Guessing here could hand the review to the host's own model, the exact failure
# adversarial review exists to prevent, so it must fail closed.
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

# -------------------------------------------------------------- cursor backend
group "cursor backend"
export PEER_PRESSURE_TEST_AGENT=peer-pressure-test-agent
expected_agent="$TESTS_DIR/bin/agent"
[ "$(command -v agent)" = "$expected_agent" ] || exit 1
[ "$(agent --fixture-id)" = "peer-pressure-test-agent" ] || exit 1

CURSOR_MODULE="$REPO_ROOT/plugins/adversarial-review/scripts/lib/agents/cursor.mjs"
FAKE_AGENT_ROOT="$WORK/cursor-contract"
mkdir -p "$FAKE_AGENT_ROOT"
CURSOR_MODULE="$CURSOR_MODULE" FAKE_AGENT_ROOT="$FAKE_AGENT_ROOT" node --input-type=module <<'EOF'
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const modulePath = process.env.CURSOR_MODULE;
const work = process.env.FAKE_AGENT_ROOT;
const { agent, buildRunOptions, CURSOR_MODELS, SUPPORTED_CURSOR_VERSION } = await import(modulePath);
const requiredFlags = ["--print", "--output-format", "--mode", "--sandbox", "--trust", "--workspace", "--add-dir", "--model"];
const saved = { ...process.env };
const reset = () => {
  for (const key of Object.keys(process.env)) if (!(key in saved)) delete process.env[key];
  Object.assign(process.env, saved);
};
const detect = (values = {}) => {
  reset(); Object.assign(process.env, values); return agent.detect();
};
const run = (values = {}, options = {}) => {
  reset(); Object.assign(process.env, values);
  return agent.run({ prompt: "review prompt", payload: "payload", model: "composer", timeoutMs: 1_000, ...options });
};

assert.equal(SUPPORTED_CURSOR_VERSION, "2026.08.04-aaa8809");
assert.deepEqual(CURSOR_MODELS, { composer: "composer-2.5", grok: "cursor-grok-4.5-high", kimi: "kimi-k3-max", glm: "glm-5.2-max" });
assert(Object.isFrozen(CURSOR_MODELS));
assert.equal(agent.id, "cursor");
assert.equal(agent.command, "agent");
assert.equal(buildRunOptions({ workspace: "/tmp/cursor-test", input: "review input" }).timeout, 600_000);
assert.equal(detect({ FAKE_AGENT_VERSION: SUPPORTED_CURSOR_VERSION }).ok, true);
for (const version of ["2026.08.03-aaa8809", "2026.08.05-aaa8809", "2026.08.04-wrong", "2026.08.04"]) {
  const result = detect({ FAKE_AGENT_VERSION: version });
  assert.equal(result.reason, "unsupported_build");
  assert.equal(result.version, version);
  assert.equal(result.supportedVersion, SUPPORTED_CURSOR_VERSION);
  assert.deepEqual(result.setupHints, ["agent install 2026.08.04-aaa8809"]);
}
assert.equal(detect({ FAKE_AGENT_VERSION: "nightly" }).reason, "unsupported_version_format");
assert.equal(detect({ FAKE_AGENT_VERSION_RC: "1" }).reason, "authentication_failed");
assert.deepEqual(detect({ FAKE_AGENT_HELP_OMIT: "--mode" }).missingFlags, ["--mode"]);
assert.deepEqual(detect({ FAKE_AGENT_HELP_OMIT: requiredFlags.join(" ") }).missingFlags, requiredFlags);
const oldPath = process.env.PATH; process.env.PATH = "/no-such-agent-path";
assert.equal(agent.detect().reason, "not_installed"); process.env.PATH = oldPath;

const payload = "p".repeat(300_000);
const arglog = path.join(work, "args.log");
const inputlog = path.join(work, "input.log");
const workspaces = path.join(work, "workspaces.log");
let result = run({ FAKE_AGENT_ARGLOG: arglog, FAKE_AGENT_INPUTLOG: inputlog, FAKE_AGENT_WORKSPACE_LOG: workspaces }, { payload });
assert.equal(result.rc, 0);
assert.equal(result.output, "STATUS: APPROVED\n\nfake-cursor reply body.");
assert.equal(fs.readFileSync(inputlog, "utf8"), `review prompt\n\n${payload}`);
const args = fs.readFileSync(arglog, "utf8").trim().split("\n").filter((line) => line.startsWith("arg=")).map((line) => line.slice(4));
const workspace = args[args.indexOf("--workspace") + 1];
assert.deepEqual(args, [
  "--print", "--output-format", "json", "--mode", "ask", "--sandbox", "enabled", "--trust",
  "--disable-project-configs", "--exclude-workspace-context", "--disable-auto-update",
  "--workspace", workspace, "--model", "composer-2.5"
]);
assert.equal(fs.readFileSync(workspaces, "utf8").match(/^entries=$/m)?.[0], "entries=");
assert(!args.includes("review prompt"));

const repo = path.join(work, "repo"); fs.mkdirSync(repo);
fs.writeFileSync(arglog, ""); fs.writeFileSync(inputlog, "");
result = run({ FAKE_AGENT_ARGLOG: arglog, FAKE_AGENT_INPUTLOG: inputlog }, { cwd: repo, prompt: "repo prompt", payload: "repo payload" });
assert.equal(result.rc, 0);
const repoArgs = fs.readFileSync(arglog, "utf8").split("\n").filter((line) => line.startsWith("arg=")).map((line) => line.slice(4));
assert.deepEqual(repoArgs.slice(repoArgs.indexOf("--add-dir"), repoArgs.indexOf("--add-dir") + 2), ["--add-dir", path.resolve(repo)]);
assert.equal(fs.readFileSync(inputlog, "utf8"), `Repository root: ${path.resolve(repo)}\nResolve every relative payload path against this root.\n\nrepo prompt\n\nrepo payload`);

fs.writeFileSync(workspaces, "");
run({ FAKE_AGENT_WORKSPACE_LOG: workspaces }); run({ FAKE_AGENT_WORKSPACE_LOG: workspaces });
const paths = fs.readFileSync(workspaces, "utf8").split("\n").filter((line) => line.startsWith("workspace=")).map((line) => line.slice(10));
assert.equal(paths.length, 2); assert.notEqual(paths[0], paths[1]);
for (const workspace of paths) { assert(workspace.startsWith(os.tmpdir())); assert.equal(fs.existsSync(workspace), false); }
for (const values of [
  { FAKE_AGENT_WRITE_WORKSPACE: "true" },
  { FAKE_AGENT_WRITE_WORKSPACE: "true", FAKE_AGENT_RC: "7" },
  { FAKE_AGENT_WRITE_WORKSPACE: "true", FAKE_AGENT_SLEEP: "2" },
  { FAKE_AGENT_WRITE_WORKSPACE: "true", FAKE_AGENT_OUTPUT_MODE: "non-json" }
]) {
  fs.writeFileSync(workspaces, "");
  result = run({ ...values, FAKE_AGENT_WORKSPACE_LOG: workspaces }, { timeoutMs: values.FAKE_AGENT_SLEEP ? 20 : 1_000 });
  const workspace = fs.readFileSync(workspaces, "utf8").match(/^workspace=(.+)$/m)?.[1];
  assert(workspace); assert.equal(fs.existsSync(workspace), false);
}
result = run({ FAKE_AGENT_IS_ERROR: "true", FAKE_AGENT_API_ERROR_STATUS: "529" });
assert.notEqual(result.rc, 0); assert.equal(result.apiErrorStatus, 529);
for (const mode of ["non-json", "prefixed-json", "missing-result", "empty-result"]) assert.notEqual(run({ FAKE_AGENT_OUTPUT_MODE: mode }).rc, 0);
assert.equal(run({ FAKE_AGENT_RC: "9", FAKE_AGENT_OUTPUT_MODE: "non-json" }).rc, 9);
result = run({ FAKE_AGENT_OUTPUT_BYTES: "34000000" }, { timeoutMs: 10_000 });
assert.notEqual(result.rc, 0); assert.equal(result.outputTooLarge, true); assert.equal(result.timedOut, false);
result = run({ FAKE_AGENT_MODEL_REJECT: "true" }, { model: "grok" });
assert.equal(result.modelRejected, true); assert.equal(result.modelAlias, "grok");
assert.equal(result.modelId, "cursor-grok-4.5-high"); assert.equal(result.modelListCommand, "agent --list-models");

const rmSync = fs.rmSync; fs.rmSync = () => { throw new Error("cleanup denied"); };
try {
  result = run(); assert.equal(result.rc, 0); assert.match(result.cleanupError, /cleanup denied/);
} finally { fs.rmSync = rmSync; }
reset();
EOF
cursor_contract_rc=$?
[ "$cursor_contract_rc" -eq 0 ] \
  && ok "Cursor backend detection and run contracts" || no "Cursor backend detection or run contract"

# --------------------------------------------------------- Cursor peer override
group "Cursor peer override"
CURSOR_VERSION="2026.08.04-aaa8809"
CURSOR_ARGS="$WORK/cursor-runtime-args.log"
CURSOR_INPUT="$WORK/cursor-runtime-input.log"
CURSOR_WORKSPACES="$WORK/cursor-runtime-workspaces.log"
CODEX_ARGS="$WORK/cursor-runtime-codex.log"
CLAUDE_ARGS="$WORK/cursor-runtime-claude.log"
NODE_BIN="$(command -v node)"
: > "$CURSOR_ARGS"; : > "$CURSOR_INPUT"; : > "$CURSOR_WORKSPACES"
: > "$CODEX_ARGS"; : > "$CLAUDE_ARGS"

QUESTION_CTX="$WORK/cursor-question.txt"
PLAN_CTX="$WORK/cursor-plan.txt"
printf '===== QUESTION START =====\nUse Redis or the database?\n===== QUESTION END =====\n' > "$QUESTION_CTX"
printf '===== PLAN START =====\nship the thing\n===== PLAN END =====\n' > "$PLAN_CTX"
R=$(newrepo cursor-runtime); cd "$R"
printf 'changed\n' >> seed.txt

cursor_cli(){
  env PEER_PRESSURE_TEST_AGENT=peer-pressure-test-agent \
    FAKE_AGENT_ARGLOG="$CURSOR_ARGS" \
    FAKE_AGENT_INPUTLOG="$CURSOR_INPUT" \
    FAKE_AGENT_WORKSPACE_LOG="$CURSOR_WORKSPACES" \
    FAKE_CODEX_ARGLOG="$CODEX_ARGS" \
    FAKE_CLAUDE_ARGLOG="$CLAUDE_ARGS" \
    node "$CLI_JS" "$@" 2>&1
}

cursor_cli detect --peer cursor | grep -q '"host": "claude-code"' \
  && cursor_cli detect --peer cursor | grep -q '"peer": "cursor"' \
  && cursor_cli detect --peer cursor | grep -q "\"version\": \"$CURSOR_VERSION\"" \
  && cursor_cli detect --peer cursor | grep -q '"sandbox": "ask-mode"' \
  && ok "detect selects Cursor with its version and confinement" \
  || no "detect does not report the Cursor reviewer contract"
cursor_cli detect --peer=cursor | grep -q '"peer": "cursor"' \
  && ok "equals-form Cursor peer selection works" \
  || no "equals-form Cursor peer selection is rejected"

env ADVERSARIAL_REVIEW_HOST=claude-code node "$CLI_JS" detect 2>&1 | grep -q '"peer": "codex"' \
  && ok "default Claude Code host still selects Codex" \
  || no "Claude Code default reviewer changed"
env ADVERSARIAL_REVIEW_HOST=codex node "$CLI_JS" detect 2>&1 | grep -q '"peer": "claude"' \
  && ok "default Codex host still selects Claude" \
  || no "Codex default reviewer changed"

cursor_cli consult --peer cursor --model composer --context-file "$QUESTION_CTX" \
  | grep -q '"peer": "cursor"' \
  && ok "consult accepts the composer Cursor alias" || no "consult rejects composer"
cursor_cli plan-review --peer cursor --model grok --context-file "$PLAN_CTX" --first \
  | grep -q '"status": "APPROVED"' \
  && ok "plan review accepts the grok Cursor alias" || no "plan review rejects grok"
cursor_cli code-review --peer cursor --model kimi --mode uncommitted --first \
  | grep -q '"status": "APPROVED"' \
  && ok "payload-only code review accepts the kimi Cursor alias" || no "code review rejects kimi"
payload_input=$(cat "$CURSOR_INPUT")
case "$payload_input" in
  *"Repository root:"*) no "payload-only commands expose a repository root" ;;
  *) ok "payload-only commands expose no repository root" ;;
esac
cursor_cli code-review --peer cursor --model glm --mode uncommitted --repo-context --first \
  | grep -q '"status": "APPROVED"' \
  && ok "repository code review accepts the glm Cursor alias" || no "repository review rejects glm"

for alias_and_id in \
  'composer composer-2.5' \
  'grok cursor-grok-4.5-high' \
  'kimi kimi-k3-max' \
  'glm glm-5.2-max'
do
  alias=${alias_and_id%% *}
  model_id=${alias_and_id#* }
  grep -q "arg=$model_id" "$CURSOR_ARGS" \
    && ok "Cursor alias $alias maps to $model_id" || no "Cursor alias $alias did not map to $model_id"
done

repo_root=$(cd "$R" && pwd -P)
grep -q "arg=$repo_root" "$CURSOR_ARGS" \
  && grep -q "Repository root: $repo_root" "$CURSOR_INPUT" \
  && ok "repository context passes the absolute root to Cursor" \
  || no "repository context does not pass the absolute root"

: > "$CODEX_ARGS"; : > "$CLAUDE_ARGS"
cursor_cli consult --peer cursor --context-file "$QUESTION_CTX" | grep -q '"error": "invalid_usage"' \
  && [ ! -s "$CODEX_ARGS" ] && [ ! -s "$CLAUDE_ARGS" ] \
  && ok "missing Cursor alias invokes no default peer" || no "missing Cursor alias contract is wrong"
: > "$CODEX_ARGS"; : > "$CLAUDE_ARGS"
cursor_cli consult --peer cursor --model unknown --context-file "$QUESTION_CTX" | grep -q 'composer|grok|kimi|glm' \
  && [ ! -s "$CODEX_ARGS" ] && [ ! -s "$CLAUDE_ARGS" ] \
  && ok "unknown Cursor alias invokes no default peer" || no "unknown Cursor alias contract is wrong"
: > "$CODEX_ARGS"; : > "$CLAUDE_ARGS"
cursor_cli detect --peer nope | grep -q '"error": "invalid_usage"' \
  && [ ! -s "$CODEX_ARGS" ] && [ ! -s "$CLAUDE_ARGS" ] \
  && ok "unknown explicit peer is invalid usage without fallback" || no "unknown explicit peer contract is wrong"
: > "$CODEX_ARGS"; : > "$CLAUDE_ARGS"
cursor_cli detect --peer nope --peer cursor | grep -q '"error": "invalid_usage"' \
  && [ ! -s "$CODEX_ARGS" ] && [ ! -s "$CLAUDE_ARGS" ] \
  && ok "every explicit peer value is validated" || no "an earlier invalid peer can be hidden"

MISSING_AGENT_BIN="$WORK/missing-agent-bin"
mkdir -p "$MISSING_AGENT_BIN"
ln -s "$TESTS_DIR/bin/codex" "$MISSING_AGENT_BIN/codex"
ln -s "$TESTS_DIR/bin/claude" "$MISSING_AGENT_BIN/claude"
for failure in missing auth build version flag; do
  : > "$CODEX_ARGS"; : > "$CLAUDE_ARGS"
  case "$failure" in
    missing) out=$(env PATH="$MISSING_AGENT_BIN:/usr/bin:/bin" PEER_PRESSURE_TEST_AGENT=peer-pressure-test-agent FAKE_CODEX_ARGLOG="$CODEX_ARGS" FAKE_CLAUDE_ARGLOG="$CLAUDE_ARGS" "$NODE_BIN" "$CLI_JS" detect --peer cursor 2>&1) ; expected='"error": "peer_unavailable"' ;;
    auth) out=$(FAKE_AGENT_VERSION_RC=1 cursor_cli detect --peer cursor) ; expected='"error": "authentication_failed"' ;;
    build) out=$(FAKE_AGENT_VERSION=2026.08.03-aaa8809 cursor_cli detect --peer cursor) ; expected='"error": "unsupported_build"' ;;
    version) out=$(FAKE_AGENT_VERSION=nightly cursor_cli detect --peer cursor) ; expected='"error": "unsupported_version_format"' ;;
    flag) out=$(FAKE_AGENT_HELP_OMIT=--mode cursor_cli detect --peer cursor) ; expected='"missingFlags"' ;;
  esac
  printf '%s' "$out" | grep -q "$expected" \
    && [ ! -s "$CODEX_ARGS" ] && [ ! -s "$CLAUDE_ARGS" ] \
    && ok "Cursor $failure detection failure does not fall back" \
    || no "Cursor $failure detection failure has the wrong contract"
done

: > "$CURSOR_ARGS"; : > "$CURSOR_INPUT"; : > "$CURSOR_WORKSPACES"
FAKE_AGENT_IS_ERROR=true FAKE_AGENT_API_ERROR_STATUS=529 cursor_cli consult --peer cursor --model composer --context-file "$QUESTION_CTX" \
  | grep -q '"retryable": true' \
  && ok "Cursor transient failure is retryable" || no "Cursor transient failure is not retryable"
first_input=$(cat "$CURSOR_INPUT")
FAKE_AGENT_STATUS='RECOMMENDATION: Use the database' cursor_cli consult --peer cursor --model composer --context-file "$QUESTION_CTX" \
  | grep -q '"ok": true' \
  && [ "$first_input" = "$(cat "$CURSOR_INPUT")" ] \
  && [ "$(grep -c '^arg=composer-2.5$' "$CURSOR_ARGS")" -eq 2 ] \
  && [ "$(grep '^workspace=' "$CURSOR_WORKSPACES" | sort -u | wc -l | tr -d ' ')" -eq 2 ] \
  && ok "Cursor retry preserves stdin and alias in a fresh workspace" \
  || no "Cursor retry does not preserve the request safely"

FAKE_AGENT_OUTPUT_BYTES=34000000 cursor_cli consult --peer cursor --model composer --context-file "$QUESTION_CTX" \
  | grep -q '"error": "peer_output_too_large"' \
  && ok "Cursor oversized output has its own terminal error" \
  || no "Cursor oversized output error is wrong"
FAKE_AGENT_OUTPUT_BYTES=34000000 cursor_cli consult --peer cursor --model composer --context-file "$QUESTION_CTX" \
  | grep -q '"retryable"' \
  && no "Cursor oversized output is retryable" || ok "Cursor oversized output is terminal"
FAKE_AGENT_SELF_KILL=true cursor_cli consult --peer cursor --model composer --context-file "$QUESTION_CTX" \
  | grep -q '"timedOut": true' \
  && ok "Cursor timeout is reported as terminal" || no "Cursor timeout is not reported"
FAKE_AGENT_SELF_KILL=true cursor_cli consult --peer cursor --model composer --context-file "$QUESTION_CTX" \
  | grep -q '"retryable"' \
  && no "Cursor timeout is retryable" || ok "Cursor timeout has no retry metadata"
FAKE_AGENT_OUTPUT_MODE=non-json FAKE_AGENT_NON_JSON_OUTPUT='rate limit' cursor_cli consult --peer cursor --model composer --context-file "$QUESTION_CTX" \
  | grep -q '"retryable"' \
  && no "Cursor strict JSON failure is retryable" || ok "Cursor strict JSON failure is terminal"
FAKE_AGENT_OUTPUT_MODE=non-json FAKE_AGENT_NON_JSON_OUTPUT='rate limit' cursor_cli consult --peer cursor --model composer --context-file "$QUESTION_CTX" \
  | grep -q '"strictJsonFailure": true' \
  && ok "Cursor strict JSON failure is identified" || no "Cursor strict JSON failure is not identified"
FAKE_AGENT_MODEL_REJECT=true cursor_cli consult --peer cursor --model grok --context-file "$QUESTION_CTX" \
  | grep -q '"error": "cursor_model_unavailable"' \
  && ok "Cursor model rejection has its own error" || no "Cursor model rejection error is wrong"
FAKE_AGENT_MODEL_REJECT=true cursor_cli consult --peer cursor --model grok --context-file "$QUESTION_CTX" \
  | grep -q '"modelId": "cursor-grok-4.5-high"' \
  && ok "Cursor model rejection reports alias mapping" || no "Cursor model rejection lacks mapping"

# ---------------------------------------------------------- plan-mode hook
group "plan-mode hook"
# The hook shipped with no execution coverage at all: CI only linted it. Its
# `case` gate on */.claude/plans/*.md is the only thing between a spoofed
# transcript line and an arbitrary path being injected into Claude's context,
# so it is worth pinning.
# (Do not start a comment line with the linter's name: it gets parsed as a
# directive and fails the lint.)
HOOK="$REPO_ROOT/plugins/adversarial-review/hooks/post-exit-plan-mode"
HW="$WORK/hook"; mkdir -p "$HW/.claude/plans"
printf '# Plan\n' > "$HW/.claude/plans/draft.md"

# The hook anchors on this exact reminder phrase, so the fixture must use it too.
mktranscript(){ printf 'You should create your plan at %s\n' "$@" > "$HW/transcript.jsonl"; }
runhook(){ printf '{"transcript_path":"%s"}' "$1" | "$HOOK" 2>/dev/null; }

if ! command -v jq >/dev/null 2>&1; then
  # Not a skip: the hook needs jq and degrades to silence without it, so a
  # machine without jq cannot verify the behaviour users actually get.
  no "jq is missing, so the plan-mode hook cannot be exercised"
else
  mktranscript "$HW/.claude/plans/draft.md"
  out=$(runhook "$HW/transcript.jsonl")
  printf '%s' "$out" | grep -q "$HW/.claude/plans/draft.md" \
    && printf '%s' "$out" | grep -q 'hookSpecificOutput' \
    && ok "a readable plan under .claude/plans produces advisory context" \
    || no "hook produced no usable context for a valid plan"

  # A transcript is attacker-influenced content. A path outside the plans dir
  # must never reach the output, however the phrase got in there.
  #
  # The decoy has to EXIST and be readable. Pointing at a missing file made this
  # assertion pass on the later `[[ -r ]]` check instead of the directory gate,
  # so weakening the gate to `*.md` still went green.
  mkdir -p "$HW/outside"; printf '# not a plan\n' > "$HW/outside/evil.md"
  mktranscript "$HW/outside/evil.md"
  [ -z "$(runhook "$HW/transcript.jsonl")" ] \
    && ok "a readable plan path outside .claude/plans is refused" \
    || no "PATH ESCAPE: hook accepted a path outside .claude/plans"

  # Right directory, but nothing on disk: the readability check must still fail.
  mktranscript "$HW/.claude/plans/ghost.md"
  [ -z "$(runhook "$HW/transcript.jsonl")" ] \
    && ok "a plan path that does not exist is refused" \
    || no "hook accepted an unreadable plan path"

  # The last mention wins, so a later plan supersedes an earlier one.
  printf 'You should create your plan at %s\nYou should create your plan at %s\n' \
    "$HW/.claude/plans/old.md" "$HW/.claude/plans/draft.md" > "$HW/transcript.jsonl"
  runhook "$HW/transcript.jsonl" | grep -q 'draft.md' \
    && ok "the most recent plan mention wins" || no "hook picked a stale plan path"

  [ -z "$(runhook "/nonexistent/transcript.jsonl")" ] \
    && ok "an unreadable transcript exits quietly" || no "hook emitted output without a transcript"

  [ -z "$(printf 'not json' | "$HOOK" 2>/dev/null)" ] \
    && ok "a malformed payload exits quietly" || no "hook emitted output for a malformed payload"
fi

printf '\n%s\n' "-----------------------------"
printf 'passed: %d   failed: %d\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
