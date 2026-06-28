//
//  ClinicalInterviewPromptTests.swift
//  HouseCallTests
//
//  Unit tests for HealthcareSystemPrompt content invariants and
//  per-phase token budget values.
//
//  Spec: openspec/changes/add-clinical-interview-mode/tasks.md — Task 5.1
//

import Testing
import Foundation
@testable import HouseCall

// MARK: - HealthcareSystemPrompt — interview (gathering) variant

@Suite("HealthcareSystemPrompt.interview content invariants")
struct InterviewPromptTests {

    private let prompt = HealthcareSystemPrompt.interview

    // MARK: One-question-per-turn

    @Test("Interview prompt enforces one question per turn")
    func oneQuestionPerTurn() {
        // The prompt must instruct the model to ask only one question at a time.
        let lower = prompt.lowercased()
        let containsOneQuestion = lower.contains("one question") || lower.contains("exactly one question")
        #expect(containsOneQuestion, "Expected 'one question' guidance in interview prompt")
    }

    // MARK: OPQRST framework

    @Test("Interview prompt references the OPQRST framework")
    func opqrstFramework() {
        #expect(prompt.contains("OPQRST"), "Expected OPQRST acronym/framework in interview prompt")
    }

    // MARK: Red-flag / emergency override

    @Test("Interview prompt contains red-flag emergency language")
    func redFlagLanguage() {
        let lower = prompt.lowercased()
        // Must mention emergency services or 911 as the red-flag override action.
        let hasEmergency = lower.contains("emergency") || lower.contains("911")
        #expect(hasEmergency, "Expected emergency/red-flag language in interview prompt")
    }

    // MARK: Safety constraints

    @Test("Interview prompt prohibits stating a definitive diagnosis")
    func noDefinitiveDiagnosis() {
        let lower = prompt.lowercased()
        #expect(
            lower.contains("definitive diagnosis"),
            "Expected 'definitive diagnosis' prohibition in interview prompt safety constraints"
        )
    }

    @Test("Interview prompt includes professional-care disclaimer ('not a substitute')")
    func professionalCareDisclaimer() {
        let lower = prompt.lowercased()
        #expect(
            lower.contains("not a substitute"),
            "Expected 'not a substitute' professional-care disclaimer in interview prompt"
        )
    }

    // MARK: Few-shot exemplar

    @Test("Interview prompt includes a few-shot exemplar section")
    func fewShotExemplar() {
        let lower = prompt.lowercased()
        // The exemplar is labelled "EXAMPLE" and contains Patient/Clinician exchange.
        let hasExampleLabel = lower.contains("example")
        let hasExchangeFormat = prompt.contains("Patient:") && prompt.contains("Clinician:")
        #expect(hasExampleLabel, "Expected 'EXAMPLE' label in interview prompt few-shot section")
        #expect(hasExchangeFormat, "Expected Patient:/Clinician: exchange in interview prompt few-shot exemplar")
    }
}

// MARK: - Per-turn token budget

@Suite("AIConversationService per-turn token budget")
struct InterviewTokenBudgetTests {

    @Test("Gathering budget is 160 tokens")
    func gatheringBudgetValue() {
        #expect(AIConversationService.gatheringMaxTokens == 160)
    }
}
