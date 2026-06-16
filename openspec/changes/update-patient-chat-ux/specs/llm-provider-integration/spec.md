# Specification: LLM Provider Integration

## ADDED Requirements

### Requirement: Use a hardcoded default provider with no user configuration

The app SHALL use a single default LLM provider and API key sourced from build
configuration. No provider selection, API-key entry, or model/temperature
configuration SHALL be exposed in the patient-facing UI.

#### Scenario: Every conversation uses the default provider

- **GIVEN** a patient starts or resumes any conversation
- **WHEN** a message is sent
- **THEN** the request uses the hardcoded default provider and key
- **AND** the patient is never prompted to choose or configure a provider

#### Scenario: No provider configuration surface exists

- **WHEN** the patient navigates the app, including the profile surface
- **THEN** there is no screen, link, or control for AI/LLM provider settings
- **AND** the API key is not displayed anywhere in the UI
