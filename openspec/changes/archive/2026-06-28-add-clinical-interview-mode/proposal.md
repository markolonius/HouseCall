# Proposal: Clinical History-Taking Interview Mode

## Why

The chat assistant currently behaves like a generic chatbot: a single system
prompt (`HealthcareSystemPrompt.default`) instructs the model to "collect
patient symptoms" but imposes no turn discipline, no history-taking structure,
and no length limit, while the provider default `maxTokens` is 1000. The result
is that the model answers each message with a large block of text instead of
conducting a focused, one-question-at-a-time clinical interview. This is the
wrong interaction model for a patient-facing intake tool: a clinician taking a
history asks a single targeted question, waits for the answer, and narrows from
there. The heavy-text experience also degrades on the small local model
(`medgemma:4b`) used for manual MVP testing, which stays more coherent in short
turns.

## What Changes

- **MODIFIED**: The healthcare system prompt becomes a structured clinical
  history-taking prompt — clinician persona, one question per turn, brief
  empathic acknowledgment, an OPQRST-based HPI framework, open-then-focused
  questioning, and an explicit length constraint per turn. Includes a short
  few-shot exemplar of the desired interview cadence (highest-ROI lever for a
  4B model).
- **MODIFIED**: Interview-turn generation parameters are constrained — a low
  `maxTokens` budget for gathering turns to physically cap response length, with
  a larger budget reserved for the final summary turn.
- **NEW**: The conversation tracks an interview phase (`gathering` → `summary`)
  so summarization is an explicit, controllable step rather than something the
  model self-decides inconsistently.
- **NEW**: A "summarize now" affordance in the chat UI lets the patient end the
  interview and request the assistant's summary, preliminary guidance, and
  triage/red-flag advice.
- **UNCHANGED**: All existing safety rails — no definitive diagnoses, emergency
  red-flag escalation, "not a substitute for professional advice", HIPAA
  encryption and audit logging.

## Impact

- **Affected specs**: `ai-chat-interface` (interview behavior, phase tracking,
  summarize-now UI), `llm-provider-integration` (clinical system prompt,
  interview-turn length constraints).
- **Affected code**: `Core/Services/LLMProvider.swift` (`HealthcareSystemPrompt`),
  `Core/Services/AIConversationService.swift` (phase state, summary turn,
  per-phase token budget), `Core/Services/LLMProviders/*` + provider configs
  (max-tokens plumbing), `Features/Conversation/ViewModels/ConversationViewModel.swift`
  and `Features/Conversation/Views/ChatView.swift` (summarize-now control).
- **Out of scope**: Diagnosis or triage decision logic beyond prompt guidance,
  any change to the provider abstraction or streaming transport, structured
  extraction of history into discrete data fields (future work), multi-language
  interviews.
