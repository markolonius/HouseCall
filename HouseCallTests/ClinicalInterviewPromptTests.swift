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

// MARK: - HealthcareSystemPrompt — summary (closing) variant

@Suite("HealthcareSystemPrompt.summary content invariants")
struct SummaryPromptTests {

    private let prompt = HealthcareSystemPrompt.summary

    // MARK: History summary instruction

    @Test("Summary prompt instructs a history summary section")
    func historySummarySection() {
        let lower = prompt.lowercased()
        #expect(
            lower.contains("history summary") || lower.contains("summary"),
            "Expected history summary instruction in summary prompt"
        )
    }

    // MARK: Preliminary non-diagnostic guidance

    @Test("Summary prompt includes preliminary non-diagnostic guidance")
    func preliminaryNonDiagnosticGuidance() {
        let lower = prompt.lowercased()
        let hasPreliminary = lower.contains("preliminary") || lower.contains("non-diagnostic")
        #expect(
            hasPreliminary,
            "Expected 'preliminary' or 'non-diagnostic' guidance instruction in summary prompt"
        )
    }

    @Test("Summary prompt prohibits stating a definitive diagnosis")
    func noDefinitiveDiagnosis() {
        let lower = prompt.lowercased()
        #expect(
            lower.contains("definitive diagnosis"),
            "Expected 'definitive diagnosis' prohibition in summary prompt"
        )
    }

    // MARK: Triage / red-flag advice

    @Test("Summary prompt includes triage and red-flag advice")
    func triageRedFlagAdvice() {
        let lower = prompt.lowercased()
        let hasTriage = lower.contains("triage") || lower.contains("red flag")
        #expect(hasTriage, "Expected triage/red-flag section in summary prompt")
    }

    // MARK: Disclaimer

    @Test("Summary prompt ends with professional-care disclaimer")
    func professionalCareDisclaimer() {
        let lower = prompt.lowercased()
        #expect(
            lower.contains("not a substitute"),
            "Expected 'not a substitute' disclaimer in summary prompt"
        )
    }

    // MARK: No further interview questions

    @Test("Summary prompt explicitly instructs model NOT to ask further interview questions")
    func noFurtherInterviewQuestions() {
        let lower = prompt.lowercased()
        // The prompt must contain a clear instruction to stop asking questions.
        let hasForbidsQuestions = lower.contains("do not ask") || lower.contains("no further")
        #expect(
            hasForbidsQuestions,
            "Expected instruction not to ask further questions in summary prompt"
        )
    }
}

// MARK: - Per-phase token budgets

@Suite("AIConversationService per-phase token budgets")
struct InterviewTokenBudgetTests {

    @Test("Gathering budget is 160 tokens")
    func gatheringBudgetValue() {
        #expect(AIConversationService.gatheringMaxTokens == 160)
    }

    @Test("Summary budget is 512 tokens")
    func summaryBudgetValue() {
        #expect(AIConversationService.summaryMaxTokens == 512)
    }

    @Test("Gathering budget is smaller than summary budget")
    func gatheringLessThanSummary() {
        #expect(AIConversationService.gatheringMaxTokens < AIConversationService.summaryMaxTokens)
    }
}
