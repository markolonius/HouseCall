## 1. Navigation & entry

- [x] 1.1 Remove the `TabView` from `MainAppView` (`HouseCallApp.swift`); show a single chat as the root authenticated view.
- [x] 1.2 Add an auto-launch path: on login, open the patient's most-recent conversation, or create one if none exists, and present `ChatView` directly (no list, no "New Chat").
- [x] 1.3 Add a Profile button to the top-right of the chat toolbar that presents the profile (about + logout); remove the standalone Profile tab.
- [x] 1.4 Stop routing to `ConversationListView` from the authenticated entry point.

## 2. Remove provider configuration from the patient UI

- [x] 2.1 Remove the provider picker menu and provider badge from `ChatView` toolbar.
- [x] 2.2 Remove the "AI Provider Settings" `NavigationLink` and `LLMProviderSettingsView` sheet from Profile / chat.
- [x] 2.3 Remove `switchProvider` from `ConversationViewModel` (and any provider-switch system messages no longer reachable).
- [x] 2.4 Introduce a hardcoded default provider + API key sourced from build config; wire `AIConversationService` to always use it.

## 3. Fix streaming

- [x] 3.1 Trace the SSE → `streamingText`/`streamingMessageId` publish path in `AIConversationService` and confirm chunks are published on the main actor as they arrive.
- [x] 3.2 Ensure `ChatView` updates the bubble incrementally (streaming bubble or in-place message update) so tokens appear in real time.
- [x] 3.3 Verify auto-scroll keeps the latest streamed text visible and the input stays disabled until the stream completes.

## 4. Markdown rendering

- [ ] 4.1 Render assistant message content as Markdown in `MessageBubbleView` (headings, bold/italic, lists, inline code/code blocks, links).
- [ ] 4.2 Keep user messages as plaintext; ensure Markdown rendering does not break VoiceOver labels or PHI handling.

## 5. Tests

- [ ] 5.1 Update/remove tests covering provider selection and conversation-list navigation.
- [ ] 5.2 Add a streaming regression test asserting `streamingText` updates incrementally and the final message is persisted.
- [ ] 5.3 Add a Markdown rendering test for assistant bubbles.
- [ ] 5.4 Update `ChatInterfaceUITests` for single-chat entry + top-right profile button.
