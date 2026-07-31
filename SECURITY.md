# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's
[private vulnerability reporting](https://github.com/ahodges22/peer-pressure/security/advisories/new).
Do not open a public issue for a security problem.

Please include the version, the host and peer CLI pair, the command you ran, and
what you expected to happen instead. A minimal repository that reproduces the
issue helps most.

Expect an initial response within 7 days. If a report is confirmed, the fix ships
in the next release and the advisory is published once it is available.

## Supported versions

Only the latest release receives fixes. Both hosts install from the marketplace
at the version in `plugin.json`, so upgrading means running a marketplace update
rather than patching in place.

## In scope

- A bypass of the secret-exclusion filter that puts a secret-bearing file into
  the payload despite `--include-secrets` not being passed.
- A bypass of the `--repo-context` preflight that lets a review start while
  secret-bearing files exist in the tree.
- A path escape in the plan-mode hook, meaning any path outside
  `.claude/plans/*.md` reaching the injected context.
- Host and peer confusion, meaning any input that makes the host review its own
  output instead of handing the review to the other CLI.
- Command or argument injection into the runtime, the bash shims, or the GitHub
  Actions workflows.
- Any path that sends payload content somewhere other than the peer CLI.

## Not in scope

These are documented limitations, not defects. They are stated in the runtime's
own output and in the skills, and reports about them will be closed as working
as intended.

- **Secret detection matches filenames, not content.** A credential pasted into
  an ordinary source or config file is not detected and will be sent to the
  peer. This limitation is documented in the `code-review` skill and repeated in
  the runtime's own `secret_files_in_tree` message.
- **The peer's sandbox does not restrict reads by path.** Codex reviews run
  under an OS-enforced read-only sandbox, but that sandbox can read files
  outside the repository, including `~/.ssh` and `~/.aws`. The Claude Code peer
  is confined by tool policy rather than by the OS. `detect` reports both facts
  in `reviewConfinement`.
- **Prompt instructions are not a security boundary.** Text in the review
  prompts that tells the peer not to read something is guidance, not
  enforcement.
- **Anything behind an explicit opt-in.** `--include-secrets` disables secret
  filtering by design. That is the flag's purpose.
- **A missing `jq` disables the plan-mode hook silently.** The hook exits
  without output rather than failing the host. This is deliberate.

Vulnerabilities in Claude Code or the Codex CLI themselves belong upstream with
those projects, not here.
