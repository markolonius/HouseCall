# Project Context

## Purpose
HouseCall is a SwiftUI-based iOS healthcare application that provides continuous remote healthcare 24/7 through AI-powered physician assistants. The app enables patients to interact with AI agents via chat, video, and audio interfaces to collect health data, symptoms, and vital signs. AI agents analyze patient information (including accelerometer data and connected health device readings) to generate clinical assessments and treatment plans for physician review and approval.

### Core Mission
Deliver accessible, continuous healthcare by bridging the gap between patients and physicians through intelligent AI assistants that can:
- Conduct preliminary patient assessments through natural conversation
- Collect and analyze health data from multiple sources (user input, sensors, connected devices)
- Generate evidence-based assessment and treatment plans for physician oversight
- Enable 24/7 patient monitoring and support

### MVP Scope
The Minimum Viable Product focuses on foundational capabilities:
1. **User Account Management**: Secure account creation and authentication
2. **AI Conversation Interface**: Chat and voice-based interaction with AI health assistant
3. **Basic Data Collection**: Capture patient-reported symptoms and health information
4. **Secure Data Storage**: HIPAA-compliant local and cloud data persistence

## Tech Stack

### Current (Template Foundation)
- **Platform**: iOS (iPhone/iPad)
- **Language**: Swift 5.x
- **UI Framework**: SwiftUI
- **Data Persistence**: Core Data (SQLite backend)
- **Build System**: Xcode Build System (xcodebuild)
- **Testing**: Swift Testing framework (modern `@Test` macro syntax, not XCTest)
- **Minimum iOS Version**: iOS 15+ (typical for modern SwiftUI)

### Planned (Healthcare Features)
- **AI Integration**: Large Language Models for conversational AI (e.g., OpenAI GPT, Claude API, or on-device models)
- **Real-time Communication**:
  - Chat: WebSocket or similar for real-time messaging
  - Voice: AVFoundation for audio recording/playback, Speech framework for transcription
  - Video: AVFoundation for video capture and streaming
- **Health Device Integration**:
  - CoreBluetooth for BLE device connectivity (blood pressure cuffs, thermometers, glucometers, etc.)
  - HealthKit for iOS health data integration
- **Motion & Sensor Data**: CoreMotion for accelerometer and device motion tracking
- **Healthcare Interoperability**:
  - FHIR (Fast Healthcare Interoperability Resources) for data exchange with other healthcare institutions
  - HL7 standards for clinical data integration
- **Security & Compliance**:
  - End-to-end encryption for all patient data
  - HIPAA-compliant cloud backend (AWS HIPAA, Azure Health, or Google Cloud Healthcare API)
  - Secure authentication (OAuth 2.0, biometric authentication)
  - Audit logging for all data access
- **Backend Services**: RESTful API or GraphQL for cloud integration (technology TBD)
- **Analytics**: Privacy-preserving analytics for clinical insights (HIPAA-compliant)

## Project Conventions

### Code Style
- **Swift Naming**: Follow Swift API Design Guidelines
  - Types: `PascalCase` (e.g., `PersistenceController`, `ContentView`)
  - Properties/Functions: `camelCase` (e.g., `managedObjectContext`, `addItem()`)
  - Constants: `camelCase` for local, `PascalCase` for static/global
- **SwiftUI Patterns**:
  - Use property wrappers (`@State`, `@Environment`, `@FetchRequest`)
  - Prefer declarative view composition
  - Extract complex views into separate components
- **File Organization**: One primary type per file, named after the type
- **Imports**: Group by framework (Foundation, SwiftUI, CoreData)

### Architecture Patterns
- **App Architecture**: SwiftUI App Lifecycle (`@main` with `App` protocol)
- **Data Layer**:
  - Singleton pattern for `PersistenceController.shared` (production)
  - Separate preview instance (`PersistenceController.preview`) for SwiftUI previews
  - Environment-based dependency injection for `managedObjectContext`
- **UI Pattern**: Master-detail navigation with `NavigationView`
- **CRUD Operations**:
  - Create: Toolbar buttons triggering context insertion
  - Read: `@FetchRequest` with `NSSortDescriptor` for automatic UI updates
  - Delete: Swipe-to-delete with context delete operations
  - All mutations followed by `context.save()`

### Testing Strategy
- **Unit Tests** (`HouseCallTests`):
  - Use Swift Testing framework with `@Test` macro
  - Use `#expect(...)` for assertions (not `XCTAssert*`)
  - Import with `@testable import HouseCall` for internal access
  - Test business logic and data transformations
