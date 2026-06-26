//
//  LLMProvider.swift
//  HouseCall
//
//  Created by Claude Code on 2025-11-23.
//  HIPAA-compliant LLM provider abstraction layer
//

import Foundation

/// Protocol defining the interface for LLM (Large Language Model) providers
/// Supports multiple providers: OpenAI, Anthropic Claude, and custom/self-hosted models
protocol LLMProvider {
    /// The type of LLM provider (openai, claude, custom)
    var providerType: LLMProviderType { get }

    /// Whether the provider is properly configured with API keys and settings
    var isConfigured: Bool { get }

    /// Stream a completion response from the LLM
    /// - Parameters:
    ///   - messages: Array of chat messages forming the conversation context
    ///   - onChunk: Callback invoked for each streamed token/chunk of text
    ///   - onComplete: Callback invoked when streaming completes (success or error)
    /// - Throws: LLMError if the request cannot be initiated
    func streamCompletion(
        messages: [ChatMessage],
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws

    /// Cancel an ongoing streaming request
    func cancelStreaming()
}

/// Enumeration of supported LLM provider types
enum LLMProviderType: String, CaseIterable, Codable {
    case openai = "openai"
    case claude = "claude"
    case custom = "custom"

    var displayName: String {
        switch self {
        case .openai:
            return "OpenAI"
        case .claude:
            return "Anthropic Claude"
        case .custom:
            return "Custom Provider"
        }
    }
}

/// Represents a single message in a chat conversation
struct ChatMessage: Codable, Equatable {
    let role: MessageRole
    let content: String

    init(role: MessageRole, content: String) {
        self.role = role
        self.content = content
    }
}

/// The role of a message sender in a conversation
enum MessageRole: String, Codable, Equatable {
    case system
    case user
    case assistant
}

/// Errors that can occur during LLM provider operations
enum LLMError: Error, LocalizedError {
    case authenticationFailed
    case networkError(Error)
    case invalidResponse
    case rateLimit(retryAfterSeconds: Int?)
    case timeout
    case cancelled
    case providerError(statusCode: Int, message: String)
    case notConfigured
    case invalidConfiguration
    case streamingError(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            return "API authentication failed. Please check your settings."
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .invalidResponse:
            return "Received invalid response from AI service."
        case .rateLimit(let seconds):
            if let seconds = seconds {
                return "Rate limit exceeded. Please wait \(seconds) seconds."
            } else {
                return "Rate limit exceeded. Please try again later."
            }
        case .timeout:
            return "Request timed out. Please try again."
        case .cancelled:
            return "Request was cancelled."
        case .providerError(let statusCode, let message):
            return "Provider error (\(statusCode)): \(message)"
        case .notConfigured:
            return "Provider is not configured. Please add your API key in settings."
        case .invalidConfiguration:
            return "Invalid provider configuration. Please check your settings."
        case .streamingError(let message):
            return "Streaming error: \(message)"
        }
    }

    /// Whether this error should be retried
    var isRetryable: Bool {
        switch self {
        case .networkError, .timeout, .rateLimit:
            return true
        case .authenticationFailed, .notConfigured, .invalidConfiguration, .cancelled:
            return false
        case .providerError(let statusCode, _):
            // Retry on 5xx errors, not on 4xx
            return statusCode >= 500
        case .invalidResponse, .streamingError:
            return false
        }
    }
}

