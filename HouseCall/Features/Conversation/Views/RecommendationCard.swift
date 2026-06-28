//
//  RecommendationCard.swift
//  HouseCall
//
//  Phase 6.3 — Renders a physician-approved recommendation inside the chat.
//  Phase 5.3 (soap-review) — Added soap_note card type.
//
//  Design contract (from design.md §7):
//  - Switch on `payloadType` so typed card views can be added in later slices
//    without redesigning this dispatch layer.
//  - MVP: every incoming card has `payloadType = "guidance"` and renders as a
//    single text card with a visual distinction from ordinary AI messages.
//  - soap_note: physician-approved SOAP care plan, rendered as-is (the
//    authoritative approved text may already contain SOAP section labels;
//    we do not attempt to parse or re-format it).
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
            case "soap_note":
                SOAPNoteCardView(content: model.finalContent)
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

// MARK: - SOAPNoteCardView

/// Renders a `soap_note` recommendation — a physician-approved care plan
/// delivered after SOAP review.
///
/// The `content` parameter is the physician-approved final text.  If the text
/// already contains SOAP section labels (SUBJECTIVE / OBJECTIVE / ASSESSMENT /
/// PLAN), they are displayed as-is; we do NOT attempt to parse or re-format the
/// authoritative physician-edited note.
///
/// HIPAA: `content` (PHI) is shown via the default SwiftUI Text renderer only;
/// it is never logged or re-persisted here.
private struct SOAPNoteCardView: View {
    let content: String

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                // Header badge
                HStack(spacing: 6) {
                    Image(systemName: "stethoscope")
                        .foregroundColor(.indigo)
                        .font(.caption)
                    Text("Care plan — reviewed by your physician")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.indigo)
                }

                Divider()
                    .background(Color.indigo.opacity(0.3))

                // Physician-approved note content (PHI — no logging).
                // Rendered as plain text exactly as approved; the physician's
                // edits are authoritative and must not be altered by the client.
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
                    .fill(Color(.systemIndigo).opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(Color.indigo.opacity(0.3), lineWidth: 1)
                    )
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Physician-reviewed care plan")
        .accessibilityValue(content)
        .accessibilityHint("Your approved care plan from the reviewing physician.")
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

#Preview("SOAP note card") {
    // Synthetic, non-identifying content used only for visual preview.
    let soapText = """
    SUBJECTIVE: Patient reports a 3-day history of headache (7/10, bifrontal) \
    with associated low-grade fever (38.1 °C self-measured) and mild fatigue. \
    No nausea, photophobia, or neck stiffness reported.

    OBJECTIVE: No in-person examination performed. Patient-reported vitals: \
    temperature 38.1 °C. No additional objective findings available.

    ASSESSMENT: Presentation is consistent with a viral upper respiratory \
    illness. No red flags for meningitis or secondary bacterial infection at \
    this time.

    PLAN: Rest and increased fluid intake. Acetaminophen 500 mg every 6 hours \
    as needed for fever or pain. Return to care if temperature exceeds 39.5 °C, \
    symptoms worsen, or no improvement within 5 days.
    """
    let model = RecommendationCardModel(
        id: "rec-preview-003",
        conversationLocalId: UUID(),
        payloadType: "soap_note",
        finalContent: soapText,
        messageLocalId: UUID()
    )
    return RecommendationCard(model: model)
        .padding()
}
