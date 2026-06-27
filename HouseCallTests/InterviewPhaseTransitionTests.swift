//
//  InterviewPhaseTransitionTests.swift
//  HouseCallTests
//
//  Unit tests for AIConversationService phase-state transitions and
//  per-phase prompt/budget routing.
//
//  Spec: openspec/changes/add-clinical-interview-mode/tasks.md — Task 5.2
//
//  Test coverage:
//  1. Default interviewPhase is .gathering.
//  2. requestSummary forwards HealthcareSystemPrompt.summary + summaryMaxTokens to the provider.
//  3. sendMessage (gathering) forwards HealthcareSystemPrompt.interview + gatheringMaxTokens.
//  4. interviewPhase resets to .gathering after a successful summary turn.
//  5. interviewPhase resets to .gathering even when the summary turn fails synchronously.
//

import Testing
import CoreData
import CryptoKit
@testable import HouseCall

@Suite("Interview Phase Transition Tests")
@MainActor
struct InterviewPhaseTransitionTests {

    // MARK: - Isolated Test Infrastructure

    /// Creates a fresh in-memory Core Data context for test isolation.
    func makeContext() -> NSManagedObjectContext {
        let container = NSPersistentContainer(
            name: "HouseCall",
            managedObjectModel: TestCoreDataModel.shared
        )
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in
            if let error = error {
                fatalError("Failed to load in-memory store: \(error)")
            }
        }
        return container.viewContext
    }

    /// Creates a fully isolated `AIConversationService` with a per-test
    /// `EncryptionManager` instance backed by an in-memory keychain.
    ///
    /// A per-test isolated `EncryptionManager` avoids the known parallel-test
    /// encryption race where `SecurityTests.clearCache()` wipes the shared
    /// singleton's master key mid-test, causing decryption of content encrypted
    /// under the original key to fail.
    ///
    /// The supplied `provider` is injected via `_testProviderOverride` so no
    /// real network or API key is needed.
    func makeService(
        context: NSManagedObjectContext,
        userId: UUID,
        provider: LLMProvider
    ) -> AIConversationService {
        let localKeychain = InMemoryKeychainManager()
        let localEncryption = EncryptionManager._testMakeInstance(keychainManager: localKeychain)
        localEncryption._testInjectMasterKey(SymmetricKey(size: .bits256))

        let conversationRepo = CoreDataConversationRepository(
            context: context,
            encryptionManager: localEncryption,
            auditLogger: AuditLogger(context: context)
        )
        let messageRepo = CoreDataMessageRepository(
            context: context,
            encryptionManager: localEncryption,
            auditLogger: AuditLogger(context: context)
        )
        let service = AIConversationService(
            userId: userId,
            conversationRepository: conversationRepo,
            messageRepository: messageRepo,
            providerConfigManager: LLMProviderConfigManager.shared,
            auditLogger: AuditLogger(context: context)
        )
        service._testProviderOverride = provider
        return service
    }

    // MARK: - Test 1: Default Phase

    @Test("Default interviewPhase is .gathering on a freshly constructed service")
    func testDefaultPhaseIsGathering() async throws {
        let context = makeContext()
        let userId = UUID()
        let capturer = CapturingStubProvider()
        let service = makeService(context: context, userId: userId, provider: capturer)

        #expect(service.interviewPhase == .gathering)
    }

    // MARK: - Test 2: Summary Turn — Prompt and Budget

    @Test("requestSummary sends HealthcareSystemPrompt.summary and summaryMaxTokens to the provider")
    func testSummaryTurnUsesSummaryPromptAndBudget() async throws {
        let context = makeContext()
        let userId = UUID()
        let capturer = CapturingStubProvider()
        let service = makeService(context: context, userId: userId, provider: capturer)

        // Create a conversation and run one gathering turn so there is history to summarise.
        let conversation = try await service.createConversation()
        try await service.sendMessage(conversationId: conversation.id!, content: "I have a sore throat")

        // Drain the main-actor Tasks spawned by handleStreamChunk / handleStreamComplete
        // so the gathering turn's assistant message is fully persisted before the
        // summary turn's buildChatContext fetches the message history.
        for _ in 0..<10 { await Task.yield() }

        // Clear captures from the gathering turn before asserting the summary turn.
        capturer.reset()

        // Run the summary turn.
        try await service.requestSummary(conversationId: conversation.id!)

        // streamCompletion is awaited inside requestSummary, so captures are ready now.
        let capturedMsgs  = capturer.capturedMessages
        let capturedTokens = capturer.capturedMaxTokens

        #expect(
            !capturedMsgs.isEmpty,
            "Provider must receive at least a system message for the summary turn"
        )
        #expect(
            capturedMsgs.first?.role == .system,
            "The leading message must be the system role"
        )
        #expect(
            capturedMsgs.first?.content == HealthcareSystemPrompt.summary,
            "System message content must equal HealthcareSystemPrompt.summary for a summary turn"
        )
        let summaryBudget = AIConversationService.summaryMaxTokens
        #expect(
            capturedTokens == summaryBudget,
            "maxTokensOverride must equal summaryMaxTokens (\(summaryBudget)) — got \(String(describing: capturedTokens))"
        )
    }

    // MARK: - Test 3: Gathering Turn — Prompt and Budget

    @Test("sendMessage sends HealthcareSystemPrompt.interview and gatheringMaxTokens to the provider")
    func testGatheringTurnUsesInterviewPromptAndBudget() async throws {
        let context = makeContext()
        let userId = UUID()
        let capturer = CapturingStubProvider()
        let service = makeService(context: context, userId: userId, provider: capturer)

        let conversation = try await service.createConversation()

        // sendMessage (default summaryTurn: false) is the gathering path.
        try await service.sendMessage(conversationId: conversation.id!, content: "I have a headache")

        // streamCompletion is awaited synchronously inside sendMessage, so captures
        // are ready immediately — no yield needed for the prompt/budget assertions.
        let capturedMsgs  = capturer.capturedMessages
        let capturedTokens = capturer.capturedMaxTokens

        #expect(
            !capturedMsgs.isEmpty,
            "Provider must receive at least a system message for the gathering turn"
        )
        #expect(
            capturedMsgs.first?.role == .system,
            "The leading message must be the system role"
        )
        #expect(
            capturedMsgs.first?.content == HealthcareSystemPrompt.interview,
            "System message content must equal HealthcareSystemPrompt.interview for a gathering turn"
        )
        let gatheringBudget = AIConversationService.gatheringMaxTokens
        #expect(
            capturedTokens == gatheringBudget,
            "maxTokensOverride must equal gatheringMaxTokens (\(gatheringBudget)) — got \(String(describing: capturedTokens))"
        )
    }

    // MARK: - Test 4: Phase Resets After Successful Summary Turn

    @Test("interviewPhase resets to .gathering after a successful summary turn")
    func testPhaseResetsAfterSuccessfulSummaryTurn() async throws {
        let context = makeContext()
        let userId = UUID()
        let capturer = CapturingStubProvider()
        let service = makeService(context: context, userId: userId, provider: capturer)

        let conversation = try await service.createConversation()
        try await service.sendMessage(conversationId: conversation.id!, content: "I have fatigue")

        // Drain gathering turn Tasks so the history is ready.
        for _ in 0..<10 { await Task.yield() }

        // Confirm precondition: phase is .gathering before the summary turn.
        #expect(service.interviewPhase == .gathering, "Precondition: phase must start as .gathering")

        try await service.requestSummary(conversationId: conversation.id!)

        // handleStreamComplete (which resets interviewPhase) runs as a spawned
        // Task { @MainActor in … }. Yield to drain it.
        for _ in 0..<10 { await Task.yield() }

        #expect(
            service.interviewPhase == .gathering,
            "interviewPhase must reset to .gathering after a successful summary turn completes"
        )
    }

    // MARK: - Test 5: Phase Resets After Failed Summary Turn

    @Test("interviewPhase resets to .gathering when the summary turn fails")
    func testPhaseResetsAfterFailedSummaryTurn() async throws {
        let context = makeContext()
        let userId = UUID()
        // ThrowingStubProvider throws synchronously from streamCompletion,
        // which triggers the synchronous catch in requestSummary and immediately
        // resets interviewPhase without requiring a Task yield.
        let thrower = ThrowingStubProvider()
        let service = makeService(context: context, userId: userId, provider: thrower)

        // Only a conversation is needed; requestSummary does not require user messages.
        let conversation = try await service.createConversation()

        var caughtError: Error?
        do {
            try await service.requestSummary(conversationId: conversation.id!)
        } catch {
            caughtError = error
        }

        #expect(caughtError != nil, "requestSummary must surface the provider's error")
        #expect(
            service.interviewPhase == .gathering,
            "interviewPhase must reset to .gathering after a failed summary turn"
        )
    }
}

