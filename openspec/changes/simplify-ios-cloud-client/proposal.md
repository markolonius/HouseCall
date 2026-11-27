# Proposal: Simplify the iOS App to a Cloud Client

## Why

The iOS app still carries its pre-cloud architecture alongside the cloud one,
and the two are selected silently at launch:

- `HouseCallApp.swift` builds a `CloudSyncCoordinator` only when a Core API base
  URL **and** a cached JWT are present. Otherwise `AIConversationService` takes
  its "legacy path" (`AIConversationService.swift:200`) and streams the
  patient's chat directly to OpenAI, Anthropic or a custom endpoint from the
  device.
- That fallback is reachable in cloud-configured builds, not only in dev builds:
  when the Core API rejects an expired token the app clears it and deactivates
  cloud sync (`Core API Session Token Lifecycle`), and on the next launch, with
  no token, the chat runs on the direct path.
- On that path PHI leaves the device for a model vendor with no BAA, and the
  response reaches the patient with no physician review. Both contradict the
  core product rule (`physician-in-loop`: no patient delivery without a
  physician transition) and the positioning promise that patient data is never
  sent to a third-party model vendor.
- `AuthenticationService` likewise keeps a local-only account path when the
  Core API is not configured, and a 6-digit passcode method the Core API does
  not use.

About 3,000 lines of iOS code (`Core/Services/LLMProviders/`,
`LLMProviderConfigManager`, `Features/Settings/`, `LLMProvider.swift`) exist only
to serve the direct path.

## What Changes

- **REMOVED**: the `llm-provider-integration` capability. The app never calls a
  model; all model calls happen server-side in the AI Agent Runtime.
- **REMOVED**: on-device streaming of AI responses. Assistant and agent
  messages arrive whole over the message-sync and WebSocket channels.
- **REMOVED**: the 6-digit passcode authentication method. Patients sign in
  with email + password against the Core API; Face ID / Touch ID unlocks a
  previously authenticated session.
- **MODIFIED**: cloud activation. The chat requires the Core API. Without a
  valid token the app shows cached history read-only and asks the patient to
  sign in; it never falls back to a direct model call.
- **ADDED**: the app requires a configured Core API. A build without
  `CORE_API_BASE_URL` / `CORE_API_TENANT_ID` shows a configuration error
  instead of creating local-only accounts.
- **MODIFIED**: first-launch conversation creation no longer references a
  model provider.

## Impact

- **Affected specs**: `llm-provider-integration` (all requirements removed),
  `ai-chat-interface`, `ios-cloud-sync`, `authentication`.
- **Affected code**: `HouseCall/Core/Services/LLMProviders/`,
  `HouseCall/Core/Services/LLMProvider.swift`,
  `HouseCall/Core/Services/LLMProviderConfigManager.swift`,
  `HouseCall/Features/Settings/`, `AIConversationService.swift`,
  `AuthenticationService.swift`, `HouseCallApp.swift`, `Info.plist` and
  `Config/*.xcconfig` (`LLM_*` keys), and the matching tests
  (`OpenAIProviderTests`, `ClaudeProviderTests`, `CustomProviderTests`,
  `SSEParserTests`, `LLMProviderConfigManagerTests`, `APIKeySecurityTests`).
- **Unchanged**: the encrypted Core Data cache, the offline authentication
  fallback for previously authenticated patients, biometric unlock, and the
  `llmProvider` attribute on the Core Data `Conversation` entity (left in place
  and unused, to avoid a model migration in this change).
- **Dependencies**: none. Independent of `add-agent-care-loop`.
- **Out of scope**: SwiftUI modernisation (`ObservableObject` → `@Observable`,
  `NavigationView` → `NavigationStack`), the trust surface
  (`add-patient-trust-surface`), token refresh (`harden-auth-and-audit`).

## Open Questions

- Existing passcode users: there are no production users, so this change drops
  passcode accounts without migration. Confirm no test devices need them.
