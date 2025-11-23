//
//  ScreenProtectionManager.swift
//  HouseCall
//
//  HIPAA-Compliant Screen Capture Protection
//  Detects screenshots and provides privacy screen for app switcher
//

import Foundation
import UIKit
import SwiftUI

/// Manages screen capture protection for HIPAA compliance
/// Detects screenshot attempts and provides privacy screen overlay
@MainActor
class ScreenProtectionManager: ObservableObject {
    static let shared = ScreenProtectionManager()

    /// Whether to show the privacy screen overlay
    @Published var showPrivacyScreen: Bool = false

    /// Whether a screenshot was recently detected
    @Published var screenshotDetected: Bool = false

    private let auditLogger: AuditLogger
    private var screenshotObserver: NSObjectProtocol?

    // MARK: - Initialization

    init(auditLogger: AuditLogger = .shared) {
        self.auditLogger = auditLogger
        setupScreenshotDetection()
    }

    deinit {
        if let observer = screenshotObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Screenshot Detection

    /// Sets up notification observer for screenshot detection
    private func setupScreenshotDetection() {
        // Listen for screenshot notifications
        screenshotObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.userDidTakeScreenshotNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleScreenshotDetected()
        }
    }

    /// Handles screenshot detection event
    private func handleScreenshotDetected() {
        screenshotDetected = true

        // Log screenshot attempt to audit trail
        if let userId = AuthenticationService.shared.getCurrentUser()?.id {
            do {
                try auditLogger.log(
                    eventType: .dataAccessed,
                    userId: userId,
                    details: AuditEventDetails(
                        message: "Screenshot captured - PHI may have been exported",
                        additionalInfo: [
                            "event": "screenshot_detected",
                            "timestamp": ISO8601DateFormatter().string(from: Date())
                        ]
                    )
                )
            } catch {
                // If audit logging fails, at least we tried
                print("Failed to log screenshot attempt: \(error)")
            }
        } else {
            // Log screenshot without user context (shouldn't happen in authenticated flow)
            do {
                try auditLogger.log(
                    eventType: .dataAccessed,
                    userId: nil,
                    details: AuditEventDetails(
                        message: "Screenshot captured - no authenticated user",
                        additionalInfo: [
                            "event": "screenshot_detected_no_user",
                            "timestamp": ISO8601DateFormatter().string(from: Date())
                        ]
                    )
                )
            } catch {
                print("Failed to log screenshot attempt: \(error)")
            }
        }

        // Show privacy notice alert (optional - can be enabled if desired)
        // For now, we just log and continue
        // showPrivacyNotice()

        // Reset flag after a delay
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            self.screenshotDetected = false
        }
    }

    // MARK: - Privacy Notice (Optional)

    /// Shows a privacy notice when screenshot is detected
    /// This can be used to remind users about PHI confidentiality
    private func showPrivacyNotice() {
        // Note: In a production app, you might want to show an alert
        // For now, we just set a flag that can be observed by the UI
        // The UI can choose to display a banner or alert
    }

    // MARK: - Privacy Screen Control

    /// Manually show privacy screen
    func showPrivacy() {
        showPrivacyScreen = true
    }

    /// Manually hide privacy screen
    func hidePrivacy() {
        showPrivacyScreen = false
    }
}

// MARK: - Privacy Screen View

/// Privacy screen overlay shown in app switcher to hide sensitive content
struct PrivacyScreenView: View {
    var body: some View {
        ZStack {
            // Background color matching app theme
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // App icon/logo
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 80))
                    .foregroundColor(.blue)

                VStack(spacing: 8) {
                    Text("🏥 HouseCall")
                        .font(.title)
                        .fontWeight(.bold)

                    Text("Protected Health Information")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Text("Your data is encrypted and secure")
                        .font(.caption)
                        .foregroundColor(.green)
                        .padding(.top, 4)
                }
            }
        }
    }
}

// MARK: - Preview

#Preview("Privacy Screen") {
    PrivacyScreenView()
}
