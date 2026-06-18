//
//  ChatInterfaceUITests.swift
//  HouseCallUITests
//
//  UI tests for the patient chat interface (update-patient-chat-ux UX refresh).
//
//  Architecture notes (as of this change):
//  - After login the app navigates DIRECTLY to ChatView; there is no
//    conversation list, no "New Chat" step, and no bottom tab bar.
//  - The profile sheet is reached via the "profileButton" toolbar button in
//    the top-right corner of ChatView.
//  - Provider selection and "AI Provider Settings" are not reachable from this
//    flow (no ProviderMenuButton, no ProviderSettingsButton).
//  - No live LLM API key is available in CI; tests that require an AI response
//    are excluded. Tests verify UI structure and input-state only.
//
//  UI-TESTING auth path:
//  When launched with the "UI-TESTING" argument HouseCallApp runs
//  UITestBootstrap.prepareIfNeeded() BEFORE AuthenticationService is
//  initialised, which:
//    (a) clears any leftover Keychain session so the app always starts on the
//        login screen, and
//    (b) seeds a synthetic account uitest@housecall.app / UITest12345!.
//  loginTestUser() fills in the form with those credentials and waits for
//  ChatView to appear.
//

import XCTest

final class ChatInterfaceUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["UI-TESTING"]
        app.launch()
    }

    override func tearDownWithError() throws {
        app = nil
    }

    // MARK: - Helper Methods

    /// Logs in via the login screen using the pre-seeded synthetic test account
    /// (uitest@housecall.app / UITest12345!).  Asserts each step so failures
    /// surface a meaningful message rather than a silent no-op.
    ///
    /// Returns only after both the chat input AND the profile toolbar button
    /// are visible, which confirms that AutoLaunchChatView has fully settled
    /// and the navigation toolbar is interactive.
    ///
    /// Pre-condition: app launched with "UI-TESTING" (handled in setUp).
    func loginTestUser() {
        let emailField = app.textFields["loginEmailField"]
        XCTAssertTrue(
            emailField.waitForExistence(timeout: 5),
            "loginEmailField not found — has HouseCallApp seeded the test account?")
        emailField.tap()
        emailField.typeText("uitest@housecall.app")

        let passwordField = app.secureTextFields["loginPasswordField"]
        XCTAssertTrue(passwordField.exists, "loginPasswordField not found")
        passwordField.tap()
        passwordField.typeText("UITest12345!")

        let submitButton = app.buttons["loginSubmitButton"]
        XCTAssertTrue(submitButton.exists, "loginSubmitButton not found")
        submitButton.tap()

        // After a successful login the app resolves (or creates) the user's
        // conversation and shows ChatView. Wait for the chat input.
        let chatInput = chatInputElement
        XCTAssertTrue(
            chatInput.waitForExistence(timeout: 10),
            "chatMessageInput not found after login — did authentication succeed?")

        // Also wait for the profile toolbar button, which confirms the nav
        // bar is fully settled and its buttons are interactive.  Without this
        // wait, tests that immediately tap profileButton can race with the
        // NavigationStack animation and miss the tap registration.
        let profileButton = app.buttons["profileButton"]
        XCTAssertTrue(
            profileButton.waitForExistence(timeout: 5),
            "profileButton must appear after login")

        // On iOS 26 Liquid Glass nav bar, a toolbar button can appear in the
        // accessibility tree before its layout frame is committed — tapping it
        // while the computed hit point is {-1,-1} silently misses.
        // Poll until `isHittable` is true so callers can tap immediately.
        let hittablePredicate = NSPredicate(format: "hittable == true")
        let hittableExpectation = XCTNSPredicateExpectation(
            predicate: hittablePredicate, object: profileButton)
        XCTWaiter().wait(for: [hittableExpectation], timeout: 3)
    }

    /// Returns the chat-input element regardless of the underlying UIKit type.
    /// SwiftUI's TextField(axis:.vertical) renders as UITextView on iOS 16+;
    /// we probe textViews first, then fall back to textFields.
    private var chatInputElement: XCUIElement {
        let tv = app.textViews["chatMessageInput"]
        if tv.exists { return tv }
        return app.textFields["chatMessageInput"]
    }

    // MARK: - Login Screen Tests

    /// The new accessibility identifiers must be present and the tab bar that
    /// was removed in this UX pass must not exist.
    func testLoginScreenIdentifiers() throws {
        XCTAssertTrue(
            app.textFields["loginEmailField"].waitForExistence(timeout: 5),
            "loginEmailField must exist on the login screen")
        XCTAssertTrue(
            app.secureTextFields["loginPasswordField"].exists,
            "loginPasswordField must exist on the login screen")
        XCTAssertTrue(
            app.buttons["loginSubmitButton"].exists,
            "loginSubmitButton must exist on the login screen")

        // Tab bar was removed in this UX refresh.
        XCTAssertFalse(
            app.tabBars.firstMatch.exists,
            "Tab bar must not appear in the new single-chat UX")
    }

    // MARK: - Chat Entry Tests

    /// After login, ChatView is shown directly.  No conversation list, no
    /// "New Chat" button, and no bottom tab bar.
    func testChatIsDirectEntryAfterLogin() throws {
        loginTestUser()

        XCTAssertTrue(
            chatInputElement.exists,
            "Chat input must be visible immediately after login")

        // Retired UI elements must be absent.
        XCTAssertFalse(
            app.tables["ConversationList"].exists,
            "ConversationList must not appear in the single-chat UX")
        XCTAssertFalse(
            app.buttons["NewChatButton"].exists,
            "NewChatButton must not appear in the single-chat UX")
        XCTAssertFalse(
            app.tabBars.firstMatch.exists,
            "Tab bar must not appear in the single-chat UX")
    }

    // MARK: - Profile Button Tests

    func testProfileButtonExistsInToolbar() throws {
        loginTestUser()

        XCTAssertTrue(
            app.buttons["profileButton"].exists,
            "profileButton must be present in the navigation bar")
    }

    func testProfileButtonOpensSheetWithLogout() throws {
        loginTestUser()

        // Tap the profile button.  loginTestUser() waits until isHittable is
        // true, but a second tap is retained as a safety-net against residual
        // NavigationStack animation overlap on iOS 26.x.
        app.buttons["profileButton"].tap()
        if !app.buttons["Done"].waitForExistence(timeout: 3) {
            app.buttons["profileButton"].tap()
        }

        // The profile sheet's toolbar always contains a "Done" button;
        // its presence is the most reliable signal that the sheet opened.
        // (Navigation-bar titles can be flaky on iOS 26.x due to animation
        // timing; SwiftUI List staticTexts inside Buttons are not exposed as
        // separate accessibility elements.)
        XCTAssertTrue(
            app.buttons["Done"].waitForExistence(timeout: 5),
            "Profile sheet must open (Done button expected in sheet toolbar)")

        // The logout button's label must be reachable as a button-level query.
        // In SwiftUI List on UICollectionView, a Button's accessibility label
        // is derived from its Text content.  Query by label predicate.
        let logoutButton = app.buttons
            .matching(NSPredicate(format: "label == 'Logout'"))
            .firstMatch
        XCTAssertTrue(
            logoutButton.exists,
            "A button labelled 'Logout' must be visible in the profile sheet")
    }

    func testProfileSheetDismissReturnsToChat() throws {
        loginTestUser()

        // Tap the profile button. Retry once if the sheet doesn't open within
        // 3 s — NavigationStack presentation animations can absorb the first
        // tap on a cold launch.
        app.buttons["profileButton"].tap()
        if !app.buttons["Done"].waitForExistence(timeout: 3) {
            app.buttons["profileButton"].tap()
        }

        XCTAssertTrue(
            app.buttons["Done"].waitForExistence(timeout: 5),
            "Profile sheet must open (Done button expected)")

        app.buttons["Done"].tap()

        XCTAssertTrue(
            chatInputElement.waitForExistence(timeout: 3),
            "Chat input must be reachable after dismissing the profile sheet")
    }

    // MARK: - No Provider Picker Tests

    /// Provider picker and AI Provider Settings are not reachable in the new
    /// flow; their identifiers must be absent from the reachable surface.
    func testNoProviderPickerReachable() throws {
        loginTestUser()

        XCTAssertFalse(
            app.buttons["ProviderMenuButton"].exists,
            "ProviderMenuButton must not exist in the new UX")
        XCTAssertFalse(
            app.otherElements["LLMProviderSettingsView"].exists,
            "LLMProviderSettingsView must not be reachable from chat")
        XCTAssertFalse(
            app.buttons["ProviderSettingsButton"].exists,
            "ProviderSettingsButton must not exist in the new UX")
    }

    // MARK: - Input and Send Button Tests

    func testSendButtonDisabledWhenInputEmpty() throws {
        loginTestUser()

        let sendButton = app.buttons["chatSendButton"]
        XCTAssertTrue(sendButton.exists, "chatSendButton must exist")
        XCTAssertFalse(
            sendButton.isEnabled,
            "chatSendButton must be disabled when message input is empty")
    }

    func testSendButtonEnablesAfterTyping() throws {
        loginTestUser()

        let chatInput = chatInputElement
        let sendButton = app.buttons["chatSendButton"]

        // Tap to establish first-responder.  Retry once — on iOS 26.x the
        // NavigationStack layout pass can absorb the first tap before focus
        // commits.  If the field still cannot accept input after two attempts
        // (e.g. the simulator is running with "Connect Hardware Keyboard"
        // active and the system-level focus transfer is unavailable), skip
        // the remainder with XCTSkip rather than failing — this is a known
        // XCUITest / simulator limitation, not a product defect.
        chatInput.tap()
        if !chatInput.hasFocus {
            chatInput.tap()
        }
        guard chatInput.hasFocus else {
            throw XCTSkip("chatMessageInput could not acquire keyboard focus; " +
                          "disable 'Connect Hardware Keyboard' in the simulator " +
                          "or run on device to exercise this code path")
        }
        chatInput.typeText("Hello")

        // SwiftUI propagates the @State change asynchronously; poll until the
        // send button becomes enabled rather than asserting at a fixed instant.
        let enabledPredicate = NSPredicate(format: "enabled == true")
        let enabledExpectation = XCTNSPredicateExpectation(
            predicate: enabledPredicate,
            object: sendButton)
        let result = XCTWaiter().wait(for: [enabledExpectation], timeout: 3)
        XCTAssertEqual(result, .completed,
                       "chatSendButton must enable after typing into the message field")
    }

    // MARK: - Accessibility Tests

    func testChatInputsHaveAccessibilityIdentifiers() throws {
        loginTestUser()

        // Both elements must be findable by the identifiers set in the views.
        // (Icon-only SwiftUI buttons do not guarantee a non-empty system label,
        // so we verify presence and enabled state rather than label text.)
        let chatInput = chatInputElement
        XCTAssertTrue(chatInput.exists, "chatMessageInput must exist")
        XCTAssertTrue(chatInput.isEnabled,
                      "chatMessageInput must be enabled when the assistant is not streaming")

        let sendButton = app.buttons["chatSendButton"]
        XCTAssertTrue(sendButton.exists, "chatSendButton must exist")
    }

    // MARK: - Landscape Tests

    func testLandscapeLayout() throws {
        loginTestUser()

        XCUIDevice.shared.orientation = .landscapeLeft

        XCTAssertTrue(chatInputElement.exists,
                      "Chat input must be visible in landscape orientation")
        XCTAssertTrue(app.buttons["chatSendButton"].exists,
                      "chatSendButton must be visible in landscape orientation")

        XCUIDevice.shared.orientation = .portrait
    }
}
