//
//  LLMProviderSettingsView.swift
//  HouseCall
//
//  Created by Claude Code on 2025-11-23.
//  SwiftUI view for configuring LLM provider settings
//

import SwiftUI

/// Settings view for managing LLM provider configuration
struct LLMProviderSettingsView: View {
    @StateObject private var viewModel: LLMProviderSettingsViewModel

    @Environment(\.dismiss) private var dismiss

    init(viewModel: LLMProviderSettingsViewModel = LLMProviderSettingsViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationView {
            Form {
                // Provider Selection Section
                Section(header: Text("AI Provider")) {
                    Picker("Provider", selection: $viewModel.selectedProvider) {
                        ForEach(LLMProviderType.allCases, id: \.self) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("Select which AI provider to use for conversations")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Provider-specific configuration
                switch viewModel.selectedProvider {
                case .openai:
                    openAIConfigSection
                case .claude:
                    claudeConfigSection
                case .custom:
                    customProviderConfigSection
                }

                // Status messages
                if let errorMessage = viewModel.errorMessage {
                    Section {
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                            Text(errorMessage)
                                .foregroundColor(.red)
                                .font(.caption)
                        }
                    }
                }

                if let successMessage = viewModel.successMessage {
                    Section {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text(successMessage)
                                .foregroundColor(.green)
                                .font(.caption)
                        }
                    }
                }

                // Action buttons
                Section {
                    Button(action: {
                        viewModel.saveSettings()
                    }) {
                        HStack {
                            Spacer()
                            if viewModel.isSaving {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                            } else {
                                Text("Save Settings")
                                    .fontWeight(.semibold)
                            }
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isSaving)

                    Button(action: {
                        Task {
                            await viewModel.testConnection()
                        }
                    }) {
                        HStack {
                            Spacer()
                            Text("Test Configuration")
                            Spacer()
                        }
                    }
                    .disabled(viewModel.isSaving)
                }
            }
            .navigationTitle("AI Provider Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - OpenAI Configuration Section

    private var openAIConfigSection: some View {
        Group {
            Section(header: Text("OpenAI Configuration")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        if viewModel.openAIAPIKey.contains("•") {
                            Text(viewModel.openAIAPIKey)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            SecureField("sk-...", text: $viewModel.openAIAPIKey)
                                .textContentType(.password)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }

                        if !viewModel.openAIAPIKey.isEmpty {
                            Button(action: {
                                viewModel.clearAPIKey(for: .openai)
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Picker("Model", selection: $viewModel.openAIModel) {
                    ForEach(LLMProviderSettingsViewModel.openAIModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.1f", viewModel.openAITemperature))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $viewModel.openAITemperature, in: 0.0...2.0, step: 0.1)
                    Text("Controls randomness: 0 = focused, 2 = creative")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Max Tokens")
                        Spacer()
                        Text("\(viewModel.openAIMaxTokens)")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(viewModel.openAIMaxTokens) },
                        set: { viewModel.openAIMaxTokens = Int($0) }
                    ), in: 100...4000, step: 100)
                    Text("Maximum length of AI responses")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(footer: Text("Get your API key from platform.openai.com")) {
                Link("OpenAI Platform →", destination: URL(string: "https://platform.openai.com/api-keys")!)
                    .font(.caption)
            }
        }
    }

    // MARK: - Claude Configuration Section

    private var claudeConfigSection: some View {
        Group {
            Section(header: Text("Anthropic Claude Configuration")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("API Key")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    HStack {
                        if viewModel.claudeAPIKey.contains("•") {
                            Text(viewModel.claudeAPIKey)
                                .font(.body)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            SecureField("sk-ant-...", text: $viewModel.claudeAPIKey)
                                .textContentType(.password)
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                        }

                        if !viewModel.claudeAPIKey.isEmpty {
                            Button(action: {
                                viewModel.clearAPIKey(for: .claude)
                            }) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }

                Picker("Model", selection: $viewModel.claudeModel) {
                    ForEach(LLMProviderSettingsViewModel.claudeModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.1f", viewModel.claudeTemperature))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $viewModel.claudeTemperature, in: 0.0...2.0, step: 0.1)
                    Text("Controls randomness: 0 = focused, 2 = creative")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Max Tokens")
                        Spacer()
                        Text("\(viewModel.claudeMaxTokens)")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(viewModel.claudeMaxTokens) },
                        set: { viewModel.claudeMaxTokens = Int($0) }
                    ), in: 100...4000, step: 100)
                    Text("Maximum length of AI responses")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section(footer: Text("Get your API key from console.anthropic.com")) {
                Link("Anthropic Console →", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
            }
        }
    }

    // MARK: - Custom Provider Configuration Section

    private var customProviderConfigSection: some View {
        Group {
            Section(header: Text("Custom Provider Configuration")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Base URL")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("http://localhost:11434", text: $viewModel.customBaseURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .keyboardType(.URL)

                    Text("OpenAI-compatible endpoint (e.g., Ollama, llama.cpp)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Model Name")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("llama3", text: $viewModel.customModel)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                }

                Toggle("Requires Authentication", isOn: $viewModel.customRequiresAuth)

                if viewModel.customRequiresAuth {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("API Key")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack {
                            if viewModel.customAPIKey.contains("•") {
                                Text(viewModel.customAPIKey)
                                    .font(.body)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                SecureField("API Key", text: $viewModel.customAPIKey)
                                    .textContentType(.password)
                                    .autocapitalization(.none)
                                    .disableAutocorrection(true)
                            }

                            if !viewModel.customAPIKey.isEmpty {
                                Button(action: {
                                    viewModel.clearAPIKey(for: .custom)
                                }) {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Temperature")
                        Spacer()
                        Text(String(format: "%.1f", viewModel.customTemperature))
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $viewModel.customTemperature, in: 0.0...2.0, step: 0.1)
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Max Tokens")
                        Spacer()
                        Text("\(viewModel.customMaxTokens)")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(viewModel.customMaxTokens) },
                        set: { viewModel.customMaxTokens = Int($0) }
                    ), in: 100...4000, step: 100)
                }
            }

            Section(footer: Text("Configure a custom LLM provider such as Ollama running on localhost")) {
                EmptyView()
            }
        }
    }
}

// MARK: - SwiftUI Preview

#Preview {
    LLMProviderSettingsView()
}
