# Tasks: Simplify the iOS App to a Cloud Client

## Phase 1 — Remove the direct model path

- [x] 1.1 Remove the legacy send path from `AIConversationService`
  - `sendMessage` always routes through `CloudSyncCoordinator`; the service no longer takes an `LLMProviderConfigManager`.
  - When no coordinator is available, sending fails with a sign-in-required error and nothing leaves the device.
  - Unit test: with no coordinator, `sendMessage` makes no network call and surfaces the sign-in error.
- [x] 1.2 Delete the on-device provider stack
  - Delete `Core/Services/LLMProviders/`, `LLMProvider.swift`, `LLMProviderConfigManager.swift`, `Features/Settings/`.
  - Delete their tests (`OpenAIProviderTests`, `ClaudeProviderTests`, `CustomProviderTests`, `SSEParserTests`, `LLMProviderConfigManagerTests`, provider cases in `APIKeySecurityTests`).
  - Remove the `LLM_*` keys from `Info.plist`, `Base.xcconfig` and `Secrets.example.xcconfig`.
  - The user removes deleted files from the Xcode target (project files are hook-protected); the coder lists them.
- [x] 1.3 Create the first conversation without a provider
  - `HouseCallApp.resolveConversation` no longer reads a provider; new conversations leave the legacy `llmProvider` field at its Core Data default (no model migration).
  - `scripts/test.sh` passes.

## Phase 2 — Cloud-only chat and sign-in

- [x] 2.1 Require Core API configuration
  - `AuthenticationService` has no local-only register/login path; with no `CoreAPIBaseURL`/`CoreAPITenantID` the login screen shows a configuration error.
  - Unit tests cover the unconfigured build.
- [ ] 2.2 Read-only chat without a valid token
  - When the token is missing or rejected, the chat shows cached history, disables input, and offers sign-in.
  - After sign-in, cloud sync activates without restarting the app.
  - Unit tests cover the expired-token path end to end (401 → read-only → sign-in → active).
- [ ] 2.3 Remove the passcode authentication method
  - Remove passcode registration/login UI, `AuthMethod.passcode`, and passcode validation.
  - Biometric unlock and the offline fallback for previously authenticated patients keep working.
  - `scripts/test.sh` passes.

## Phase 3 — Verification

- [ ] 3.1 Grep check: no reference to `api.openai.com`, `api.anthropic.com`, `LLMProvider`, or `LLM_DEFAULT_` remains in `HouseCall/` or `HouseCallTests/`.
- [ ] 3.2 Manual smoke on the iOS 27.2 simulator against the compose stack: register, chat, token expiry (shorten TTL locally), read-only state, sign back in.
- [ ] 3.3 Update `CLAUDE.md` iOS sections and `docs/USER_GUIDE.md` for the removed settings and passcode; `openspec validate simplify-ios-cloud-client --strict`.