// MARK: - CapturingStubProvider

/// An `LLMProvider` that records the `messages` array and `maxTokensOverride`
/// from each `streamCompletion` invocation, then emits a single-chunk success so
/// the service's completion path runs cleanly.
///
/// Call `reset()` between turns to clear state from prior invocations.
private final class CapturingStubProvider: LLMProvider {
    let providerType: LLMProviderType = .openai
    let isConfigured: Bool = true

    /// Messages received in the most recent `streamCompletion` call.
    private(set) var capturedMessages: [ChatMessage] = []

    /// `maxTokensOverride` received in the most recent `streamCompletion` call.
    private(set) var capturedMaxTokens: Int?

    /// Clears captured state from a prior turn so that the next assertion
    /// reflects only the turn under test.
    func reset() {
        capturedMessages = []
        capturedMaxTokens = nil
    }

    func streamCompletion(
        messages: [ChatMessage],
        maxTokensOverride: Int?,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws {
        capturedMessages = messages
        capturedMaxTokens = maxTokensOverride
        let response = "Capturing stub response."
        onChunk(response)
        onComplete(.success(response))
    }

    func cancelStreaming() {}
}

// MARK: - ThrowingStubProvider

/// An `LLMProvider` whose `streamCompletion` always throws synchronously.
///
/// Used by `testPhaseResetsAfterFailedSummaryTurn` to verify that
/// `requestSummary` resets `interviewPhase` to `.gathering` via its synchronous
/// `catch` block when the stream setup fails before any chunks arrive.
private final class ThrowingStubProvider: LLMProvider {
    let providerType: LLMProviderType = .openai
    let isConfigured: Bool = true

    func streamCompletion(
        messages: [ChatMessage],
        maxTokensOverride: Int?,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<String, LLMError>) -> Void
    ) async throws {
        throw LLMError.networkError(NSError(
            domain: "ThrowingStubProvider",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "Stubbed synchronous failure for phase-reset test"]
        ))
    }

    func cancelStreaming() {}
}
