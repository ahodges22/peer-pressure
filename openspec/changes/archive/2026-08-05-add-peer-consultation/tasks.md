## 1. Pin the Runtime Contract

- [x] 1.1 Add hermetic tests for valid consultation bundles, question-only bundles with absent or empty optional sections, and successful recommendation responses through both peer backends.
- [x] 1.2 Add tests for missing questions, missing recommendation labels, tolerated Markdown label variants, unknown flags, payload-only confinement, and structured peer failures.
- [x] 1.3 Pin existing plan-review and code-review status parsing, backend flags, and review failure payloads before refactoring shared execution.

## 2. Add Consultation Runtime Support

- [x] 2.1 Extract generic peer execution from `runReview` while leaving review status parsing and current error shapes unchanged.
- [x] 2.2 Extend context-path generation and CLI usage with `--kind consult` and the `consult --context-file PATH [--model NAME]` command.
- [x] 2.3 Parse the required question and optional context and candidate sections, omit empty optional sections from the peer payload, invoke the peer without repository context, and validate the bounded recommendation-label variants.
- [x] 2.4 Add the concise payload-only consultation prompt with explicit no-tool instructions and the agreed advice fields.

## 3. Add the Host Skill

- [x] 3.1 Create `skills/consult-peer/SKILL.md` with narrow explicit-request triggering and the exhaustive allowed invocation table.
- [x] 3.2 Implement the host workflow for initial-assessment disclosure, one-question briefing, neutral candidates, sensitive-context refusal, one-shot invocation, and exact retry only on the existing retry metadata.
- [x] 3.3 Implement the final synthesis contract for peer attribution, visible disagreement, claim verification, agreement caveats, and explicit consultation failure.

## 4. Update Product Surfaces

- [x] 4.1 Update repository and plugin usage documentation with consultation examples, one-shot behavior, payload-only limits, and peer quota cost.
- [x] 4.2 Update marketplace and plugin descriptions, keywords, interface text, and default prompts without changing release-managed version values or the installed plugin ID.

## 5. Verify the Change

- [x] 5.1 Run the full hermetic test suite and resolve only regressions caused by this change.
- [x] 5.2 Run strict OpenSpec validation and repository checks for manifest agreement, forbidden em dashes, and unintended files.
- [x] 5.3 Forward-test `consult-peer` with an explicit second-opinion request and confirm that the peer receives no host conclusion or repository tools.
