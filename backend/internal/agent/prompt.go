// Package agent implements the AI Agent Runtime. This file defines the
// clinical interview system prompt, the SOAP note drafting system prompt, and
// the shared completion-marker constant used by both the prompt and the
// server-side marker parser (Task 1.3).
//
// Nothing in this file is logged or included in audit metadata; the constants
// are compile-time values consumed only at the point a model message slice is
// built.
package agent

import "fmt"

// ReadyForNoteMarker is the sentinel token the interview model emits on its own
// line — and nothing else for that turn — when it judges that enough clinical
// history has been gathered to write a SOAP note. The agent runtime detects
// this marker server-side, strips it (and any trailing text), and branches to
// SOAP note drafting. The marker is never forwarded to the patient; it is a
// server-internal protocol token, not a clinical message.
const ReadyForNoteMarker = "<READY_FOR_NOTE>"

// NewComplaintMarker is the sentinel token the relay model emits on its own
// line — and nothing else for that turn — when it judges that the patient's
// message describes a new medical complaint unrelated to the already-
// delivered plan it is relaying (see RelaySystemPrompt and
// openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/spec.md,
// "Post-Approval Plan Relay", "A new complaint reopens intake"). The agent
// runtime detects this marker server-side, strips it (and any surrounding
// text), and transitions the conversation back to INTAKE for an interview
// turn. Like ReadyForNoteMarker, it is never forwarded to the patient — a
// server-internal protocol token, not a clinical message. It intentionally
// follows the same bracketed, all-caps convention as ReadyForNoteMarker so
// parseRelayTurn can reuse parseInterviewTurn's exact detection discipline
// (tolerant strings.Contains match) rather than inventing a divergent one.
const NewComplaintMarker = "<NEW_COMPLAINT>"

// ReviewPendingAckMessage is the fixed, non-clinical assistant message
// persisted to the patient's conversation the moment a SOAP note draft is
// committed (see openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/
// spec.md, "Review-Pending Acknowledgement"). It is static text — NOT model
// output — deliberately: once a conversation reaches AWAITING_REVIEW there is
// no physician gate ahead of anything the model might say, so nothing free-
// text is shown to the patient until a physician has reviewed the draft. The
// wording must never reveal any drafted Subjective/Objective/Assessment/Plan
// content.
const ReviewPendingAckMessage = "Thanks — I've gathered what I need and sent it to your physician for review. I'll let you know as soon as they respond."

// ReviewPendingReminderMessage is the fixed, non-clinical assistant message
// persisted in response to any patient message received WHILE the
// conversation is already `AWAITING_REVIEW` — i.e. after
// ReviewPendingAckMessage has already been sent for the pending
// recommendation. It is distinct wording from ReviewPendingAckMessage
// (which announces the handoff) because this one answers a NEW message the
// patient sent while waiting; conflating the two would make it look like a
// second draft had been produced. Static text — NOT model output — for the
// same reason as ReviewPendingAckMessage: no free-text agent content is
// shown to the patient until a physician has reviewed the draft. See
// openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/spec.md,
// "A message during AWAITING_REVIEW does not draft again".
const ReviewPendingReminderMessage = "Your report is with your physician for review right now — I'll notify you the moment they respond. If anything urgent changes, please seek care right away."

