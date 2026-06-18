# Design: AI Chat Interface

## Architecture Overview

The AI Chat Interface follows a layered architecture with clear separation between UI, business logic, and data persistence layers, adhering to MVVM pattern and HIPAA security requirements.

```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer (SwiftUI)                    │
│  ┌──────────────────┐  ┌──────────────────┐                │
│  │   ChatView       │  │ ConversationList │                │
│  │ MessageBubbleView│  │      View        │                │
│  └──────────────────┘  └──────────────────┘                │
└─────────────────────────────────────────────────────────────┘
                           ↓ ObservableObject
┌─────────────────────────────────────────────────────────────┐
│                    ViewModel Layer                           │
│  ┌──────────────────────────────────────────┐               │
│  │      ConversationViewModel               │               │
│  │  - Current conversation state            │               │
│  │  - Message sending/receiving             │               │
│  │  - Streaming response handling           │               │
│  └──────────────────────────────────────────┘               │
└─────────────────────────────────────────────────────────────┘
                           ↓ Calls
┌─────────────────────────────────────────────────────────────┐
│                    Service Layer                             │
│  ┌──────────────────────────────────────────┐               │
│  │      AIConversationService               │               │
│  │  - Multi-provider LLM management         │               │
│  │  - Message orchestration                 │               │
│  │  - Audit logging integration             │               │
│  └──────────────────────────────────────────┘               │
└─────────────────────────────────────────────────────────────┘
                           ↓ Uses
┌─────────────────────────────────────────────────────────────┐
│                  LLM Provider Layer                          │
│  ┌────────────┐  ┌──────────────┐  ┌───────────────┐       │
│  │ LLMProvider│  │OpenAIProvider│  │ClaudeProvider │       │
│  │ (Protocol) │  │              │  │               │       │
│  └────────────┘  └──────────────┘  └───────────────┘       │
│                   ┌──────────────┐                          │
│                   │CustomProvider│                          │
│                   └──────────────┘                          │
└─────────────────────────────────────────────────────────────┘
                           ↓ Persists via
┌─────────────────────────────────────────────────────────────┐
│                Data Persistence Layer (Core Data)            │
│  ┌──────────────┐  ┌─────────────┐                         │
│  │ Conversation │  │   Message   │                         │
│  │   Entity     │  │   Entity    │                         │
│  └──────────────┘  └─────────────┘                         │
│  (Encrypted storage via EncryptionManager)                  │
└─────────────────────────────────────────────────────────────┘
```

## Component Design

### 1. Core Data Entities

#### Conversation Entity
```swift
@objc(Conversation)
public class Conversation: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var userId: UUID
    @NSManaged public var title: String  // Encrypted
    @NSManaged public var encryptedTitle: Data
    @NSManaged public var createdAt: Date
    @NSManaged public var updatedAt: Date
    @NSManaged public var isActive: Bool
    @NSManaged public var llmProvider: String  // "openai", "claude", "custom"
    @NSManaged public var messages: NSSet?
}
```

#### Message Entity
```swift
@objc(Message)
public class Message: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var conversationId: UUID
    @NSManaged public var role: String  // "user", "assistant", "system"
    @NSManaged public var encryptedContent: Data  // Encrypted message text
    @NSManaged public var timestamp: Date
    @NSManaged public var tokenCount: Int32
    @NSManaged public var streamingComplete: Bool
    @NSManaged public var conversation: Conversation
}
```

### 2. LLM Provider Protocol

```swift
protocol LLMProvider {
    var providerType: LLMProviderType { get }
    var isConfigured: Bool { get }

    func streamCompletion(
        messages: [ChatMessage],
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws

    func cancelStreaming()
}

enum LLMProviderType: String, CaseIterable {
    case openai = "openai"
    case claude = "claude"
    case custom = "custom"
}

struct ChatMessage {
    let role: MessageRole
    let content: String
}

enum MessageRole: String {
    case system, user, assistant
}
```

### 3. Provider Implementations

#### OpenAI Provider
- **API**: OpenAI Chat Completions API (gpt-4, gpt-3.5-turbo)
- **Streaming**: Server-Sent Events (SSE) via `stream: true`
- **Authentication**: Bearer token in Authorization header
- **Configuration**: API key stored in secure configuration (KeychainManager)
- **Endpoint**: `https://api.openai.com/v1/chat/completions`

#### Anthropic Claude Provider
- **API**: Anthropic Messages API
- **Streaming**: Server-Sent Events (SSE) with `stream: true`
- **Authentication**: `x-api-key` header + `anthropic-version` header
- **Configuration**: API key in KeychainManager
- **Endpoint**: `https://api.anthropic.com/v1/messages`

#### Custom Provider
- **API**: OpenAI-compatible endpoint (Ollama, llama.cpp, etc.)
- **Streaming**: SSE format compatible with OpenAI spec
- **Authentication**: Configurable (API key, none, or custom auth)
- **Configuration**: Custom base URL + optional API key
- **Endpoint**: User-provided URL (e.g., `http://localhost:11434/v1/chat/completions`)

### 4. Streaming Implementation

#### Server-Sent Events Parser
```swift
class SSEParser {
    func parse(data: Data, onEvent: (SSEEvent) -> Void) {
        // Parse SSE format:
        // data: {"chunk": "text"}
        //
        // data: [DONE]
    }
}

struct SSEEvent {
    let data: String
    let isComplete: Bool
}
```