- **UI Tests** (`HouseCallUITests`):
  - End-to-end testing of user workflows
  - Test navigation, CRUD operations, and UI state
- **Preview Testing**: Use `PersistenceController.preview` for SwiftUI previews to avoid affecting production data
- **Test Execution**: Run via `xcodebuild test -scheme HouseCall -destination 'platform=iOS Simulator,name=iPhone 15'`

### Git Workflow
- **Main Branch**: `main` (currently at commit `1a2cdeb Initial Commit`)
- **Commit Style**: Conventional Commits preferred for clarity
- **Untracked Files**: `.claude/`, `.opencode/`, `AGENTS.md`, `CLAUDE.md`, `openspec/` (configuration and documentation)

## Domain Context

### Healthcare Domain Knowledge

#### Clinical Workflow
1. **Patient Intake**: User reports symptoms, medical history, current medications
2. **AI Assessment**: AI agent conducts structured interview, analyzes reported data and device readings
3. **Data Collection**: Gathers vital signs from connected devices, accelerometer data, patient-reported outcomes
4. **Clinical Analysis**: AI generates preliminary assessment with differential diagnoses
5. **Treatment Plan**: AI proposes evidence-based treatment recommendations
6. **Physician Review**: Licensed physician reviews, modifies, and approves assessment and plan
7. **Patient Communication**: Approved plan delivered to patient with instructions
8. **Continuous Monitoring**: Ongoing data collection and follow-up assessments

#### Health Data Types
- **Patient Demographics**: Name, DOB, gender, contact information
- **Medical History**: Conditions, allergies, medications, procedures, immunizations
- **Vital Signs**: Blood pressure, heart rate, temperature, oxygen saturation, glucose levels
- **Symptoms**: Patient-reported symptoms with severity, duration, context
- **Device Readings**: Real-time data from connected Bluetooth health devices
- **Motion Data**: Accelerometer readings for activity tracking, fall detection, gait analysis
- **Conversation History**: Chat, voice, and video interaction logs for clinical context
- **Clinical Assessments**: AI-generated and physician-approved diagnoses and plans

#### Interoperability Standards
- **FHIR Resources**: Patient, Observation, Condition, MedicationStatement, DiagnosticReport, CarePlan
- **Data Exchange**: Fetch patient records from external healthcare systems (EHR integration)
- **Terminology Standards**: SNOMED CT, LOINC, RxNorm for clinical coding

### Current Data Model (Template - Will Be Replaced)
- **Model Name**: "HouseCall" (defined in `HouseCall.xcdatamodeld/HouseCall.xcdatamodel`)
- **Entities**:
  - `Item`: Placeholder entity with timestamp (will be replaced with healthcare entities)
- **Planned Entities**:
  - `Patient`: User profile, demographics, medical history
  - `Conversation`: Chat/voice/video session records
  - `Message`: Individual messages within conversations
  - `VitalSign`: Device readings and manual entries
  - `Assessment`: AI-generated clinical assessments
  - `TreatmentPlan`: Physician-approved care plans
  - `Device`: Connected health device registry

### Key Components (Current)
1. **HouseCallApp.swift**: App entry point, initializes Core Data stack
2. **Persistence.swift**: Core Data stack management (will be enhanced with encryption)
3. **ContentView.swift**: Placeholder UI (will become main dashboard)
4. **Item+CoreDataClass/Properties**: Template entity (will be replaced)

### Planned Architecture Components
1. **Authentication Module**: Secure login, biometric auth, session management
2. **AI Conversation Engine**: Chat/voice interface with LLM integration
3. **Device Manager**: Bluetooth device discovery, pairing, data synchronization
4. **FHIR Client**: Healthcare data exchange with external systems
5. **Encryption Layer**: End-to-end encryption for PHI (Protected Health Information)
6. **Audit Logger**: HIPAA-compliant access logging
7. **Clinical Decision Support**: Evidence-based recommendation engine

## Important Constraints

### Regulatory & Compliance Constraints (CRITICAL)
- **HIPAA Compliance**: All Protected Health Information (PHI) must be:
  - Encrypted at rest (AES-256 or equivalent)
  - Encrypted in transit (TLS 1.2+ for all network communications)
  - Access-controlled with audit logging
  - Deletable upon patient request (right to be forgotten)
  - Backed up securely with disaster recovery plan
- **FDA Considerations**: Depending on clinical claims, may require FDA clearance as a medical device
- **Medical Liability**: AI recommendations are preliminary and require physician oversight
- **State Licensing**: Physicians must be licensed in patient's state for telemedicine
- **Informed Consent**: Users must consent to AI-assisted care and data collection
- **Data Retention**: Comply with medical record retention laws (typically 7+ years)
- **Audit Requirements**: Complete audit trail of all data access and modifications
- **Business Associate Agreements**: Required for any third-party service processing PHI