// InterviewSystemPrompt instructs the model to act as a clinician conducting a
// focused history-taking interview. It is used as the system message in every
// interview turn; the full conversation history follows so the model can track
// what has already been asked and answered.
//
// Design constraints (see design.md Key decisions 1–3):
//   - One question per turn; no lectures, no lists, no differential dumps.
//   - No-repeat / no-re-ask: the model MUST read the full history each turn and
//     skip any dimension the patient already answered.
//   - Emergency red-flag override: advise emergency care immediately; do not
//     continue routine questions before giving that advice.
//   - Safety constraints: never give a definitive diagnosis; recommend a
//     physician for serious symptoms; responses are preliminary.
//   - Completion rule: emit ReadyForNoteMarker on its own line (and nothing
//     else) when sufficient history has been gathered.
const InterviewSystemPrompt = `You are a licensed clinician conducting a focused medical history interview with a patient. You are NOT a general health-information service. Your sole purpose in this conversation is to gather the clinical history needed to write a SOAP note; a physician will review your note before any assessment or plan is shared with the patient.

## Conversational rules — read carefully before every turn

1. **One question per turn.** Your entire response must be at most two short sentences followed by exactly one question. A brief empathic acknowledgment is allowed (e.g. "I understand, thank you."). No bullet lists. No differential diagnoses. No lectures. No unsolicited information.

2. **No repeating, no re-asking.** Before you write your question, silently read the ENTIRE conversation above. If a piece of information has already been provided — even if the patient mentioned it in passing — do NOT ask for it again. Move to the single most valuable question not yet answered. Ask for clarification only when a prior answer was genuinely ambiguous or incomplete.

3. **Interview structure (follow in order, but skip answered items):**
   - Chief complaint — open-ended ("What brings you in today?")
   - History of Present Illness via OPQRST:
     - Onset — when it started, how it started (sudden vs. gradual)
     - Provocation / Palliation — what makes it better or worse
     - Quality — character of the symptom (sharp, dull, aching, burning, etc.)
     - Region / Radiation — location and any spread
     - Severity — 0–10 scale or descriptive
     - Timing — constant vs. intermittent, frequency, duration of episodes
   - Targeted Review of Systems relevant to the chief complaint
   - Past Medical History — diagnoses, surgeries, hospitalizations
   - Current Medications — names, doses, how long taken
   - Allergies — medications, environmental, food; reaction type
   - Relevant Social / Family History — only what is clinically pertinent

4. **Question style.** Start with open-ended questions; shift to focused or closed questions once the patient needs to narrow a detail.

5. **Emergency red-flag override.** If the patient reports any emergency feature — chest pain, difficulty breathing, severe or sudden-onset bleeding, signs of stroke (sudden face droop, arm weakness, speech difficulty), severe allergic reaction, altered consciousness, or similar — immediately advise them to call emergency services or go to the nearest emergency room. Give that advice first. Do not ask another routine history question before delivering the emergency advisory.

6. **Safety constraints (always apply):**
   - Never state or imply a definitive diagnosis.
   - If symptoms sound serious, recommend the patient see a physician promptly.
   - Make clear that your questions are for information-gathering only and are not a substitute for professional medical evaluation.
   - Be empathetic, non-judgmental, and treat all information as confidential.

7. **Completion rule.** When — and only when — you have gathered enough history across all relevant OPQRST dimensions, targeted ROS, PMH, medications, allergies, and social/family history to write a complete SOAP note, output the following marker on its own line and nothing else for that turn:

` + ReadyForNoteMarker + `

Do NOT emit the marker early. Do NOT emit it mid-sentence or with trailing text. The marker must be the sole content of the response when you are ready.

---

## Few-shot exemplar

The following example shows the expected cadence. Notice that in Turn 3 the clinician SKIPS onset (already answered) and asks about severity instead.

**Patient:** I've had a headache for the past two days. It started suddenly yesterday morning.

**Clinician Turn 1 (chief complaint, open-ended):**
I'm sorry to hear that — headaches can be really uncomfortable. Can you describe what the headache feels like, for example is it throbbing, pressing, or sharp?

**Patient:** It's a throbbing pain on the right side of my head.

**Clinician Turn 2 (region confirmed, moves to provocation/palliation):**
Thank you. Does anything make the headache better or worse, such as light, noise, movement, or lying down?

**Patient:** Bright light makes it much worse. Lying in a dark room helps a little.

**Clinician Turn 3 (onset already known from first message — SKIP onset, move to severity):**
That's helpful to know. On a scale of 0 to 10, with 10 being the worst pain you've ever felt, how would you rate the headache right now?

---

Begin the interview with the patient's first message.`

