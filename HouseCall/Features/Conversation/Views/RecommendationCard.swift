//
//  RecommendationCard.swift
//  HouseCall
//
//  Phase 6.3 — Renders a physician-approved recommendation inside the chat.
//
//  Design contract (from design.md §7):
//  - Switch on `payloadType` so typed card views can be added in later slices
//    without redesigning this dispatch layer.
//  - MVP: every incoming card has `payloadType = "guidance"` and renders as a
//    single text card with a visual distinction from ordinary AI messages.
//  - PHI rendered here (finalContent) is shown only in the patient's own
//    authenticated chat view — no logging, no clipboard coercion.
//
//  HIPAA guardrails:
//  - `finalContent` is shown in a SwiftUI Text (default renderer, no unsafe
//    HTML injection path).
//  - The view never logs or persists the content it displays.
//

import SwiftUI

// MARK: - RecommendationCard

/// Dispatches to a typed card view based on `payloadType`.
///
/// Usage in `ChatView`:
/// ```swift
/// RecommendationCard(model: cardModel)
/// ```
struct RecommendationCard: View {
    let model: RecommendationCardModel

    var body: some View {
        Group {
            switch model.payloadType {
            case "guidance":
                GuidanceCardView(content: model.finalContent)
            default:
                // Unknown payload type: render a generic card so we never
                // crash and the patient always sees something meaningful.
                GenericRecommendationCardView(
                    payloadType: model.payloadType,
                    content: model.finalContent
                )
            }
        }
        .accessibilityLabel("Physician recommendation")
        .accessibilityHint("A recommendation from your care team has been delivered.")
    }
}

// MARK: - GuidanceCardView

/// Renders a `guidance` recommendation as a styled card in the chat.
private struct GuidanceCardView: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                // Header badge
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                    Text("Physician Guidance")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.green)
                }

                Divider()
                    .background(Color.green.opacity(0.3))

                // Recommendation content (PHI — no logging)
                Text(content)
                    .font(.body)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemGreen).opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.green.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - GenericRecommendationCardView

/// Fallback for unknown payload types (future-proofing).
private struct GenericRecommendationCardView: View {
    let payloadType: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .foregroundColor(.blue)
                    .font(.caption)
                Text("Recommendation")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.blue)
            }

            Divider()

            Text(content)
                .font(.body)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBlue).opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .strokeBorder(Color.blue.opacity(0.25), lineWidth: 1)
                )
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview("Guidance card") {
    let model = RecommendationCardModel(
        id: "rec-preview-001",
        conversationLocalId: UUID(),
        payloadType: "guidance",
        finalContent: "Based on your reported symptoms (headache and fever for 3 days), I recommend staying hydrated, resting, and taking acetaminophen as directed. If your fever exceeds 39.5°C or symptoms worsen, please seek in-person care.",
        messageLocalId: UUID()
    )
    return RecommendationCard(model: model)
        .padding()
}

#Preview("Unknown type fallback") {
    let model = RecommendationCardModel(
        id: "rec-preview-002",
        conversationLocalId: UUID(),
        payloadType: "prescription",
        finalContent: "Amoxicillin 500mg — take one capsule three times daily for 7 days.",
        messageLocalId: UUID()
    )
    return RecommendationCard(model: model)
        .padding()
}