### Security Constraints (CRITICAL)
- **Authentication**:
  - Multi-factor authentication required
  - Biometric authentication (Face ID/Touch ID) strongly recommended
  - Session timeout and automatic logout
  - Password requirements must meet healthcare security standards
- **Data Protection**:
  - End-to-end encryption for all conversations
  - Encrypted Core Data store using `NSPersistentStoreFileProtectionKey`
  - Secure keychain storage for credentials and encryption keys
  - No PHI in device logs or analytics
  - Secure deletion of cached data
- **Network Security**:
  - Certificate pinning for API connections
  - VPN or secure tunnel for data transmission
  - No storage of PHI on unsecured cloud services
- **Device Security**:
  - Require device passcode/biometrics to be enabled
  - Detect and prevent use on jailbroken devices
  - Remote wipe capability for lost/stolen devices

### Technical Constraints
- **iOS Platform Only**: No macOS/watchOS/tvOS support currently (may expand to iPad optimization)
- **Minimum iOS Version**: iOS 15+ (may need iOS 16+ for advanced security features)
- **Bluetooth Limitations**: CoreBluetooth requires physical device for testing (not available in Simulator)
- **Real-time Requirements**: Chat/voice must handle latency gracefully for poor network conditions
- **Offline Capability**: Must handle offline scenarios with local data sync when reconnected
- **Core Data Encryption**: Requires FileVault or similar encryption for production PHI storage
- **AI Model Constraints**:
  - Response time must be <5 seconds for good UX
  - On-device models preferred for privacy, but may lack clinical accuracy
  - Cloud-based models require HIPAA-compliant API providers

### Development Constraints
- **Error Handling**: Template contains `fatalError()` calls that MUST be replaced:
  - `ContentView.swift` lines 56, 71 (save errors)
  - `Persistence.swift` lines 27, 52 (load/save errors)
  - Healthcare apps cannot crash on data errors
- **Preview Data**: Always use `PersistenceController.preview` for SwiftUI previews
- **No Test Data in Production**: Strict separation between test and production environments
- **Code Signing**: Requires Apple Developer Enterprise account or App Store distribution
- **Accessibility**: Must comply with ADA/Section 508 for healthcare accessibility

### Quality Standards (Healthcare-Grade)
- **Clinical Accuracy**: AI assessments must cite evidence-based sources
- **Reliability**: 99.9% uptime SLA for critical health monitoring features
- **Data Integrity**: Zero tolerance for data loss or corruption of health records
- **Privacy**: No PHI sharing without explicit patient consent
- **Transparency**: AI decision-making must be explainable to patients and physicians
- **Error Handling**: Graceful degradation, never crash with patient data loss
- **Testing**:
  - 90%+ code coverage for critical health data paths
  - Clinical validation of AI recommendations
  - Penetration testing for security vulnerabilities
  - HIPAA compliance audit before launch
- **Accessibility**: WCAG 2.1 AA compliance minimum for healthcare equity
- **Internationalization**: Support for multiple languages (Spanish, etc.) for healthcare access

## External Dependencies

### Apple Frameworks (Current)
- **SwiftUI**: Primary UI framework for declarative interface design
- **CoreData**: Persistence layer for local data storage
- **Foundation**: Core Swift utilities and data types

### Apple Frameworks (Planned for Healthcare Features)
- **CoreBluetooth**: BLE connectivity for health devices
- **HealthKit**: Integration with Apple Health for vital signs and activity data
- **CoreMotion**: Accelerometer and motion sensor data collection
- **AVFoundation**: Audio/video recording, playback, and streaming
- **Speech**: Voice-to-text transcription for voice conversations
- **LocalAuthentication**: Face ID/Touch ID biometric authentication
- **Security**: Keychain access, encryption, secure data storage
- **CryptoKit**: Modern cryptographic operations (iOS 13+)
- **Network**: Low-level networking with privacy and security features
- **UserNotifications**: Push notifications for clinical alerts

### Cloud & Backend Services (Planned)
- **HIPAA-Compliant Backend Options**:
  - AWS: HealthLake, Lambda, API Gateway, Cognito (with BAA)
  - Azure: Health Data Services, Functions, API Management
  - Google Cloud: Healthcare API, Cloud Functions
- **AI/LLM Providers** (HIPAA-compliant required):
  - OpenAI API (with BAA for GPT models)
  - Anthropic Claude API (with healthcare compliance)
  - Azure OpenAI Service (HIPAA-compliant)
  - On-device models (Core ML) for privacy-first approach
