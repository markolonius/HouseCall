//
//  LLMProviderSettingsViewModel.swift
//  HouseCall
//
//  Created by Claude Code on 2025-11-23.
//  ViewModel for LLM provider configuration settings
//

import Foundation
import Combine

/// ViewModel for managing LLM provider settings
class LLMProviderSettingsViewModel: ObservableObject {
    // MARK: - Published Properties

    /// Currently selected provider
    @Published var selectedProvider: LLMProviderType

    /// OpenAI configuration
    @Published var openAIAPIKey: String = ""
    @Published var openAIModel: String
    @Published var openAITemperature: Double
    @Published var openAIMaxTokens: Int

    /// Claude configuration
    @Published var claudeAPIKey: String = ""
    @Published var claudeModel: String
    @Published var claudeTemperature: Double
    @Published var claudeMaxTokens: Int

    /// Custom provider configuration
    @Published var customAPIKey: String = ""
    @Published var customBaseURL: String = ""
    @Published var customModel: String = ""
    @Published var customTemperature: Double = 0.7
    @Published var customMaxTokens: Int = 1000
    @Published var customRequiresAuth: Bool = false

    /// UI state
    @Published var errorMessage: String?
    @Published var successMessage: String?
    @Published var isSaving: Bool = false

    // MARK: - Dependencies

    private let configManager: LLMProviderConfigManager
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(configManager: LLMProviderConfigManager = .shared) {
        self.configManager = configManager

        // Load current active provider
        self.selectedProvider = configManager.getActiveProvider()

        // Load OpenAI config
        let openAIConfig = configManager.loadOpenAIConfig()
        self.openAIModel = openAIConfig.model
        self.openAITemperature = openAIConfig.temperature
        self.openAIMaxTokens = openAIConfig.maxTokens

        // Load Claude config
        let claudeConfig = configManager.loadClaudeConfig()
        self.claudeModel = claudeConfig.model
        self.claudeTemperature = claudeConfig.temperature
        self.claudeMaxTokens = claudeConfig.maxTokens

        // Load custom provider config
        if let customConfig = configManager.loadCustomProviderConfig() {
            self.customBaseURL = customConfig.baseURL
            self.customModel = customConfig.model
            self.customTemperature = customConfig.temperature ?? 0.7
            self.customMaxTokens = customConfig.maxTokens ?? 1000
            self.customRequiresAuth = customConfig.requiresAuth
        }

        // Load API keys (masked)
        loadAPIKeys()
    }

    // MARK: - Public Methods

    /// Save all settings
    func saveSettings() {
        isSaving = true
        errorMessage = nil
        successMessage = nil

        do {
            // Save active provider
            configManager.setActiveProvider(selectedProvider)

            // Save OpenAI settings
            try saveOpenAISettings()

            // Save Claude settings
            try saveClaudeSettings()

            // Save Custom provider settings
            try saveCustomProviderSettings()

            successMessage = "Settings saved successfully"

            // Clear success message after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.successMessage = nil
            }

        } catch {
            errorMessage = "Failed to save settings: \(error.localizedDescription)"
        }

        isSaving = false
    }

    /// Test connection for the selected provider
    func testConnection() async {
        errorMessage = nil
        successMessage = nil

        // Validate configuration
        guard validateCurrentProvider() else {
            return
        }

        // Note: Actual connection testing would require making a test API call
        // For now, we just validate that the configuration is complete
        successMessage = "Configuration is valid"

        // Clear success message after 3 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.successMessage = nil
        }
    }

    /// Clear API key for a specific provider
    func clearAPIKey(for provider: LLMProviderType) {
        do {
            try configManager.deleteAPIKey(for: provider)

            switch provider {
            case .openai:
                openAIAPIKey = ""
            case .claude:
                claudeAPIKey = ""
            case .custom:
                customAPIKey = ""
            }

            successMessage = "API key cleared"

            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.successMessage = nil
            }
        } catch {
            errorMessage = "Failed to clear API key: \(error.localizedDescription)"
        }
    }

    // MARK: - Private Methods

    private func loadAPIKeys() {
        // Load masked API keys (show only if exists)
        if configManager.hasAPIKey(for: .openai) {
            openAIAPIKey = "••••••••••••••••"
        }

        if configManager.hasAPIKey(for: .claude) {
            claudeAPIKey = "••••••••••••••••"
        }

        if configManager.hasAPIKey(for: .custom) {
            customAPIKey = "••••••••••••••••"
        }
    }

    private func saveOpenAISettings() throws {
        // Save API key if it's not the masked placeholder
        if !openAIAPIKey.isEmpty && !openAIAPIKey.contains("•") {
            try configManager.saveAPIKey(openAIAPIKey, for: .openai)
        }

        // Save config
        let config = OpenAIConfig(
            model: openAIModel,
            temperature: openAITemperature,
            maxTokens: openAIMaxTokens
        )
        configManager.saveOpenAIConfig(config)
    }

    private func saveClaudeSettings() throws {
        // Save API key if it's not the masked placeholder
        if !claudeAPIKey.isEmpty && !claudeAPIKey.contains("•") {
            try configManager.saveAPIKey(claudeAPIKey, for: .claude)
        }

        // Save config
        let config = ClaudeConfig(
            model: claudeModel,
            temperature: claudeTemperature,
            maxTokens: claudeMaxTokens
        )
        configManager.saveClaudeConfig(config)
    }

    private func saveCustomProviderSettings() throws {
        // Save API key if required and not the masked placeholder
        if customRequiresAuth && !customAPIKey.isEmpty && !customAPIKey.contains("•") {
            try configManager.saveAPIKey(customAPIKey, for: .custom)
        }

        // Only save custom provider config if base URL is provided
        guard !customBaseURL.isEmpty else {
            return
        }

        // Save config
        let config = CustomProviderConfig(
            baseURL: customBaseURL,
            endpoint: "v1/chat/completions",
            model: customModel,
            temperature: customTemperature,
            maxTokens: customMaxTokens,
            requiresAuth: customRequiresAuth
        )
        configManager.saveCustomProviderConfig(config)
    }

    private func validateCurrentProvider() -> Bool {
        switch selectedProvider {
        case .openai:
            if openAIAPIKey.isEmpty || openAIAPIKey.contains("•") {
                errorMessage = "Please enter an OpenAI API key"
                return false
            }

        case .claude:
            if claudeAPIKey.isEmpty || claudeAPIKey.contains("•") {
                errorMessage = "Please enter a Claude API key"
                return false
            }

        case .custom:
            if customBaseURL.isEmpty {
                errorMessage = "Please enter a custom provider URL"
                return false
            }
            if customRequiresAuth && (customAPIKey.isEmpty || customAPIKey.contains("•")) {
                errorMessage = "Please enter an API key for your custom provider"
                return false
            }
        }

        return true
    }
}

// MARK: - Model Options

extension LLMProviderSettingsViewModel {
    /// Available OpenAI models
    static let openAIModels = [
        "gpt-4",
        "gpt-4-turbo",
        "gpt-3.5-turbo"
    ]

    /// Available Claude models
    static let claudeModels = [
        "claude-3-5-sonnet-20241022",
        "claude-3-opus-20240229",
        "claude-3-sonnet-20240229",
        "claude-3-haiku-20240307"
    ]
}
