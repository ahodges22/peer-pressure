## Context

The current runtime combines reusable peer execution with review-specific status parsing in `runReview`. Both shipped skills require iterative approval semantics. The new capability must reuse host detection, opposite-peer selection, confinement, payload limits, timeout handling, and transient-failure classification without weakening those review contracts. See `proposal.md` for motivation and `specs/peer-consultation/spec.md` for observable behavior.

## Goals / Non-Goals

**Goals:**

- Add one explicit, one-shot consultation path for open questions and decisions.
- Keep the peer's view independent from the host's initial assessment.
- Reuse the existing peer backends and structured error behavior.
- Make unusable peer responses fail clearly instead of accepting arbitrary non-empty text.
- Preserve existing plan-review and code-review behavior.

**Non-Goals:**

- Repository access, self-collection, or consultation-specific tools.
- Iteration, approval, findings, caching, response persistence, or multi-peer fan-out.
- Renaming the installed plugin or changing its release-managed version fields by hand.
- Automated arbitrary-text secret detection or an option to send known sensitive material.

## Decisions

### Add `consult-peer` inside the existing plugin

Create `skills/consult-peer/SKILL.md`, `scripts/prompts/consult.txt`, and a `consult` runtime subcommand. Keep the installed plugin ID `adversarial-review` because changing it would require a migration. Expand visible descriptions to cover cross-model consultation and adversarial review.

Alternatives considered:

- `second-opinion` communicates the non-binding result but is narrower than diagnostics and approach questions.
- A separate plugin would align its package name but duplicate peer detection and create another installation step.

### Record the host view before the call but exclude it from the payload

The skill writes a short initial assessment in commentary before constructing the consultation bundle. This gives the user an observable pre-peer position and reduces retrospective anchoring. The bundle contains only the question, factual context, and neutrally labeled candidates.

Do not add a critique mode in this change. Sending the host's reasoning to the peer changes the interaction from independent consultation to review.

### Use a fenced temporary context bundle

Extend `new-ctx` to accept `--kind consult`. The skill writes these sections:

```text
===== QUESTION START =====
<one focused question>
===== QUESTION END =====
===== CONTEXT START =====
<optional verified facts and constraints>
===== CONTEXT END =====
===== CANDIDATE APPROACHES START =====
<optional neutrally labeled candidates>
===== CANDIDATE APPROACHES END =====
```

The skill always writes all three sections, with empty bodies for unused optional sections. `QUESTION` is required and non-empty. The runtime also treats absent optional fences as empty and omits empty optional sections from the normalized peer payload. Reusing `parseBundle` keeps marker parsing consistent with the review commands and avoids passing long or multiline content through command arguments.

### Separate peer execution from review semantics

Extract a generic peer execution function from `runReview`. It owns host and peer checks, prompt loading, backend invocation, payload-size errors, timeout behavior, and provider-failure classification. It returns successful peer output without interpreting its domain semantics.

Keep review status parsing in a review wrapper. The consultation command performs its own recommendation-line validation after the generic call. This is simpler than injecting validator callbacks into generic execution and keeps each command's response contract visible at its call site.

### Require a recommendation line without adding approval status

The consultation prompt requires a recommendation label on the first non-empty line and requests no more than approximately 400 words. The runtime trims whitespace, disregards only immediately adjacent Markdown heading, list, emphasis, or code decoration, and compares `RECOMMENDATION:` case-insensitively without searching later lines. It returns the full text unchanged. This catches empty replies and tool-attempt-only replies while tolerating harmless formatting drift and avoiding the false authority of `APPROVED` or `CHANGES_REQUIRED`.

A missing marker returns `missing_recommendation_line`; it does not trigger an automatic format-correction request. The skill follows the existing single retry rule only when peer execution returns `retryable: true` and `retryInstruction: "rerun_same_command_once"`. The shared extraction preserves the current timeout, transient HTTP-status, stream-signature classification, and review failure fields byte-for-byte.

### Keep consultation payload-only

Call the generic peer runner without a repository working directory. Claude Code therefore receives no tools, and Codex runs in its existing ephemeral read-only directory with the git-repository check disabled. The prompt explicitly states that the payload is sufficient and forbids requesting or simulating tool calls.

The skill is responsible for selecting and sanitizing context. It must stop before invocation if the selected text contains known credentials, authentication tokens, private keys, personal data, or customer data. There is no `--include-secrets` escape hatch in this change.

### Preserve clear failure and synthesis behavior

Peer detection and execution failures remain `ok: false`; consultation does not silently degrade to success. The skill can still give the host's previously stated assessment, but it must say the peer did not respond.

On success, the skill presents the peer view separately before its synthesis. It keeps material disagreement visible, verifies factual claims when possible, labels unverified repository claims as assumptions, and warns that cross-model agreement is not verification.

## Risks / Trade-offs

- **Thin context produces generic advice**: Require one focused question and instruct the host to include only decision-relevant verified facts.
- **Free-form context can expose sensitive data**: Add a hard skill-level sanitization gate and no bypass in the first version.
- **A tool-disabled peer can still emit a textual tool attempt**: Require and validate the `RECOMMENDATION:` line.
- **Real models can decorate the required label with Markdown**: Normalize only adjacent decoration and keep later-line searches invalid.
- **Users can overvalue model agreement**: Require the final synthesis to distinguish agreement from verification.
- **Refactoring shared execution can regress reviews**: Pin existing review outputs and backend flags before adding consultation cases.
- **The initial host assessment adds conversational output**: Keep it to a concise position that the final synthesis can reference.

## Migration Plan

Add the capability without changing current command names or accepted review flags. Existing users receive the new skill when the normal release process publishes a release-managed version. Rollback removes the consultation skill, prompt, command, tests, and description changes while leaving the shared execution behavior equivalent to its pre-change contract.