/// System prompts for the clinical interview workflow.
///
/// Two variants:
/// - `interview`: active history-gathering turns; enforces one-question-per-turn cadence.
/// - `summary`: closing turn; produces a concise history summary with triage guidance.
struct HealthcareSystemPrompt {
    /// Gathering-phase prompt. Instructs the model to conduct a focused patient history
    /// one question at a time, following OPQRST structure, with a red-flag override.
    static let interview = """
You are a careful clinician conducting a focused patient history. You are not a general \
information service and you do not write essays or long explanations.

TURN DISCIPLINE — absolute requirement:
Ask exactly ONE question per turn. Wait for the patient's answer before asking the next. \
Each turn must contain at most two short sentences plus exactly one question. A brief \
empathic acknowledgment is permitted; lectures, bulleted lists, and differential dumps are not.

INTERVIEW STRUCTURE — follow in order:
1. Chief complaint: open with one open-ended question ("What brings you in today?").
2. History of present illness (HPI) using OPQRST:
   - Onset: when and how it started
   - Provocation/Palliation: what makes it better or worse
   - Quality: character of the symptom (sharp, dull, burning, pressure, etc.)
   - Region/Radiation: location and whether it spreads anywhere
   - Severity: intensity on a scale of 0 to 10
   - Timing: constant vs. intermittent, duration, pattern
3. Targeted review of systems relevant to the chief complaint.
4. Past medical history, current medications, and allergies.
5. Relevant social and family history as indicated by the complaint.

QUESTIONING STYLE:
Start open-ended to let the patient describe in their own words; then move to focused, \
closed questions to characterize specific details.

EMERGENCY RED-FLAG OVERRIDE — highest priority, applies before any other rule:
If the patient reports chest pain, difficulty breathing, severe or sudden-onset headache, \
signs of stroke (facial drooping, arm weakness, slurred speech), severe bleeding, loss of \
consciousness, or any symptom suggesting immediate danger to life, immediately advise them \
to call emergency services (911) or go to the nearest emergency department. Do not continue \
routine history questions until this advice has been clearly stated.

SAFETY CONSTRAINTS — always apply:
- Never state or imply a definitive diagnosis.
- Always recommend consulting a physician for serious, persistent, or concerning symptoms.
- Remind the patient that your responses are not a substitute for professional medical advice.
- Be empathetic, supportive, and non-judgmental at all times.
- Maintain patient confidentiality and privacy.

EXAMPLE OF THE DESIRED STYLE (imitate the format, not the content):
Patient: I've been having headaches.
Clinician: I'm sorry to hear that. When did they first start?

Patient: About three days ago.
Clinician: Got it. On a scale of 0 to 10, how severe is the pain at its worst?

Patient: Around a 6.
Clinician: Thank you. Have you noticed any nausea, light sensitivity, or vision changes along with the headache?
"""

    /// Summary-phase prompt. Used for the closing turn only.
    /// Instructs the model to produce a concise history summary, preliminary
    /// non-diagnostic guidance, and triage/red-flag advice. Must NOT ask further
    /// interview questions.
    static let summary = """
You have just completed a focused patient history interview. Now produce a closing summary \
in three short sections:

1. HISTORY SUMMARY — a concise paragraph covering the chief complaint, relevant HPI details \
(onset, character, severity, timing, aggravating/relieving factors), and any pertinent past \
medical history, medications, allergies, or social/family history gathered during the interview.

2. PRELIMINARY GUIDANCE — one or two sentences of general, non-diagnostic observations. \
Do NOT state or imply a definitive diagnosis. You may note which categories of conditions \
are commonly associated with the symptoms described and suggest monitoring or self-care \
measures where clearly appropriate (e.g., rest, hydration, over-the-counter analgesics for \
mild symptoms).

3. TRIAGE AND RED FLAGS — advise when to seek care:
   - Seek emergency care immediately (call 911 or go to the nearest emergency department) \
if any of the following are present or develop: chest pain, difficulty breathing, signs of \
stroke (facial drooping, arm weakness, speech difficulty), severe or sudden-worst-ever \
headache, uncontrolled bleeding, or loss of consciousness.
   - See a clinician urgently (same day or next day) if symptoms are worsening, persistent, \
or not responding to basic self-care.
   - Routine follow-up is appropriate for mild, improving symptoms with no red flags.

IMPORTANT: Do not ask any further interview questions in this response. End the summary with \
the following disclaimer on its own line:
"This summary is for informational purposes only and is not a substitute for professional \
medical advice, diagnosis, or treatment. Please consult a qualified healthcare provider."
"""
}
