//
//  LLMProviderType.swift
//  HouseCall
//

import Foundation

/// Legacy conversation metadata. The app no longer talks to LLM vendors directly;
/// this enum only backs the Core Data `Conversation.llmProvider` attribute and is
/// kept to avoid a Core Data migration.
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
