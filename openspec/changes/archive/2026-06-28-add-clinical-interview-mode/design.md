# Design: Clinical History-Taking Interview Mode

## Goal

Convert the assistant from an essay-style chatbot into a clinician conducting a
focused patient history: one question per turn, short turns, a recognizable
history structure, and an explicit summary at the end.

## Primary lever: the system prompt

`HealthcareSystemPrompt.default` (in `Core/Services/LLMProvider.swift`) is the
single string injected as the leading `.system` message by
`AIConversationService.buildChatContext`. Rewriting it is the highest-impact,
lowest-risk change and is provider-agnostic (OpenAI/Claude/Custom all consume
the same context).

New prompt requirements:

- **Persona**: a careful clinician taking a focused history, not an information
  service.
- **Turn discipline**: ask exactly ONE question per turn; wait for the answer
  before asking the next.
- **Brevity**: ≤ 2 short sentences plus a single question. A brief empathic
  acknowledgment is allowed; lectures and bulleted explanations are not.
- **Structure**: chief complaint → HPI via OPQRST (Onset, Provocation/
  Palliation, Quality, Region/Radiation, Severity, Timing) → targeted ROS, PMH,
  medications, allergies, and relevant social/family history.
- **Questioning style**: open-ended first ("What brings you in today?"), then
  focused/closed questions to narrow.
- **Red-flag override**: emergency features (chest pain, difficulty breathing,
  severe bleeding, stroke signs, etc.) interrupt the interview and advise
  immediate care.
- **Summary turn**: only when asked to summarize (or after sufficient history),
  produce a concise summary, preliminary non-diagnostic guidance, and
  triage/red-flag advice with the standard professional-care disclaimer.
- **Few-shot exemplar**: 2–3 short example turns embedded in the prompt to lock
  the cadence. Empirically the strongest lever for a 4B model.

Two prompt variants are defined: `HealthcareSystemPrompt.interview` (gathering)
and `HealthcareSystemPrompt.summary` (closing turn). `buildChatContext` selects
the variant from the conversation's interview phase.

## Secondary lever: generation parameters

A small token budget physically caps turn length even if the model ignores the
prompt. `AIConversationService` supplies a per-phase budget when constructing
the request:

- Gathering turns: ~160 tokens.
- Summary turn: ~512 tokens (room for the structured summary).

This requires threading a per-request `maxTokens` override through the provider
call path. The provider configs already carry a `maxTokens` field; the override
is applied for the active request without mutating stored config. Temperature is
left at provider default initially; lowering it is a tunable follow-up, not a
hard requirement.

## Interview phase state

Phase is a property of the conversation, defaulting to `gathering`. It is held
in `AIConversationService` (and surfaced to the view model) rather than the
prompt, so summarization is deterministic and testable.

- `gathering`: normal interview turns, interview prompt + small token budget.
- `summary`: triggered by the summarize-now action (or a future heuristic).
  The next assistant turn uses the summary prompt + larger budget, then the
  phase returns to `gathering` so the patient can continue if they wish.

Phase is in-memory for this change (no Core Data schema change); a conversation
reopened later starts in `gathering`. Persisting phase is deferred.

## UI: summarize-now affordance

`ChatView` gains a control (toolbar button or an inline action above the input)
labeled e.g. "Summarize" that calls a new `ConversationViewModel.requestSummary()`.
It is disabled while streaming and when there are no user messages yet. Standard
accessibility identifier added for UI tests.

## Safety and HIPAA

No change to encryption, audit logging, or red-flag obligations. The summary is
explicitly preliminary and non-diagnostic. No PHI added to logs — phase
transitions log event name + identifiers only.

## Alternatives considered

- **Pure prompt, no state/UI**: simplest, but summarization timing becomes
  model-dependent and inconsistent on a small model. Rejected per scope
  decision to include phase-2 state.
- **Structured field extraction** (parse history into discrete data): valuable
  but much larger; deferred to future work.