#### Streaming Flow
1. User sends message → ViewModel → Service
2. Service saves user message to Core Data (encrypted)
3. Service calls LLMProvider.streamCompletion()
4. Provider makes HTTP request with `stream: true`
5. Provider receives SSE chunks, calls `onChunk` callback
6. ViewModel appends chunks to @Published message text
7. SwiftUI re-renders with new text
8. On completion, Service saves assistant message to Core Data
9. Audit log records interaction

### 5. Security Architecture

#### Encryption Flow
```
User Message (plaintext)
    ↓
EncryptionManager.encryptString(message, for: userId)
    ↓
Encrypted Data (AES-256-GCM)
    ↓
Core Data (encryptedContent field)
```

#### Decryption Flow
```
Core Data (encryptedContent field)
    ↓
EncryptionManager.decryptString(data, for: userId)
    ↓
Plaintext Message
    ↓
Display in UI
```

#### Audit Logging
```swift
// Log every AI interaction
AuditLogger.log(
    eventType: .aiInteraction,
    userId: userId,
    details: [
        "conversationId": conversationId,
        "llmProvider": provider.providerType,
        "messageRole": role,
        "tokenCount": tokens,
        "streamingUsed": true
    ]
)
```

### 6. Error Handling Strategy

#### Provider-Level Errors
- **Network Errors**: Retry with exponential backoff (3 attempts)
- **Authentication Errors**: Alert user to check API key configuration
- **Rate Limit Errors**: Display wait time, queue request
- **Timeout Errors**: 30-second timeout, retry or cancel options

#### UI-Level Error States
- **Connection Failed**: Show offline indicator, queue message for retry
- **Streaming Interrupted**: Save partial response, offer retry
- **Invalid Configuration**: Guide user to settings for API key setup

### 7. Performance Considerations

#### Optimization Strategies
- **Message Batching**: Fetch last 50 messages per conversation
- **Pagination**: Load older messages on scroll (virtual scrolling)
- **Image Caching**: Cache message bubbles for smooth scrolling
- **Background Encryption**: Encrypt/decrypt messages off main thread
- **Streaming Throttle**: Update UI max every 50ms to avoid excessive renders

#### Memory Management
- **Conversation Limit**: Keep max 10 active conversations in memory
- **Message Pruning**: Clear old messages from memory after 100+ messages
- **Provider Cleanup**: Cancel ongoing streams when view disappears

### 8. Configuration Management

#### Provider Configuration Storage
```swift
struct LLMProviderConfig: Codable {
    let providerType: LLMProviderType
    let apiKey: String?  // Stored in Keychain, not here
    let baseURL: String?  // For custom providers
    let model: String?  // e.g., "gpt-4", "claude-3-opus"
    let systemPrompt: String  // Healthcare-specific instructions
    let maxTokens: Int
    let temperature: Double
}
```

Storage:
- **API Keys**: Keychain (kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
- **Config**: UserDefaults for non-sensitive settings
- **System Prompts**: Hardcoded in app for security

#### Default System Prompt
```
You are a medical AI assistant for HouseCall. Your role is to:
1. Collect patient symptoms and health information
2. Provide preliminary health guidance (NOT diagnoses)
3. Recommend when to seek immediate medical attention
4. Always emphasize that your responses are not a substitute for professional medical advice
5. Be empathetic, clear, and patient-centered

IMPORTANT:
- Never provide definitive diagnoses
- Always recommend consulting a physician for serious symptoms
- Recognize medical emergencies (chest pain, difficulty breathing, etc.) and advise immediate care
- Maintain patient confidentiality and privacy
```

## Testing Strategy

### Unit Tests
- ✅ SSE parser handles various formats correctly
- ✅ LLMProvider implementations handle errors gracefully
- ✅ Message encryption/decryption works correctly
- ✅ Audit logging captures all required fields

### Integration Tests
- ✅ End-to-end message flow (send → stream → persist → display)
- ✅ Provider switching maintains conversation context
- ✅ Streaming interruption and recovery

### UI Tests
- ✅ Chat view displays messages correctly
- ✅ Streaming responses render smoothly
- ✅ Error states display appropriately
- ✅ Conversation list navigation

### Security Tests
- ✅ Messages encrypted at rest (validate Core Data storage)
- ✅ API keys not exposed in logs or memory dumps
- ✅ Audit logs capture all AI interactions
- ✅ No PHI in error messages or crash reports

## Deployment Considerations

### API Key Management
- **Development**: Use environment variables or .xcconfig files (not committed)
- **Production**: Secure backend configuration service (future)
- **Testing**: Mock providers for UI tests

### HIPAA Compliance Checklist
- ✅ All conversation data encrypted at rest (AES-256-GCM)
- ✅ API calls use TLS 1.2+ (enforced by URLSession)
- ✅ Audit logs for all AI interactions
- ✅ No PHI in logs or analytics
- ✅ Secure API key storage (Keychain)
- ✅ User consent for AI interactions (authentication required)
- ✅ Business Associate Agreements with LLM providers

### Monitoring & Observability
- **Metrics to Track**:
  - First token latency (P50, P95, P99)
  - Full response time
  - Streaming chunk rate
  - Error rate by provider
  - Token usage by conversation
  - API cost tracking

### Future Enhancements
1. **Voice Integration**: AVFoundation + Speech framework
2. **Context Management**: Smart conversation summarization for long chats
3. **Multi-turn Optimization**: Compress conversation history
4. **Provider Fallback**: Auto-switch on provider failure
5. **Custom Fine-tuned Models**: Healthcare-specific model support
6. **FHIR Integration**: Pull patient data into conversation context
