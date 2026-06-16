# Change: Simplify patient chat to a single zero-config streaming conversation

## Why

The chat surface still exposes LLM plumbing to the patient — provider pickers,
an "AI Provider Settings" screen, a conversation list, and a "New Chat" button —
none of which belong in a consumer healthcare app. The patient should land in a
working conversation immediately after login. Two defects compound this: the
assistant response does not visibly stream, and assistant text renders as flat
plaintext with no Markdown formatting.

## What Changes

- **BREAKING**: Remove the bottom `TabView`. After login the patient is taken
  straight into a chat (no conversation list, no "New Chat" step).
- **BREAKING**: Remove the in-chat LLM provider picker/badge and the
  "AI Provider Settings" screen from Profile. The patient never sees or selects
  a provider.
- Provider + API key become a **hardcoded app default** (build config), used by
  every conversation. No user-facing provider configuration remains.
- Replace the tab bar with a single **Profile button in the top-right** of the
  chat toolbar (logout + about live there).
- **Fix streaming**: assistant responses must visibly render token-by-token in
  the bubble as SSE chunks arrive (currently they do not update incrementally).
- Add **Markdown rendering** for assistant messages (headings, bold, lists,
  code, links).

## Impact

- Affected specs: `ai-chat-interface` (MODIFIED/REMOVED/ADDED),
  `llm-provider-integration` (ADDED hardcoded default).
- Affected code:
  - `HouseCall/HouseCallApp.swift` — `MainAppView` tab bar → single chat + profile toolbar button.
  - `HouseCall/Features/Conversation/Views/ChatView.swift` — remove provider menu/badge; add Markdown rendering; profile toolbar item.
  - `HouseCall/Features/Conversation/Views/MessageBubbleView.swift` — Markdown.
  - `HouseCall/Features/Conversation/ViewModels/ConversationViewModel.swift` — drop `switchProvider`; verify streaming publish path.
  - `HouseCall/Core/Services/AIConversationService.swift` — incremental `streamingText` publish fix.
  - `HouseCall/Features/Settings/**` — `LLMProviderSettingsView` no longer reachable from Profile.
  - Auto-launch helper (open most-recent or create conversation on login).
- Supersedes the provider-selection and conversation-list UX from
  `add-ai-chat-interface`.