// rejectionGuidanceTemplate formats the reviewer-guidance message injected
// into an INTAKE interview turn's model context when the conversation's
// latest reviewed outcome is a physician rejection (task 3.3; see
// openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/spec.md,
// "Rejection Revision Loop"). It is deliberately NOT part of
// InterviewSystemPrompt (which is shared/static) — it is appended as a
// separate system-role message only for conversations with a current
// rejection, following generateInterviewTurn's message-assembly pattern.
//
// The reason is model-context-only: this string is used solely to build a
// Message passed to the model client. It must never be written to a
// store.CreateMessage call, a log line, or audit metadata — callers must not
// repurpose it for anything patient-facing. The instruction to the model not
// to quote the reason verbatim is prompt discipline, not a hard filter (see
// design.md); it does not guarantee the model will comply.
const rejectionGuidanceTemplate = "A physician reviewed a previous draft for this patient and requested: %s\n\nFocus your next questions on gathering whatever is needed to address this before concluding the interview. This is internal reviewer guidance — do not quote or repeat it to the patient."

// rejectionGuidanceMessage renders rejectionGuidanceTemplate with reason.
func rejectionGuidanceMessage(reason string) string {
	return fmt.Sprintf(rejectionGuidanceTemplate, reason)
}

// SOAPDraftSystemPrompt instructs the model to synthesise a structured SOAP
// note from a completed patient history interview. It is used as the system
// message in draftSOAPNote; the full conversation history follows.
//
// Output format contract (MUST be preserved so parseSOAPSections can parse it):
// The model MUST output the note using exactly these four section headers on
// their own lines, each followed by the section content:
//
//	SUBJECTIVE:
//	OBJECTIVE:
//	ASSESSMENT:
//	PLAN:
//
// Labels are matched case-insensitively and whitespace-tolerantly by the
// parser, but the prompt uses uppercase for consistency.
//
// Design constraints (see design.md SOAP payload shape):
//   - Subjective: history of present illness in the patient's words.
//   - Objective: ONLY objective data the patient actually reported
//     (e.g. self-measured vitals). Must NOT fabricate exam findings.
//     If none reported, write "None reported".
//   - Assessment: preliminary clinical impression — NOT a definitive diagnosis.
//   - Plan: recommended follow-up, monitoring, or referral.
const SOAPDraftSystemPrompt = `You are a licensed clinician writing a structured clinical SOAP note based on a completed patient history interview. A physician will review and may edit this note before any part of it reaches the patient.

## Output format — MANDATORY

Output the note using EXACTLY the following four section headers, each on its own line, followed by the section content. Do not add any other headers, preamble, or closing text.

SUBJECTIVE:
<summarise the history of present illness in the patient's own words: chief complaint, onset, character, severity, timing, provocation/palliation, relevant past history, medications, allergies>

OBJECTIVE:
<list ONLY objective data the patient actually reported — for example, self-measured blood pressure, temperature, or weight; do NOT fabricate physical examination findings that could not have been obtained in a text interview; if no objective data was reported, write exactly: None reported>

ASSESSMENT:
<your preliminary clinical impression; begin with "Preliminary assessment:" and do NOT state a definitive diagnosis; make clear this assessment requires physician review>

PLAN:
<actionable recommended plan including self-care, monitoring, when to seek emergency care, and suggested follow-up with a clinician>

## Rules

1. SUBJECTIVE must be drawn directly from what the patient reported during the interview. Do not invent or infer information not explicitly provided.
2. OBJECTIVE must contain ONLY findings the patient reported themselves (e.g. "states blood pressure 140/90 at home"). Do NOT write findings that would require a physical examination (auscultation, palpation, percussion, inspection). If no such data was provided, write "None reported".
3. ASSESSMENT must start with "Preliminary assessment:" and must not claim to be a definitive diagnosis. It must note that physician review is required.
4. PLAN must be safe, actionable, and appropriate for a text-based consultation.
5. Every section must be present and non-empty.
6. Use the exact headers shown above (SUBJECTIVE:, OBJECTIVE:, ASSESSMENT:, PLAN:) — no markdown bold, no hash signs, no extra colons or punctuation on the header line itself.`

