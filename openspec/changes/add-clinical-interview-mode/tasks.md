# Tasks: Clinical History-Taking Interview Mode

## Phase 1: Clinical system prompt

### Task 1.1: Rewrite HealthcareSystemPrompt for interview mode  [x]
Replace `HealthcareSystemPrompt.default` with a clinician history-taking prompt
(persona, one-question-per-turn, brevity ≤2 sentences + single question, OPQRST
HPI structure, open-then-focused questioning, red-flag override, professional-
care disclaimer). Keep all existing safety constraints.

### Task 1.2: Add a few-shot interview exemplar  [x]
Embed 2–3 short example turns in the prompt demonstrating the desired short
interview cadence.

### Task 1.3: Add the summary prompt variant  [x]
Add `HealthcareSystemPrompt.summary` instructing a concise summary + preliminary
non-diagnostic guidance + triage/red-flag advice. Define `.interview` as the
gathering variant. Update `buildChatContext` to select the variant by phase.

## Phase 2: Interview-turn generation parameters

### Task 2.1: Thread a per-request maxTokens override through the provider path
Allow `AIConversationService` to pass a per-request `maxTokens` to the provider
for the current turn without mutating stored provider config (OpenAI, Claude,
Custom request bodies).

### Task 2.2: Apply per-phase token budgets
Use a small budget (~160) for gathering turns and a larger budget (~512) for the
summary turn.

## Phase 3: Interview phase state

### Task 3.1: Add interview phase to AIConversationService
Add a `gathering | summary` phase (default `gathering`), in-memory per
conversation. Gathering turns use the interview prompt + small budget.

### Task 3.2: Implement the summary turn transition
Add a service method that sets phase to `summary`, runs one assistant turn with
the summary prompt + larger budget, then returns phase to `gathering`. Log the
transition (event name + identifiers only, no PHI).

## Phase 4: Summarize-now UI

### Task 4.1: Expose requestSummary() on ConversationViewModel
Forward to the service summary-turn method; guard against empty conversations
and concurrent streaming.

### Task 4.2: Add the summarize control to ChatView
Add a "Summarize" control (disabled while streaming or with no user messages)
with an accessibility identifier, wired to `requestSummary()`.

## Phase 5: Tests and evaluation

### Task 5.1: Prompt and parameter unit tests
Assert the interview/summary prompt content invariants (one-question guidance,
disclaimer present, red-flag language) and the per-phase token budgets.

### Task 5.2: Phase-state and summary-turn tests
Cover the `gathering → summary → gathering` transition and that the summary turn
uses the summary prompt + larger budget (using the existing test provider
override).

### Task 5.3: Manual evaluation against local Ollama
Verify with `medgemma:4b` that gathering turns are short single questions and
the summarize action produces a coherent structured summary.
