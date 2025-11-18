<!-- OPENSPEC:START -->
# OpenSpec Instructions

These instructions are for AI assistants working in this project.

Always open `@/openspec/AGENTS.md` when the request:
- Mentions planning or proposals (words like proposal, spec, change, plan)
- Introduces new capabilities, breaking changes, architecture shifts, or big performance/security work
- Sounds ambiguous and you need the authoritative spec before coding

Use `@/openspec/AGENTS.md` to learn:
- How to create and apply change proposals
- Spec format and conventions
- Project structure and guidelines

Keep this managed block so 'openspec update' can refresh the instructions.

<!-- OPENSPEC:END -->

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

HouseCall is a SwiftUI iOS application using Core Data for persistence. The project follows the standard Xcode project template structure with a simple master-detail interface for managing timestamped items.

## Build and Test Commands

### Building the App
```bash
# Build for iOS Simulator (Debug)
xcodebuild -scheme HouseCall -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15' build

# Build for iOS Simulator (Release)
xcodebuild -scheme HouseCall -configuration Release -destination 'platform=iOS Simulator,name=iPhone 15' build

# Build and run (use Xcode or iOS Simulator)
open HouseCall.xcodeproj  # Then Cmd+R in Xcode
```

### Running Tests
```bash
# Run all tests
xcodebuild test -scheme HouseCall -destination 'platform=iOS Simulator,name=iPhone 15'

# Run unit tests only (HouseCallTests target)
xcodebuild test -scheme HouseCall -only-testing:HouseCallTests -destination 'platform=iOS Simulator,name=iPhone 15'

# Run UI tests only (HouseCallUITests target)
xcodebuild test -scheme HouseCall -only-testing:HouseCallUITests -destination 'platform=iOS Simulator,name=iPhone 15'

# Run a specific test
xcodebuild test -scheme HouseCall -only-testing:HouseCallTests/HouseCallTests/example -destination 'platform=iOS Simulator,name=iPhone 15'
```

### Clean Build
```bash
xcodebuild clean -scheme HouseCall
```

## Architecture

### Core Data Stack
- **Persistence Layer**: `Persistence.swift` manages the Core Data stack with `NSPersistentContainer`
  - `PersistenceController.shared`: Production instance with SQLite backing
  - `PersistenceController.preview`: In-memory instance for SwiftUI previews with sample data
  - Model name: "HouseCall" (located in `HouseCall.xcdatamodeld`)
  - Automatic merge of changes from parent context enabled

### App Entry Point
- **HouseCallApp.swift**: SwiftUI `@main` app entry point
  - Initializes shared `PersistenceController` instance
  - Injects `managedObjectContext` into SwiftUI environment for views

### UI Layer
- **ContentView.swift**: Main view with Core Data integration
  - Uses `@FetchRequest` to fetch `Item` entities sorted by timestamp
  - Master-detail navigation pattern with `NavigationView`
  - CRUD operations: Add items (toolbar button), delete items (swipe-to-delete)
  - Environment-injected `managedObjectContext` for database operations

### Data Model
- Located in `HouseCall.xcdatamodeld/HouseCall.xcdatamodel`
- Entity: `Item` with `timestamp` attribute (Date)
- SwiftUI `@FetchRequest` uses `NSSortDescriptor` for sorting

### Testing Structure
- **HouseCallTests**: Unit tests using Swift Testing framework (not XCTest)
  - Uses `@Test` macro syntax
  - Uses `#expect(...)` for assertions
  - Imports `@testable import HouseCall` for internal access
- **HouseCallUITests**: UI testing target for end-to-end tests

## Development Notes

### Error Handling
The template contains `fatalError()` calls in Core Data error handlers that should be replaced with proper error handling before shipping:
- `ContentView.swift`: Lines 56, 71 (save errors)
- `Persistence.swift`: Lines 27, 52 (load/save errors)

### SwiftUI Previews
All views should use `PersistenceController.preview` for SwiftUI previews to avoid affecting production data.

### Core Data Context
The `managedObjectContext` is injected via SwiftUI environment and should be accessed with `@Environment(\.managedObjectContext)` in views that need database access.
