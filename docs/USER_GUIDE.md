# HouseCall User Guide

Welcome to HouseCall, your HIPAA-compliant health assistant app. This guide will help you get started and make the most of the app's features.

## Table of Contents
1. [Getting Started](#getting-started)
2. [Using the Chat Interface](#using-the-chat-interface)
3. [Managing Conversations](#managing-conversations)
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

Face ID or Touch ID unlocks a session you have already signed in to with your password. If you have not signed in recently, you will be asked for your password.

The app will automatically log you out after 5 minutes of inactivity for security.

### Signing In Again When Chat Is Read-Only

Sometimes your sign-in with HouseCall expires, or you opened the app while your phone could not reach the internet. When that happens you can still open and read your earlier conversations, but you cannot send new messages. The chat shows a **Sign in to send messages** banner.

1. Make sure your phone has an internet connection
2. Tap the **Sign in to send messages** banner
3. Enter your password
4. Your messages start syncing again right away. You do not need to restart the app.

---

## Using the Chat Interface

### Starting a New Conversation

1. Open HouseCall and log in
2. Tap the **Chat** tab at the bottom
3. Tap the **+ New Chat** button (top right or center if no conversations)
4. Type your message in the text field at the bottom
5. Tap the **Send** button (blue arrow)

Your message will appear on the right in a blue bubble. While the HouseCall assistant is working on its answer, you will see a "waiting for a reply" indicator. The reply then appears all at once on the left in a gray bubble.

Responses come from the HouseCall assistant. Any clinical guidance is reviewed by a physician before it is delivered to you, so some replies may take longer to arrive.

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
- The HouseCall assistant provides general health information, NOT medical diagnoses
- For emergencies (chest pain, difficulty breathing, severe bleeding), call 911 immediately
- Always consult a healthcare provider for medical advice

### Understanding Assistant Responses

The assistant will:
- ✅ Ask clarifying questions about your symptoms
- ✅ Provide general health information
- ✅ Suggest when to see a doctor
- ✅ Recommend over-the-counter remedies (when appropriate)
- ✅ Explain medical terms in simple language

The assistant will NOT:
- ❌ Provide definitive diagnoses
- ❌ Prescribe medications
- ❌ Replace professional medical advice
- ❌ Handle medical emergencies (call 911 instead)

### Viewing Message History

- Scroll up to see older messages in the conversation
- Tap on any message to see its timestamp
- For long conversations, tap "Load earlier messages" at the top

---

## Managing Conversations

### Viewing All Conversations

1. Tap the **Chat** tab
2. Your conversations are listed newest first
3. Each conversation shows:
   - Title (based on first message)
   - Time of last message

### Opening a Conversation

- Tap any conversation in the list to open it
- All previous messages will load
- Continue chatting from where you left off

### Deleting a Conversation

**Method 1: Swipe to Delete**
1. In the conversation list, swipe left on a conversation
2. Tap the red **Delete** button
3. Confirm deletion

**Method 2: In-Conversation Delete**
1. Open the conversation
2. Tap the menu icon (three dots)
3. Select **Delete Conversation**
4. Confirm deletion

**Note**: Deleted conversations cannot be recovered. All messages are permanently erased.

### Organizing Conversations

Conversations are automatically sorted by last activity:
- Most recent conversations appear at the top
- Sending a message moves that conversation to the top
- No manual sorting needed

---

## Privacy & Security

HouseCall is designed with HIPAA compliance and your privacy as top priorities.

### How Your Data is Protected

#### 1. Encryption at Rest
- **All conversation data is encrypted** on your device using AES-256-GCM encryption
- Message content is never stored in plaintext
- Conversation titles are encrypted
- Even if someone accesses your device storage, they cannot read your conversations

#### 2. Encryption in Transit
- All communications with HouseCall's servers use **TLS 1.2+ encryption**
- Your messages are encrypted during transmission
- Network traffic cannot be intercepted and read

#### 3. Session Management
- Automatic logout after **5 minutes of inactivity**
- Re-authentication required when app returns from background
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
- Every action is logged for HIPAA compliance
- Logs include: logins, conversation access, deletions
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
- Clinical guidance is reviewed by a physician before it is delivered to you
- Replies are sent back to your phone and stored encrypted on your device

Your phone never contacts an outside AI company directly, and you do not need to set up any AI accounts or keys.

### Deleting Your Data

**To delete all your data:**
1. Log into HouseCall
2. Go to **Profile** tab
3. Scroll down to **Delete Account**
4. Confirm deletion

This will permanently delete:
- All conversations and messages
- Your user account
- All audit logs

**Note**: This action cannot be undone.

---

## Frequently Asked Questions

### General Usage

**Q: How much does HouseCall cost?**
A: HouseCall is free to download. There is nothing to set up for AI access; the assistant is part of the service.

**Q: Can I use HouseCall without an internet connection?**
A: You can read existing conversations offline, but sending new messages requires an internet connection and a valid sign-in. If you are offline, or your sign-in has expired, the chat is read-only until you sign in again.

**Q: How long are my conversations stored?**
A: Conversations are stored indefinitely on your device until you delete them. There are no automatic expiration or deletion policies.

**Q: Can I use HouseCall on multiple devices?**
A: Currently, HouseCall is iPhone-only.

**Q: Is HouseCall HIPAA compliant?**
A: Yes, HouseCall is designed with HIPAA compliance in mind. All data is encrypted at rest and in transit, with comprehensive audit logging.

### Assistant Questions

**Q: Who writes the replies?**
A: Replies come from the HouseCall assistant, which runs on HouseCall's servers. Clinical guidance is reviewed by a physician before it is delivered to you.

**Q: Why is the chat read-only?**
A: Your sign-in has expired or you opened the app while offline. Tap **Sign in to send messages** and enter your password to continue. See [Signing In Again When Chat Is Read-Only](#signing-in-again-when-chat-is-read-only).

### Privacy & Security Questions

**Q: Can anyone else see my conversations?**
A: No. Conversations are encrypted with a key unique to your account. Only you can decrypt and view them when logged in.

**Q: What happens if I lose my phone?**
A: Your conversations are encrypted and cannot be accessed without your password. Use iOS "Find My" to remotely wipe your device if needed.

**Q: Does HouseCall collect my health information?**
A: Your messages are sent to HouseCall's servers so the assistant and your physician can respond. They are encrypted in transit and stored encrypted on your device.

**Q: Can my employer/insurance see my conversations?**
A: No. HouseCall does not sell or share your conversations with employers or insurers. Your conversations are encrypted on your device.

**Q: Is it safe to screenshot my conversations?**
A: Screenshots are detected and logged for audit purposes. Avoid sharing screenshots that contain sensitive health information, as they are not encrypted outside the app.

### Technical Questions

**Q: Why is the reply slow?**
A: Response speed depends on:
- Your internet connection speed
- Whether a physician is reviewing the guidance
- How busy the service is

**Q: Why did my message fail to send?**
A: Common causes:
- No internet connection
- Your sign-in expired (tap **Sign in to send messages**)
- HouseCall's service is temporarily unavailable

**Q: How do I report a bug?**
A: Please report issues on GitHub: https://github.com/markolonius/HouseCall/issues

---

## Troubleshooting

### "Sign in to send messages"

**Problem**: You can read your conversations, but you cannot send messages.

**Solutions**:
1. Check your internet connection (WiFi or cellular)
2. Tap the **Sign in to send messages** banner and enter your password
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
2. Clinical guidance is reviewed by a physician, which can take extra time
3. Close and reopen the app to refresh your conversation

### "Unable to decrypt conversation"

**Problem**: You see an error when trying to open a conversation.

**Solutions**:
1. Logout and login again to refresh encryption keys
2. Verify you're logged in with the correct account
3. If the conversation is corrupted, you may need to delete it
4. Contact support if the issue persists

### App crashes when sending message

**Problem**: The app closes unexpectedly when you tap Send.

**Solutions**:
1. Check your device has enough free storage
2. Restart your iPhone
3. Update to the latest version of HouseCall
4. Delete unused conversations to free up space
5. If crashes continue, report the issue with device logs

---

## Medical Disclaimer

**IMPORTANT: HouseCall is NOT a substitute for professional medical advice, diagnosis, or treatment.**

- The HouseCall assistant provides general health information only
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

**App Issues**: Report bugs on [GitHub Issues](https://github.com/markolonius/HouseCall/issues)

**Privacy Policy**: See PRIVACY.md in the app repository

**License**: MIT License - See LICENSE file

---

## Version Information

**Current Version**: 1.0.0 (Phase 9: Documentation & Handoff)

**Last Updated**: November 23, 2025

**Compatibility**: iOS 17.0+

---

Thank you for using HouseCall! We hope this app helps you manage your health with convenience and privacy.
