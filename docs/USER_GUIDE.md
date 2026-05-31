# HouseCall User Guide

Welcome to HouseCall, your HIPAA-compliant AI health assistant app. This guide will help you get started and make the most of the app's features.

## Table of Contents
1. [Getting Started](#getting-started)
2. [Setting Up AI Providers](#setting-up-ai-providers)
3. [Using the Chat Interface](#using-the-chat-interface)
4. [Managing Conversations](#managing-conversations)
5. [Privacy & Security](#privacy--security)
6. [Frequently Asked Questions](#frequently-asked-questions)
7. [Troubleshooting](#troubleshooting)

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
3. Enter your password or passcode
4. (Optional) Enable Face ID or Touch ID for faster login
5. Tap **Log In**

The app will automatically log you out after 5 minutes of inactivity for security.

---

## Setting Up AI Providers

HouseCall supports three types of AI providers to power your health assistant:

### Option 1: OpenAI (ChatGPT)

OpenAI provides GPT-4 and GPT-3.5 models for conversational AI.

**Steps to Set Up:**
1. Get an API key from [OpenAI Platform](https://platform.openai.com/api-keys)
   - Sign up for an OpenAI account
   - Navigate to API Keys section
   - Click "Create new secret key"
   - Copy the key (it starts with `sk-`)
2. In HouseCall, go to **Profile** tab → **AI Provider Settings**
3. Select **OpenAI** as your provider
4. Paste your API key in the "API Key" field
5. Choose your preferred model:
   - **GPT-4**: Most capable, slower, higher cost
   - **GPT-4-Turbo**: Faster than GPT-4, good balance
   - **GPT-3.5-Turbo**: Fastest, lowest cost
6. Tap **Test Configuration** to verify
7. Tap **Save Settings**

**Cost**: OpenAI charges per token used. Typical conversation costs $0.01-0.10 depending on length.

### Option 2: Anthropic Claude

Anthropic provides Claude models known for helpful, harmless, and honest responses.

**Steps to Set Up:**
1. Get an API key from [Anthropic Console](https://console.anthropic.com/)
   - Sign up for an Anthropic account
   - Navigate to API Keys
   - Create a new key
   - Copy the key (it starts with `sk-ant-`)
2. In HouseCall, go to **Profile** tab → **AI Provider Settings**
3. Select **Claude** as your provider
4. Paste your API key in the "API Key" field
5. Choose your preferred model:
   - **Claude 3.7 Sonnet**: Best balance of intelligence and speed
   - **Claude 3 Opus**: Most capable
   - **Claude 3 Haiku**: Fastest, most affordable
6. Tap **Test Configuration** to verify
7. Tap **Save Settings**

**Cost**: Anthropic charges per token used. Pricing varies by model.

### Option 3: Custom/Self-Hosted

Use your own AI server running locally or on a private server.

**Supported Platforms:**
- Ollama
- llama.cpp server
- Any OpenAI-compatible API

**Steps to Set Up:**
1. Start your AI server (e.g., `ollama serve` for Ollama)
2. In HouseCall, go to **Profile** tab → **AI Provider Settings**
3. Select **Custom** as your provider
4. Enter the base URL (e.g., `http://localhost:11434`)
5. Enter model name (e.g., `llama3`, `mistral`)
6. (Optional) Enter API key if your server requires authentication
7. Tap **Test Configuration** to verify
8. Tap **Save Settings**

**Cost**: Free if self-hosted, but requires running your own server.

### Advanced Settings

- **Temperature** (0.0 - 2.0): Controls randomness
  - Lower (0.3-0.7): More focused, consistent responses
  - Higher (0.8-1.5): More creative, varied responses
- **Max Tokens** (100 - 4000): Maximum response length
  - Shorter: Faster, cheaper, more concise
  - Longer: More detailed explanations

---

## Using the Chat Interface

### Starting a New Conversation

1. Open HouseCall and log in
2. Tap the **Chat** tab at the bottom
3. Tap the **+ New Chat** button (top right or center if no conversations)
4. Type your message in the text field at the bottom
5. Tap the **Send** button (blue arrow)

Your message will appear on the right in a blue bubble. The AI's response will stream in from the left in a gray bubble.

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
- The AI assistant provides general health information, NOT medical diagnoses
- For emergencies (chest pain, difficulty breathing, severe bleeding), call 911 immediately
- Always consult a healthcare provider for medical advice

### Understanding AI Responses

The AI will:
- ✅ Ask clarifying questions about your symptoms
- ✅ Provide general health information
- ✅ Suggest when to see a doctor
- ✅ Recommend over-the-counter remedies (when appropriate)
- ✅ Explain medical terms in simple language

The AI will NOT:
- ❌ Provide definitive diagnoses
- ❌ Prescribe medications
- ❌ Replace professional medical advice
- ❌ Handle medical emergencies (call 911 instead)

### Viewing Message History

- Scroll up to see older messages in the conversation
- Tap on any message to see its timestamp
- For long conversations, tap "Load earlier messages" at the top

### Switching AI Providers

You can change which AI provider handles your conversation:

1. While in a conversation, tap the **menu icon** (three dots) in the top right
2. Select **Switch Provider**
3. Choose a different provider (OpenAI, Claude, or Custom)
4. Confirm the switch

The conversation history is maintained when you switch. A system message will indicate the provider change.

**Why switch?**
- Try different AI models for better responses
- Reduce costs by using a cheaper provider
- Access a faster provider for quicker responses
- Fallback if one provider is down

---

## Managing Conversations

### Viewing All Conversations

1. Tap the **Chat** tab
2. Your conversations are listed newest first
3. Each conversation shows:
   - Title (based on first message)
   - Time of last message
   - AI provider badge (OpenAI, Claude, or Custom)

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
- All communications with AI providers use **TLS 1.2+ encryption**
- Your messages are encrypted during transmission to OpenAI, Anthropic, or custom servers
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
- Fallback to password/passcode if biometrics unavailable

#### 6. Audit Logging
- Every action is logged for HIPAA compliance
- Logs include: logins, conversation access, AI interactions, deletions
- Logs contain NO personal health information (PHI)
- Logs are encrypted and stored securely

### What Data is Stored Locally

**On your iPhone:**
- Encrypted conversations and messages
- Your account information (encrypted)
- API keys (in iOS Keychain)
- Audit logs (encrypted)
- Provider settings

**NOT stored (unless you configure custom providers):**
- HouseCall does NOT sync data to iCloud
- Conversations stay on your device only
- No automatic cloud backups

### What Data is Sent to AI Providers

When you send a message:
- Your message content is sent to the selected AI provider (OpenAI, Anthropic, or custom)
- Previous conversation messages (for context)
- Your API key for authentication

**Important:**
- HouseCall recommends using AI providers with **Business Associate Agreements (BAAs)** for HIPAA compliance
- OpenAI and Anthropic offer BAAs for enterprise customers
- For self-hosted providers, you control all data

### API Keys Security

Your API keys are stored in the **iOS Keychain** with:
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` protection
- No iCloud sync
- Automatic deletion when app is uninstalled
- Never logged or exposed in error messages

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
- API keys from Keychain

**Note**: This action cannot be undone.

---

## Frequently Asked Questions

### General Usage

**Q: How much does HouseCall cost?**
A: HouseCall is free to download. You pay for AI provider usage (OpenAI, Anthropic) based on their pricing, or use a free self-hosted provider like Ollama.

**Q: Can I use HouseCall without an internet connection?**
A: You can view existing conversations offline, but sending new messages requires an internet connection to reach the AI provider.

**Q: How long are my conversations stored?**
A: Conversations are stored indefinitely on your device until you delete them. There are no automatic expiration or deletion policies.

**Q: Can I use HouseCall on multiple devices?**
A: Currently, HouseCall is iPhone-only and does not sync between devices. Each device has separate conversations.

**Q: Is HouseCall HIPAA compliant?**
A: Yes, HouseCall is designed with HIPAA compliance in mind. All data is encrypted at rest and in transit, with comprehensive audit logging. However, HIPAA compliance also depends on your choice of AI provider and whether they have signed a Business Associate Agreement (BAA).

### AI Provider Questions

**Q: Which AI provider is best?**
A: It depends on your needs:
- **OpenAI GPT-4**: Best for complex medical questions, most expensive
- **Claude**: Great balance of quality and cost, known for empathetic responses
- **Custom/Ollama**: Free and private, but requires technical setup

**Q: Can I use multiple providers?**
A: Yes! You can configure all three providers and switch between them at any time.

**Q: What if my API key stops working?**
A: This usually means:
- Your API key was revoked or expired
- You ran out of credits with the provider
- There's a typo in the key

Solution: Check your provider's dashboard, ensure you have credits, and re-enter the key in HouseCall settings.

**Q: Are my API keys shared with anyone?**
A: No. Your API keys are stored locally in your device's secure Keychain and are never sent to HouseCall servers (there are no HouseCall servers). They are only used to communicate directly with your chosen AI provider.

### Privacy & Security Questions

**Q: Can anyone else see my conversations?**
A: No. Conversations are encrypted with a key unique to your account. Only you can decrypt and view them when logged in.

**Q: What happens if I lose my phone?**
A: Your conversations are encrypted and cannot be accessed without your password/passcode. Use iOS "Find My" to remotely wipe your device if needed.

**Q: Does HouseCall collect my health information?**
A: HouseCall does not operate any servers or collect any data. All conversations stay on your device. The AI provider (OpenAI, Anthropic, or your custom server) receives your messages to generate responses.

**Q: Can my employer/insurance see my conversations?**
A: No. HouseCall does not share any data with third parties. Your conversations are private and encrypted on your device.

**Q: Is it safe to screenshot my conversations?**
A: Screenshots are detected and logged for audit purposes. Avoid sharing screenshots that contain sensitive health information, as they are not encrypted outside the app.

### Technical Questions

**Q: Why is the AI response slow?**
A: Response speed depends on:
- Your AI provider (GPT-4 is slower than GPT-3.5-Turbo)
- Your internet connection speed
- The length of your conversation history
- The max_tokens setting (longer = slower)

**Q: Why did my message fail to send?**
A: Common causes:
- No internet connection
- Invalid or expired API key
- Provider is down (check status pages)
- Rate limit exceeded (wait 60 seconds)

**Q: How do I report a bug?**
A: Please report issues on GitHub: https://github.com/markolonius/HouseCall/issues

---

## Troubleshooting

### "Unable to connect to AI service"

**Problem**: Your message won't send, and you see a connection error.

**Solutions**:
1. Check your internet connection (WiFi or cellular)
2. Verify your API key is entered correctly in Settings
3. Check if the AI provider is experiencing downtime:
   - OpenAI: https://status.openai.com
   - Anthropic: https://status.anthropic.com
4. Try switching to a different AI provider
5. Restart the app

### "API authentication failed"

**Problem**: The AI provider rejected your API key.

**Solutions**:
1. Go to **Profile** → **AI Provider Settings**
2. Double-check your API key is correct:
   - OpenAI keys start with `sk-`
   - Claude keys start with `sk-ant-`
3. Verify you have credits/quota with the provider
4. Re-enter the API key and tap **Save Settings**
5. Tap **Test Configuration** to verify

### "Rate limit exceeded"

**Problem**: You've sent too many messages too quickly.

**Solutions**:
1. Wait for the countdown timer to complete (usually 60 seconds)
2. Upgrade to a higher tier with your AI provider for more quota
3. Switch to a different AI provider temporarily

### Messages appear slowly or stuttering

**Problem**: AI responses are choppy or laggy.

**Solutions**:
1. Check your internet connection speed
2. Close other apps to free memory
3. Delete old conversations to reduce app data size
4. Reduce max_tokens in AI Provider Settings for shorter responses
5. Switch to a faster model (e.g., GPT-3.5-Turbo instead of GPT-4)

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

### Custom provider not working

**Problem**: Your self-hosted AI server isn't responding.

**Solutions**:
1. Verify your server is running:
   - For Ollama: Run `ollama serve` in terminal
   - Check server logs for errors
2. Ensure the base URL is correct:
   - Include full path: `http://localhost:11434/v1/chat/completions`
   - Use `http://` for local servers (not `https://`)
3. Test your server with curl:
   ```bash
   curl http://localhost:11434/v1/models
   ```
4. Check firewall settings if using remote server
5. Verify the model name is correct and available

---

## Medical Disclaimer

**IMPORTANT: HouseCall is NOT a substitute for professional medical advice, diagnosis, or treatment.**

- The AI assistant provides general health information only
- Always consult a qualified healthcare provider for medical concerns
- For emergencies, call 911 or go to the nearest emergency room immediately
- Do not delay seeking medical care based on AI responses
- The AI cannot diagnose conditions, prescribe medications, or provide treatment

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

**Provider Support**:
- OpenAI: https://help.openai.com
- Anthropic: https://support.anthropic.com
- Custom providers: Contact your server administrator

**Privacy Policy**: See PRIVACY.md in the app repository

**License**: MIT License - See LICENSE file

---

## Version Information

**Current Version**: 1.0.0 (Phase 9: Documentation & Handoff)

**Last Updated**: November 23, 2025

**Compatibility**: iOS 17.0+

---

Thank you for using HouseCall! We hope this app helps you manage your health with convenience and privacy.