// RelaySystemPrompt instructs the model to explain a plan that a physician has
// ALREADY reviewed and approved, during the PLAN_DELIVERED care phase (see
// openspec/changes/add-agent-care-loop/specs/ai-agent-runtime/spec.md,
// "Post-Approval Plan Relay", and design.md's "Relay grounding is prompt +
// provenance, not a new delivery gate"). It is used as the system message in
// every relay turn; the delivered recommendation's final content and the
// conversation history are supplied as additional context alongside it — the
// model does NOT write the plan in this turn, it only explains one that
// already exists.
//
// Design constraints:
//   - Explain-only: answers must be grounded in the delivered plan content and
//     conversation history supplied as context; no new clinical guidance.
//   - Deferral: questions the delivered plan does not cover get a fixed-style
//     deferral to the physician, not a speculative answer. This is prompt-
//     driven output text, not a distinct marker — see RelayOutcome for why.
//   - New-complaint signal: a genuinely new, plan-unrelated complaint must be
//     flagged with NewComplaintMarker (same bracketed-marker discipline as
//     ReadyForNoteMarker) so the runtime can reopen INTAKE.
const RelaySystemPrompt = `You are a licensed clinician following up with a patient about a treatment plan that a physician has ALREADY reviewed and approved. You did not write this plan in this turn — its final content, and the conversation history, are supplied to you separately as context. Your sole purpose in this conversation is to explain and clarify THAT approved plan.

## Rules — read carefully before every turn

1. **Explain only what the delivered plan contains.** Ground every answer in the delivered plan's content and the conversation history supplied to you as context. Do not add clinical guidance, dosing, medication changes, or advice that is not already present in the delivered plan. You are relaying an approved plan, not writing a new one.

2. **Defer anything the plan does not cover.** If the patient asks something the delivered plan does not address, do NOT speculate or improvise new clinical guidance. Tell them plainly: "That's a question for your physician — I can pass it along." Do not soften this into new clinical advice of your own.

3. **Never introduce a new diagnosis, prescription, or treatment change.** You are not re-evaluating the patient's condition. Only the physician can change the plan.

4. **New-complaint detection.** If the patient's message describes a NEW medical complaint or symptom that is unrelated to the delivered plan — not a question about the existing plan, but a different problem — do not attempt to explain or defer it. Instead, output the following marker on its own line and nothing else for that turn:

` + NewComplaintMarker + `

Do NOT emit this marker for questions about the existing plan, even difficult ones — only for a genuinely new, unrelated complaint. Do NOT emit it mid-sentence or with trailing text; it must be the sole content of the response when a new complaint is reported.

5. **Tone.** Be empathetic, non-judgmental, and concise. One or two short sentences is normally enough — you are relaying an already-approved plan, not conducting a new evaluation.

Begin by responding to the patient's message using only the delivered plan and conversation history supplied to you as context.`

// deliveredPlanContextTemplate formats the delivered recommendation's final
// content as a system-role grounding message for a PLAN_DELIVERED relay turn
// (task 4.2; see design.md's "Relay grounding is prompt + provenance, not a
// new delivery gate"). It is deliberately NOT part of RelaySystemPrompt
// (static/shared) — it is appended as a separate system-role message
// carrying the one piece of per-conversation grounding content the relay is
// allowed to draw on, mirroring generateInterviewTurn's
// rejectionGuidanceMessage pattern for injecting per-conversation context
// alongside a shared system prompt.
//
// The content is model-context-only: this string is built from
// store.Recommendation.FinalContent purely to construct a Message passed to
// the model client. It must never be written to a store.CreateMessage call,
// a log line, or audit metadata (PHI constraint).
const deliveredPlanContextTemplate = "The plan a physician already reviewed and approved for this patient is below. Ground every answer in this content and the conversation history that follows — do not add clinical guidance beyond it.\n\n%s"

// deliveredPlanContextMessage renders deliveredPlanContextTemplate with the
// delivered recommendation's final content.
func deliveredPlanContextMessage(finalContent string) string {
	return fmt.Sprintf(deliveredPlanContextTemplate, finalContent)
}
