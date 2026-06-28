# Tasks: Clinical SOAP Review Workflow

## Phase 1: Server-side interview engine (backend)

### Task 1.1: Add the clinical interview system prompt server-side  [x]
Add the clinician history-taking prompt to the agent runtime (one question per
turn, OPQRST, red-flag override, safety constraints, no-diagnosis) including the
no-repeat / no-re-ask-answered instructions and a few-shot exemplar that skips an
already-answered dimension. Define the completion marker constant
(`<READY_FOR_NOTE>`) shared by prompt and parser.

### Task 1.2: Generate an interview turn per patient message  [x]
Replace the single-shot guidance draft with an interview step: assemble the
tenant-scoped conversation, call the model, and produce the next turn. Add a
configurable max-interview-turn safety cap that forces note drafting if exceeded.

### Task 1.3: Detect the completion marker  [x]
Parse the model output for the marker: if present, strip it (and any trailing
text) and branch to note drafting; otherwise treat the output as an interview
question. Marker handling is server-side only and never patient-visible.

## Phase 2: SOAP note payload + drafting (backend)

### Task 2.1: Register the soap_note payload type  [x]
Add `soap_note` as a valid recommendation payload type in the domain layer with
validation that Subjective/Objective/Assessment/Plan are present; extend the
migration payload-type constraint if one exists. Lifecycle transitions unchanged.

### Task 2.2: Draft the SOAP note into PENDING_REVIEW  [x]
On marker detection, draft a `soap_note` recommendation (structured S/O/A/P
payload + human-readable `draft_content`) using the existing DRAFT→PENDING_REVIEW
transaction + audit + `queue.updated` pattern. Instruct the model not to
fabricate objective exam findings.

## Phase 3: Direct agent→patient interview channel (core-api + delivery)

### Task 3.1: Add a patient notifier + persist agent questions  [x]
Add a patient WebSocket notifier (analogue of PhysicianNotifier); persist each
agent interview question as an assistant message on the conversation and push it
to the patient's live socket. Audit with identifiers + event type only.

### Task 3.2: Enforce the delivery carve-out  [x]
Ensure interview questions (non-clinical) are the ONLY agent output delivered
directly; the SOAP note (clinical A/P) is never delivered by the agent — only via
the physician lifecycle. Add a guard/test asserting the agent has no code path to
deliver a soap_note.

## Phase 4: Physician SOAP review UI (physician-web-app)

### Task 4.1: Render the SOAP note in the review queue  [x]
Extend the review template so a `soap_note` recommendation displays the four
sections clearly, with Assessment and Plan presented as the physician's decision
focus.

### Task 4.2: Approve / modify / reject the Assessment & Plan
Wire approve (`approve`), edit-then-save (`modify` of A/P), and reject
(`reject`) using the existing review actions and state-licensing checks. No new
lifecycle states.

## Phase 5: iOS thin client

### Task 5.1: Remove the Summarize control + client summary path
Remove the ChatView "Summarize" toolbar button and the `requestSummary()`
client path for the cloud flow (retire client-side interview prompt/budget/phase
usage on the cloud path).

### Task 5.2: Route patient chat through cloud sync
For the SOAP flow, send patient messages via `CloudSyncCoordinator` and render
agent interview questions arriving over message sync / WebSocket as assistant
bubbles.

### Task 5.3: Render the delivered approved note
Render a DELIVERED `soap_note` recommendation to the patient as a recommendation
card (reuse `RecommendationCard`) showing the physician-approved plan.

## Phase 6: Tests and evaluation

### Task 6.1: Backend unit/integration tests
Cover: interview turn generation, marker detection + stripping, turn-cap forced
draft, soap_note payload validation, DRAFT→PENDING_REVIEW drafting, the
delivery carve-out (agent cannot deliver soap_note), and physician approve/modify/
reject of a soap_note with state-licensing.

### Task 6.2: iOS tests
Cover: Summarize control removed; cloud-sync send path; rendering of agent
interview questions and of a delivered soap_note card.

### Task 6.3: Manual end-to-end evaluation
With Postgres + core-api + agent (Ollama `medgemma:4b`) + physician web app
running: verify the interview does not repeat/re-ask, self-completes into a SOAP
note, the physician can approve/modify/reject A/P, and the approved plan is
delivered to the patient.