- **Real-time Communication**:
  - WebSocket servers for chat (Socket.io, custom implementation)
  - Twilio Video API (HIPAA-eligible) for video calls
  - Agora.io (healthcare-compliant) for audio/video streaming

### Healthcare Data Standards & APIs
- **FHIR (Fast Healthcare Interoperability Resources)**:
  - SMART on FHIR for EHR integration
  - FHIR REST APIs for data exchange with healthcare systems
- **HL7 Standards**: Clinical data messaging and integration
- **Terminology Services**:
  - SNOMED CT: Clinical terminology
  - LOINC: Laboratory and clinical observations
  - RxNorm: Medication terminology
- **EHR Integration**: Epic, Cerner, AllScripts APIs (requires partnerships)

### Third-Party SDKs (Planned - All Must Be HIPAA-Compatible)
- **Bluetooth Health Devices**:
  - Manufacturer SDKs for FDA-approved devices (Omron, Withings, iHealth, etc.)
  - Generic BLE health device protocols
- **Authentication**: Auth0 (healthcare tier), Firebase Auth (BAA required), or custom OAuth 2.0
- **Analytics**: HIPAA-compliant options only (no standard Google Analytics/Mixpanel)
- **Error Monitoring**: Sentry (HIPAA plan) or custom solution
- **Encryption**: End-to-end encryption libraries if needed beyond CryptoKit

### Development & Build Tools
- **Xcode**: Primary IDE and build environment
- **xcodebuild**: Command-line build tool for CI/CD integration
- **iOS Simulator**: Testing and development (note: BLE requires physical device)
- **Swift Package Manager**: Dependency management (preferred for security auditing)
- **Fastlane**: Automation for builds, testing, and deployment (optional)
- **CI/CD**: GitHub Actions, Jenkins, or CircleCI with security scanning

### Testing & Security Tools
- **XCTest/Swift Testing**: Unit and UI testing frameworks
- **OWASP Mobile Security Testing Guide**: Security validation framework
- **Static Analysis**: SwiftLint, SonarQube for code quality
- **Penetration Testing**: Third-party security audit tools
- **HIPAA Compliance Scanner**: Automated compliance verification tools

### Compliance & Legal
- **Business Associate Agreements (BAAs)**: Required for ALL third-party services handling PHI
- **Data Processing Agreements**: GDPR compliance if serving EU patients
- **Medical Malpractice Insurance**: Coverage for telemedicine services
- **HIPAA Security Risk Assessment**: Annual requirement

## Project Structure

### Current Structure (Template)
```
HouseCall/
├── HouseCall/                  # Main app target
│   ├── HouseCallApp.swift     # App entry point
│   ├── ContentView.swift      # Placeholder UI (will become dashboard)
│   ├── Persistence.swift      # Core Data stack (needs encryption)
│   ├── HouseCall.xcdatamodeld # Core Data model (needs healthcare entities)
│   └── Assets.xcassets        # Images and resources
├── HouseCallTests/            # Unit tests (Swift Testing)
├── HouseCallUITests/          # UI tests
├── openspec/                  # OpenSpec change management
│   ├── project.md             # This file - project context
│   └── AGENTS.md              # OpenSpec workflow guidance
├── CLAUDE.md                  # AI assistant guidance (project-specific)
└── HouseCall.xcodeproj/       # Xcode project file
```

