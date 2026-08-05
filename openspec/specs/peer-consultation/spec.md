# peer-consultation Specification

## Purpose
Provide a one-shot, non-binding opinion from the agent CLI that is not the host while preserving independence, context safety, and clear attribution.
## Requirements
### Requirement: Consultation requires an explicit user request
The skill SHALL invoke peer consultation only when the user explicitly asks for the other model's view, a second opinion, or peer consultation on one question.

#### Scenario: User requests the other model's view
- **WHEN** the user asks what Claude or Codex thinks about a question
- **THEN** the skill starts the peer consultation workflow

#### Scenario: User asks for ordinary brainstorming
- **WHEN** the user asks the host to brainstorm without requesting another model
- **THEN** the skill does not invoke the peer

### Requirement: The peer receives an independent consultation brief
Before invoking the peer, the host SHALL state a concise initial assessment in the conversation. The host SHALL exclude that assessment from the peer payload and SHALL send one neutral question, optional factual context, and optional candidate approaches without signaling a preferred candidate.

#### Scenario: Consultation compares candidate approaches
- **WHEN** the user asks for a second opinion on multiple approaches
- **THEN** the host states its initial assessment and sends the peer neutrally labeled candidates with relevant facts and constraints

#### Scenario: The question is self-contained
- **WHEN** the question needs no additional factual context
- **THEN** the skill writes empty optional bundle sections and the runtime omits them from the normalized peer payload

#### Scenario: The request contains multiple independent questions
- **WHEN** the user requests consultation on questions that cannot receive one focused answer
- **THEN** the host asks the user to select one question before invoking the peer

### Requirement: Consultation context excludes sensitive material
The skill SHALL inspect its selected payload context before invocation and SHALL exclude credentials, authentication tokens, private keys, personal data, and customer data. The first version SHALL provide no option to bypass this restriction.

#### Scenario: Selected context contains sensitive material
- **WHEN** the host identifies sensitive material in the proposed consultation payload
- **THEN** it does not invoke the peer and asks for or constructs sanitized context

### Requirement: The runtime uses the opposite peer without repository access
The runtime SHALL select the agent CLI that is not the detected host and SHALL run it with the existing payload-only confinement. A consultation SHALL not grant repository tools or accept a repository-context mode.

#### Scenario: Codex hosts a consultation
- **WHEN** Codex invokes the consultation command
- **THEN** the runtime sends only the consultation payload to Claude Code with tools disabled

#### Scenario: Claude Code hosts a consultation
- **WHEN** Claude Code invokes the consultation command
- **THEN** the runtime sends only the consultation payload to Codex in an ephemeral read-only working directory

### Requirement: The peer returns a direct recommendation
The consultation prompt SHALL require a recommendation label on the first non-empty response line. Validation SHALL trim whitespace, disregard only immediately adjacent Markdown heading, list, emphasis, or code decoration, and compare `RECOMMENDATION:` case-insensitively without searching later lines. The remaining response SHALL give concise reasons, tradeoffs, assumptions, confidence, and the missing information most likely to change the recommendation.

#### Scenario: Peer returns valid advice
- **WHEN** the peer call succeeds and its first non-empty line contains the required label with optional adjacent Markdown decoration
- **THEN** the runtime returns `ok: true`, the peer identifier, and the full unmodified peer output without a review status

#### Scenario: Peer returns no usable recommendation
- **WHEN** the peer output is empty or its first non-empty line does not contain the required label
- **THEN** the runtime returns `ok: false` with error `missing_recommendation_line` and includes the peer output for diagnosis

### Requirement: Consultation is one-shot and non-binding
The skill SHALL make one logical consultation request and SHALL not start an approval loop, finding ledger, corrective dialogue, or automatic follow-up. An exact retry remains permitted only when shared peer execution returns `retryable: true` and `retryInstruction: "rerun_same_command_once"`. The consultation SHALL reuse the existing timeout, transient HTTP-status, and provider-stream classification without changing review failure payloads. Any new consultation question requires an explicit user request.

#### Scenario: Peer recommends a different approach
- **WHEN** the peer disagrees with the host's initial assessment
- **THEN** the host evaluates the disagreement without sending a corrective response to the peer

#### Scenario: Peer identifies decisive missing information
- **WHEN** the peer names information that could materially change its recommendation
- **THEN** the host offers to determine that information and re-consult only through a new user-approved request

### Requirement: The host presents an attributed synthesis
After a successful consultation, the host SHALL present a labeled peer view, its own assessment, and a final recommendation. It SHALL preserve material disagreement, verify peer claims against available evidence before adopting them, and label unverified claims as assumptions. If both models agree, it SHALL state that agreement is not independent verification.

#### Scenario: Host and peer disagree
- **WHEN** the host rejects a material part of the peer recommendation
- **THEN** the final response reports the peer's position and explains the evidence for the host's different conclusion

#### Scenario: Host and peer agree
- **WHEN** the host and peer reach the same recommendation
- **THEN** the final response can collapse duplicate reasoning but states that model agreement is weak evidence rather than verification

### Requirement: Consultation failures remain explicit
The runtime SHALL preserve the existing structured peer failure contract. The skill MAY still present the host's initial assessment after a failure, but SHALL clearly state that no peer consultation completed.

#### Scenario: Peer is unavailable
- **WHEN** detection or invocation reports that the peer is unavailable
- **THEN** the skill reports the failure and does not describe the host-only answer as a peer consultation
