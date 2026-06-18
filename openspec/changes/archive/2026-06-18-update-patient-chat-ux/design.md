## Context

The chat surface was built (`add-ai-chat-interface`) as a power-user, multi-
provider tool: conversation list, in-chat provider switching, and a settings
screen for keys/model/temperature. The product is a consumer healthcare app
where the patient must never see LLM plumbing. This change collapses the UX to a
single zero-config streaming conversation and fixes two defects (no visible
streaming, no Markdown).

## Goals / Non-Goals

- Goals: single-chat entry after login; remove all patient-facing provider
  config; profile reachable from a toolbar button; visible token streaming;
  Markdown for assistant messages.
- Non-Goals: changing the cloud/physician-in-loop recommendation-card path;
  multi-conversation management; in-app provider switching; deleting the
  underlying repositories or `LLMProviderConfigManager` internals.

## Decisions

- **Provider is a hardcoded build-config default.** A single provider + key are
  read from build configuration and used for all conversations. Keep
  `LLMProviderConfigManager` as the internal seam but drive it from the default
  rather than user input. Keychain key storage remains for the chosen default;
  no user entry path.
  - Alternatives: keep settings UI but hide the link (rejected — leaves dead
    code reachable via deep links and tests); fully delete config layer
    (rejected — larger blast radius, cloud path may still need it).
- **Single-chat root, not a list.** Authenticated root resolves to the most-
  recent conversation or creates one. `ConversationListView` is retired from the
  authenticated entry point but left in the codebase until a follow-up removes
  it, to keep this change focused.
- **Profile as a toolbar sheet, not a tab.** Removes `TabView`; a top-right
  toolbar button presents profile (about + logout).
- **Markdown via SwiftUI `Text(AttributedString(markdown:))` / `Text(.init(...))`
  for assistant bubbles**, falling back to plain text on parse failure. User
  bubbles stay plaintext to avoid rendering patient input as markup.

## Risks / Trade-offs

- Streaming bug root cause unconfirmed — could be publish threading, Combine
  sink, or in-place vs streaming-bubble swap. Task 3.1 traces before fixing.
  → Mitigation: add a regression test asserting incremental `streamingText`.
- Markdown rendering of untrusted assistant output → keep it display-only; no
  HTML, no remote image loading; links rendered but not auto-opened.

## Migration Plan

Existing Core Data conversations are untouched; login opens the most-recent one.
No schema change. Provider field on stored conversations is ignored at runtime
in favor of the default.

## Open Questions

- Which build-config mechanism for the default key (xcconfig vs Info.plist vs
  compile-time) — resolve in task 2.4 against existing project conventions.