### Planned Structure (Healthcare App)
```
HouseCall/
├── HouseCall/
│   ├── App/
│   │   ├── HouseCallApp.swift              # App entry point
│   │   ├── AppDelegate.swift               # App lifecycle (if needed)
│   │   └── SceneDelegate.swift             # Scene management (if needed)
│   │
│   ├── Core/
│   │   ├── Persistence/
│   │   │   ├── PersistenceController.swift # Core Data stack with encryption
│   │   │   ├── CoreDataModels/
│   │   │   │   ├── Patient+CoreData.swift
│   │   │   │   ├── Conversation+CoreData.swift
│   │   │   │   ├── Message+CoreData.swift
│   │   │   │   ├── VitalSign+CoreData.swift
│   │   │   │   └── Assessment+CoreData.swift
│   │   │   └── HouseCall.xcdatamodeld
│   │   │
│   │   ├── Security/
│   │   │   ├── EncryptionManager.swift     # AES-256 encryption
│   │   │   ├── KeychainManager.swift       # Secure credential storage
│   │   │   ├── BiometricAuth.swift         # Face ID/Touch ID
│   │   │   └── AuditLogger.swift           # HIPAA audit trail
│   │   │
│   │   ├── Networking/
│   │   │   ├── APIClient.swift             # Base API client with certificate pinning
│   │   │   ├── WebSocketManager.swift      # Real-time chat connection
│   │   │   └── FHIRClient.swift            # Healthcare data exchange
│   │   │
│   │   └── Services/
│   │       ├── AuthenticationService.swift  # User auth and session management
│   │       ├── AIConversationService.swift  # LLM integration
│   │       └── DeviceManager.swift          # Bluetooth device coordination
│   │
│   ├── Features/
│   │   ├── Authentication/
│   │   │   ├── Views/
│   │   │   │   ├── LoginView.swift
│   │   │   │   ├── SignUpView.swift
│   │   │   │   └── BiometricSetupView.swift
│   │   │   └── ViewModels/
│   │   │       └── AuthenticationViewModel.swift
│   │   │
│   │   ├── Dashboard/
│   │   │   ├── Views/
│   │   │   │   ├── DashboardView.swift
│   │   │   │   ├── VitalSignsCardView.swift
│   │   │   │   └── QuickActionsView.swift
│   │   │   └── ViewModels/
│   │   │       └── DashboardViewModel.swift
│   │   │
│   │   ├── Conversation/
│   │   │   ├── Views/
│   │   │   │   ├── ChatView.swift          # Text chat interface
│   │   │   │   ├── VoiceView.swift         # Voice conversation interface
│   │   │   │   ├── VideoView.swift         # Video consultation interface
│   │   │   │   └── MessageBubbleView.swift
│   │   │   └── ViewModels/
│   │   │       └── ConversationViewModel.swift
│   │   │
│   │   ├── HealthData/
│   │   │   ├── Views/
│   │   │   │   ├── VitalSignsView.swift
│   │   │   │   ├── MedicalHistoryView.swift
│   │   │   │   └── DevicesView.swift       # Connected device management
│   │   │   └── ViewModels/
│   │   │       └── HealthDataViewModel.swift
│   │   │
│   │   ├── Devices/
│   │   │   ├── Views/
│   │   │   │   ├── DevicePairingView.swift
│   │   │   │   └── DeviceReadingsView.swift
│   │   │   ├── ViewModels/
│   │   │   │   └── DeviceViewModel.swift
│   │   │   └── BluetoothDevices/
│   │   │       ├── BloodPressureCuff.swift
│   │   │       ├── Thermometer.swift
│   │   │       └── Glucometer.swift
│   │   │
│   │   └── Assessment/
│   │       ├── Views/
│   │       │   ├── AssessmentView.swift    # AI-generated assessment display
│   │       │   └── TreatmentPlanView.swift
│   │       └── ViewModels/
│   │           └── AssessmentViewModel.swift
│   │
│   ├── Utilities/
│   │   ├── Extensions/
│   │   │   ├── Date+Extensions.swift
│   │   │   ├── String+Extensions.swift
│   │   │   └── View+Extensions.swift
│   │   ├── Helpers/
│   │   │   ├── DateFormatters.swift
│   │   │   ├── Validators.swift            # Input validation
│   │   │   └── PrivacyHelpers.swift        # PHI handling utilities
│   │   └── Constants/
│   │       ├── AppConstants.swift
│   │       └── HealthConstants.swift
│   │
│   └── Resources/
│       ├── Assets.xcassets
│       ├── Localizable.strings             # i18n support
│       └── Info.plist
│
├── HouseCallTests/
│   ├── UnitTests/
│   │   ├── Services/
│   │   ├── ViewModels/
│   │   └── Security/                       # Critical security testing
│   └── MockData/
│       └── TestFixtures.swift
│
├── HouseCallUITests/
│   ├── AuthenticationUITests.swift
│   ├── ConversationUITests.swift
│   └── AccessibilityTests.swift            # WCAG compliance testing
│
├── openspec/                               # OpenSpec change management
│   ├── project.md                          # This file
│   ├── AGENTS.md                           # OpenSpec workflow
│   └── changes/                            # Proposed/approved changes
│
├── CLAUDE.md                               # AI assistant guidance
└── HouseCall.xcodeproj/
```

### Architecture Notes
- **MVVM Pattern**: ViewModels handle business logic, Views remain declarative
- **Repository Pattern**: Data layer abstraction for Core Data and API calls
- **Dependency Injection**: Protocol-based DI for testability and modularity
- **Feature-Based Organization**: Features grouped by functionality for scalability
- **Security-First**: Encryption, audit logging, and secure storage at every layer
