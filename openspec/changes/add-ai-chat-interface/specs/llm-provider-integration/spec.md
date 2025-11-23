# Specification: LLM Provider Integration

## ADDED Requirements

### Requirement: Support multiple LLM providers

The system shall support integration with OpenAI, Anthropic Claude, and custom/self-hosted LLM providers through a unified provider interface.

#### Scenario: OpenAI provider generates response

**Given** the conversation is configured to use OpenAI (GPT-4)
**When** the user sends the message "What are symptoms of flu?"
**Then** the system sends a request to `https://api.openai.com/v1/chat/completions`
**And** the request includes the Authorization header with Bearer token
**And** the request includes `stream: true` for streaming responses
**And** the system receives and parses SSE (Server-Sent Events) chunks
**And** the AI response streams to the UI

#### Scenario: Claude provider generates response

**Given** the conversation is configured to use Anthropic Claude
**When** the user sends a message
**Then** the system sends a request to `https://api.anthropic.com/v1/messages`
**And** the request includes `x-api-key` and `anthropic-version` headers
**And** the request includes `stream: true`
**And** the system parses Claude's SSE format correctly
**And** the response streams to the UI

#### Scenario: Custom provider generates response

**Given** the conversation is configured with a custom provider at `http://localhost:11434`
**When** the user sends a message
**Then** the system sends a request to the custom endpoint
**And** the request follows OpenAI-compatible format
**And** the system handles SSE responses from the custom server
**And** the response streams to the UI

---

### Requirement: Stream responses using Server-Sent Events

All LLM providers shall return streaming responses using SSE format to enable real-time token-by-token display.

#### Scenario: Parse OpenAI SSE stream

**Given** OpenAI returns an SSE stream:
```
data: {"choices":[{"delta":{"content":"Hello"}}]}

data: {"choices":[{"delta":{"content":" there"}}]}

data: [DONE]
```
**When** the SSE parser processes the stream
**Then** "Hello" is extracted from the first chunk
**And** " there" is extracted from the second chunk
**And** the [DONE] marker signals completion
**And** the full message "Hello there" is assembled

#### Scenario: Handle partial SSE chunks

**Given** an SSE chunk arrives split across two network packets:
```
Packet 1: "data: {\"choices\":[{\"delta\":{\"con"
Packet 2: "tent\":\"Hello\"}}]}\n\n"
```
**When** the SSE parser receives both packets
**Then** the parser buffers incomplete chunks
**And** waits for the complete message
**And** extracts "Hello" once the full chunk is received

---

### Requirement: Implement provider-specific authentication

Each LLM provider shall use its required authentication mechanism securely.

#### Scenario: OpenAI authentication with API key

**Given** the OpenAI API key is stored in Keychain
**When** a request is made to OpenAI
**Then** the API key is retrieved from Keychain
**And** the Authorization header is set to `Bearer {api_key}`
**And** the API key is never logged or exposed in error messages

#### Scenario: Claude authentication with API key and version

**Given** the Claude API key is stored in Keychain
**When** a request is made to Anthropic
**Then** the `x-api-key` header is set to the API key
**And** the `anthropic-version` header is set to "2023-06-01"
**And** the `content-type` header is set to "application/json"

#### Scenario: Custom provider with optional authentication

**Given** a custom provider URL is configured without an API key
**When** a request is made to the custom provider
**Then** no authentication headers are sent
**And** the request uses only the base URL and payload

---

### Requirement: Handle provider errors gracefully

The system shall detect and handle provider-specific errors with appropriate retry logic and user feedback.

#### Scenario: OpenAI rate limit error (429)

**Given** OpenAI returns HTTP 429 with rate limit headers
**When** the error is received
**Then** the system reads the `retry-after` header (e.g., 60 seconds)
**And** displays "Rate limit exceeded. Retry in 60s"
**And** disables sending for 60 seconds
**And** automatically retries after the wait period

#### Scenario: Authentication failure (401)

**Given** the API key is invalid or revoked
**When** the provider returns HTTP 401
**Then** the system logs an authentication error (without exposing the key)
**And** displays "API authentication failed. Check your settings."
**And** provides a button to navigate to provider configuration
**And** does not retry automatically

#### Scenario: Network timeout

