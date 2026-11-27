# HouseCall User Guide

Welcome to HouseCall, your health assistant app, designed with HIPAA compliance in mind. This guide will help you get started and make the most of the app's features.

## Table of Contents
1. [Getting Started](#getting-started)
2. [Using the Chat Interface](#using-the-chat-interface)
3. [Your Conversation](#your-conversation)
4. [Privacy & Security](#privacy--security)
5. [Frequently Asked Questions](#frequently-asked-questions)
6. [Troubleshooting](#troubleshooting)

---

## Getting Started

### Creating Your Account

1. Open HouseCall on your iPhone
2. Tap **Sign Up** on the welcome screen
3. Enter your email address
4. Create a strong password (at least 12 characters with uppercase, lowercase, numbers, and special characters)
5. Enter your full name
6. Tap **Create Account**

### Logging In

1. Open HouseCall
2. Enter your email address
3. Enter your password
4. (Optional) Enable Face ID or Touch ID for faster login
5. Tap **Log In**

Face ID or Touch ID opens the app on your phone, but it does not sign you in to HouseCall's servers. After a Face ID or Touch ID login you can read your conversations, but chat is usually read-only until you enter your password (see below).

The app will automatically log you out after 5 minutes of inactivity for security. Logging out, or the inactivity timeout, ends your sign-in with HouseCall's servers, so you will need your password to send messages again.

### Signing In Again When Chat Is Read-Only

Sometimes you can read your earlier conversations but cannot send new messages. This happens when:
- you signed in with Face ID or Touch ID. Chat is usually read-only after this; if the app was force-quit, an earlier sign-in may still be active.
- your sign-in with HouseCall expired or was rejected
- you signed in while your phone could not reach the internet

The chat then shows a **Sign in to send messages** banner with a **Sign in** button.

1. Make sure your phone has an internet connection
2. Tap **Sign in** in the banner
3. Enter your password
4. Your messages start syncing again right away. You do not need to restart the app.

---

## Using the Chat Interface

### Starting a Conversation

1. Open HouseCall and log in
2. Your conversation opens automatically
3. Type your message in the text field at the bottom
4. Tap the **Send** button (blue arrow)

Your message will appear on the right in a blue bubble. While the HouseCall assistant is working on its answer, you will see a "waiting for a reply" indicator. The reply then appears all at once on the left in a gray bubble.

Replies come from the HouseCall assistant. The assistant asks you questions about your symptoms. Its assessment and care plan are reviewed and approved by a physician before you see them, so that part may take longer to arrive. The assistant is instructed to tell you to call 911 if you describe an emergency, but do not wait for it. If you think you are having an emergency, call 911 yourself now.

### Sending Messages

**What to include in your message:**
- Describe your symptoms clearly
- Include when they started
- Mention severity (mild, moderate, severe)
- List any relevant medical history

**Example good messages:**
- "I've had a headache for 3 days. It's moderate pain on the right side of my head."
- "My 5-year-old has a fever of 101°F that started yesterday morning."
- "I have chest pain when I breathe deeply. Started an hour ago."

**Important Notes:**
- The HouseCall assistant is not a doctor and does NOT give medical diagnoses
- For emergencies (chest pain, difficulty breathing, severe bleeding), call 911 immediately
- Always consult a healthcare provider for medical advice

### Understanding Assistant Responses

The assistant will:
- ✅ Ask you questions about your symptoms, one at a time
- ✅ Be instructed to tell you to call 911 if you describe an emergency (but do not rely on it; call 911 yourself)
- ✅ Prepare an assessment and care plan, which a physician reviews and approves before you see it

The assistant will NOT:
- ❌ Provide definitive diagnoses
- ❌ Prescribe medications
- ❌ Replace professional medical advice
- ❌ Handle medical emergencies (call 911 instead)

### Viewing Message History

- Scroll up to see older messages in the conversation
- Tap on any message to see its timestamp

---

## Your Conversation

HouseCall opens a single conversation for you automatically, titled "Chat". Your earlier messages load when you open it, and you can continue from where you left off.

The app does not currently let you create, delete, or switch between conversations. Account deletion is also not yet available in the app (see [Deleting Your Data](#deleting-your-data)).

---

## Privacy & Security

HouseCall is designed with HIPAA compliance and your privacy as top priorities.

### How Your Data is Protected

#### 1. Encryption at Rest
- **The copy of your conversation on your device is encrypted** using AES-256-GCM encryption
- Message content and conversation titles are never stored in plaintext on your device
- Even if someone accesses your device storage, they cannot read the local copy
- Messages are also stored on HouseCall's servers so your care team can see them

#### 2. Encryption in Transit
- All communications with HouseCall's servers use **TLS 1.2+ encryption**
- Your messages are protected from being read in transit

#### 3. Session Management
- Automatic logout after **5 minutes of inactivity**
- If the app has been in the background longer than the 5-minute inactivity timeout, you will need to sign in again
- Session tokens are securely stored in iOS Keychain

#### 4. Screen Protection
- **Privacy screen** shown when app is in the background
- Your conversations are hidden in the app switcher
- Screenshots are detected and logged for audit purposes

#### 5. Biometric Authentication
- Enable **Face ID or Touch ID** for quick, secure access
- Your biometric data never leaves your device
- Fallback to your password if biometrics are unavailable

#### 6. Audit Logging
- Key events are logged for HIPAA compliance
- Logs include: logins, conversation access, and assistant interactions (including failures)
- Logs contain NO personal health information (PHI)
- Logs are encrypted and stored securely

### What Data is Stored Locally

**On your iPhone:**
- Encrypted conversations and messages
- Your account information (encrypted)
- Audit logs (encrypted)

HouseCall does NOT sync data to iCloud and does not make automatic iCloud backups.

### What Data is Sent to HouseCall

When you send a message:
- Your message is sent to HouseCall's servers, where the HouseCall assistant prepares a reply
- The assessment and care plan are reviewed and approved by a physician before you see them
- Replies are sent back to your phone and stored encrypted on your device

The app only talks to HouseCall's servers, and you do not need to set up any AI accounts or keys.

### Deleting Your Data

Account deletion is not yet available in the app. To ask about your data, contact support.

---

## Frequently Asked Questions

### General Usage

**Q: How much does HouseCall cost?**
A: HouseCall is free to download. There is nothing to set up for AI access; the assistant is part of the service.

**Q: Can I use HouseCall without an internet connection?**
A: You can read existing conversations offline, but sending new messages requires an internet connection and a valid sign-in. If you are offline but still signed in, chat stays active, and your message is saved and sent automatically once you're back online. If your sign-in has expired, or you signed in while offline, the chat is read-only until you sign in again.

**Q: How long are my conversations stored?**
A: Your messages are stored encrypted on your device and also on HouseCall's servers. The app does not currently let you delete conversations. Contact support with questions about your data.

**Q: Can I use HouseCall on multiple devices?**
A: Currently, HouseCall is iPhone-only.

**Q: Is HouseCall HIPAA compliant?**
A: HouseCall is designed with HIPAA compliance in mind. The copy on your device is encrypted at rest, data is sent over TLS, and key events are audit-logged.

### Assistant Questions

**Q: Who writes the replies?**
A: Replies come from the HouseCall assistant, which runs on HouseCall's servers. It asks you questions about your symptoms. Its assessment and care plan are reviewed and approved by a physician before you see them. It is instructed to tell you to call 911 if you describe an emergency, but do not wait for it. If you think you are having an emergency, call 911 yourself now.

**Q: Why is the chat read-only?**
A: You signed in with Face ID or Touch ID (usually read-only afterwards), your sign-in has expired, or you signed in while offline. Tap **Sign in** in the banner and enter your password to continue. See [Signing In Again When Chat Is Read-Only](#signing-in-again-when-chat-is-read-only).

### Privacy & Security Questions

**Q: Can anyone else see my conversations?**
A: You can see them, and so can the clinicians and staff caring for you, since your messages are stored on HouseCall's servers and reviewed in the physician portal. The copy on your device is encrypted with a key unique to your account.

**Q: What happens if I lose my phone?**
A: The copy of your conversations on your device is encrypted and cannot be read without signing in. Use iOS "Find My" to remotely wipe your device if needed.

**Q: Does HouseCall collect my health information?**
A: Your messages are sent to HouseCall's servers so the assistant and your physician can respond. They are encrypted in transit and stored encrypted on your device.

**Q: Can my employer/insurance see my conversations?**
A: A privacy policy will be published before HouseCall is available to patients.

**Q: Is it safe to screenshot my conversations?**
A: Screenshots are detected and logged for audit purposes. Avoid sharing screenshots that contain sensitive health information, as they are not encrypted outside the app.

### Technical Questions

**Q: Why is the reply slow?**
A: Response speed depends on:
- Your internet connection speed
- Whether a physician is still reviewing the assessment and care plan
- How busy the service is

**Q: Why did my message fail to send?**
A: Common causes:
- No internet connection
- Your sign-in expired or you used Face ID / Touch ID (tap **Sign in** in the banner)
- HouseCall's service is temporarily unavailable

**Q: How do I report a bug?**
A: Please report issues on GitHub: https://github.com/markolonius/HouseCall/issues. Do not include personal or health information in GitHub issues.

---

## Troubleshooting

### "Sign in to send messages"

**Problem**: You can read your conversations, but you cannot send messages.

**Solutions**:
1. Check your internet connection (WiFi or cellular)
2. Tap **Sign in** in the banner and enter your password
3. If signing in fails, try again in a few minutes or restart the app

### "Unable to connect"

**Problem**: Your message won't send, and you see a connection error.

**Solutions**:
1. Check your internet connection (WiFi or cellular)
2. Try again in a few minutes in case the service is temporarily unavailable
3. Restart the app

### Waiting for a reply for a long time

**Problem**: The "waiting for a reply" indicator stays on screen.

**Solutions**:
1. Check your internet connection
2. The assessment and care plan are reviewed by a physician, which can take extra time
3. Close and reopen the app to refresh your conversation

### "Unable to decrypt conversation"

**Problem**: You see an error when trying to open a conversation.

**Solutions**:
1. Logout and login again to refresh encryption keys
2. Verify you're logged in with the correct account
3. Contact support if the issue persists

### App crashes when sending message

**Problem**: The app closes unexpectedly when you tap Send.

**Solutions**:
1. Check your device has enough free storage
2. Restart your iPhone
3. Update to the latest version of HouseCall
4. If crashes continue, report the issue (do not include logs or screenshots that contain personal or health information)

---

## Medical Disclaimer

**IMPORTANT: HouseCall is NOT a substitute for professional medical advice, diagnosis, or treatment.**

- The HouseCall assistant is not a doctor and does not give medical diagnoses
- Always consult a qualified healthcare provider for medical concerns
- For emergencies, call 911 or go to the nearest emergency room immediately
- Do not delay seeking medical care based on assistant responses
- The assistant cannot diagnose conditions, prescribe medications, or provide treatment

**Emergency Warning Signs** (call 911):
- Chest pain or pressure
- Difficulty breathing
- Severe bleeding
- Loss of consciousness
- Sudden severe headache
- Sudden numbness or weakness
- Severe allergic reaction
- Suicidal thoughts

---

## Support & Contact

**App Issues**: Report bugs on [GitHub Issues](https://github.com/markolonius/HouseCall/issues). Do not include personal or health information in GitHub issues.

**Privacy Policy**: A privacy policy will be published before HouseCall is available to patients.

---

Thank you for using HouseCall! We hope this app helps you manage your health with convenience and privacy.
