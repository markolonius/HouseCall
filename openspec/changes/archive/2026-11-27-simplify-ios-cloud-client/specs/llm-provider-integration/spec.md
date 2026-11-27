# llm-provider-integration (delta)

## REMOVED Requirements

### Requirement: Support multiple LLM providers
**Reason**: The iOS app no longer calls a model. All model calls are made server-side by the AI Agent Runtime, behind physician review.
**Migration**: None. Model configuration lives in the backend (`ai-agent-runtime`).

### Requirement: Stream responses using Server-Sent Events
**Reason**: No on-device model calls remain; assistant messages arrive over message sync and WebSocket.
**Migration**: None.

### Requirement: Implement provider-specific authentication
**Reason**: No vendor API keys exist on the device.
**Migration**: Any keys previously stored in the Keychain are no longer read; they are left to be cleared on next logout.

### Requirement: Handle provider errors gracefully
**Reason**: Model errors are handled server-side (`ai-agent-runtime`: model endpoint unavailable).
**Migration**: None.

### Requirement: Manage conversation context across providers
**Reason**: Conversation context is assembled server-side.
**Migration**: None.

### Requirement: Implement retry logic with exponential backoff
**Reason**: No on-device model calls remain. Network retry for Core API calls is covered by `ios-cloud-sync` offline queue and replay.
**Migration**: None.

### Requirement: Support provider-specific configuration
**Reason**: No on-device model configuration remains.
**Migration**: None.

### Requirement: Implement provider fallback mechanism
**Reason**: No on-device model calls remain.
**Migration**: None.

### Requirement: Log all provider interactions for audit compliance
**Reason**: AI interactions are audited server-side (`core-api`: Audit Logging).
**Migration**: None.

### Requirement: Use a hardcoded default provider with no user configuration
**Reason**: No on-device provider remains to default.
**Migration**: None.

### Requirement: Use a clinical history-taking system prompt
**Reason**: The interview prompt lives server-side in the AI Agent Runtime.
**Migration**: None.

### Requirement: Constrain interview-turn response length
**Reason**: Interview turns are produced server-side.
**Migration**: None.