**Given** a request to any provider exceeds 30 seconds
**When** the timeout occurs
**Then** the streaming request is cancelled
**And** an error displays "Request timed out"
**And** the user can manually retry
**And** the partial response (if any) is discarded

---

### Requirement: Manage conversation context across providers

When switching providers, the system shall maintain conversation history and context appropriately.

#### Scenario: Switch from OpenAI to Claude mid-conversation

**Given** a conversation has 4 messages using OpenAI:
- User: "I have a headache"
- AI: "I understand. How severe is the headache?"
- User: "It's moderate, started this morning"
- AI: "Thank you for providing that context."
**When** the user switches to Claude for the next message
**Then** the full message history is sent to Claude
**And** Claude receives all 4 previous messages for context
**And** the Claude response continues the conversation naturally
**And** all messages are stored with their original provider metadata

---

### Requirement: Implement retry logic with exponential backoff

Transient network errors shall be handled with intelligent retry logic to improve reliability.

#### Scenario: Retry on network failure

**Given** a request to OpenAI fails with a network error
**When** the first retry attempt occurs
**Then** the system waits 1 second before retrying
**When** the second retry attempt occurs
**Then** the system waits 2 seconds before retrying
**When** the third retry attempt occurs
**Then** the system waits 4 seconds before retrying
**And** if all 3 retries fail, display error to user

#### Scenario: Successful retry

**Given** a request fails with a transient network error
**When** the second retry attempt succeeds
**Then** the streaming response proceeds normally
**And** the user sees no error message
**And** the retry attempts are logged to audit trail

---

### Requirement: Support provider-specific configuration

Each provider shall have configurable settings including model selection, temperature, max tokens, and system prompts.

#### Scenario: Configure OpenAI model selection

**Given** the user opens provider settings
**When** the user selects OpenAI as the provider
**Then** available models are displayed: "GPT-4", "GPT-4-Turbo", "GPT-3.5-Turbo"
**And** the user can select a model
**And** the selected model is used for all future requests to OpenAI

#### Scenario: Configure custom provider endpoint

**Given** the user wants to use a local Ollama instance
**When** the user enters base URL "http://localhost:11434"
**And** the user selects model "llama3"
**Then** the configuration is saved securely
**And** requests are sent to the custom endpoint
**And** the OpenAI-compatible format is used

#### Scenario: Configure temperature and max tokens

**Given** the user is configuring a provider
**When** the user sets temperature to 0.7 and max_tokens to 1000
**Then** all API requests include these parameters:
```json
{
  "temperature": 0.7,
  "max_tokens": 1000
}
```

---

### Requirement: Implement provider fallback mechanism

The system shall support automatic fallback to alternative providers when the primary provider fails.

#### Scenario: Fallback from OpenAI to Claude on failure

**Given** OpenAI is configured as primary and Claude as fallback
**When** OpenAI returns HTTP 503 (service unavailable)
**And** the retry attempts fail
**Then** the system automatically switches to Claude
**And** the user message is resent to Claude
**And** a notification displays "Switched to Claude (OpenAI unavailable)"
**And** the conversation continues normally

#### Scenario: No fallback available

**Given** only OpenAI is configured (no fallback)
**When** OpenAI fails and retries are exhausted
**Then** an error is displayed to the user
**And** no automatic fallback occurs
**And** the user can manually retry or configure a fallback provider

---

### Requirement: Log all provider interactions for audit compliance

All LLM API calls shall be logged to the audit trail for HIPAA compliance.

#### Scenario: Log successful API interaction

**Given** a user sends a message "I feel dizzy"
**When** the OpenAI API returns a response successfully
**Then** an audit log entry is created with:
- Event type: "ai_interaction"
- User ID: (encrypted user identifier)
- Conversation ID: (conversation UUID)
- Provider: "openai"
- Model: "gpt-4"
- Token count: (total tokens used)
- Success: true
- Timestamp: (ISO 8601 format)
**And** the message content is NOT logged (PHI protection)

#### Scenario: Log failed API interaction

**Given** a request to Claude fails with HTTP 500
**When** the error is handled
**Then** an audit log entry is created with:
- Event type: "ai_interaction_failed"
- Provider: "claude"
- Error code: 500
- Success: false
**And** the error response body is NOT logged (may contain PHI)
