# Change: Fix Sign-Up View State Publishing Bug

## Why
When users click "Create Account" during sign-up, the button becomes disabled and grays out permanently due to a SwiftUI state publishing violation. The console shows three "Publishing changes from within view updates is not allowed" warnings, causing the authentication flow to freeze despite successful registration. This critical bug prevents users from completing account creation and accessing the application.

**Root Cause**: The `AuthenticationService.createSession()` method (AuthenticationService.swift:242-245) publishes `isAuthenticated = true` inside a `DispatchQueue.main.async` block while SwiftUI is still updating views from the sign-up completion. This violates SwiftUI's constraint that `@Published` properties cannot change during the view update cycle, causing undefined behavior including the permanently disabled button state.

**Evidence from Console Log**:
```
🔵 Button tapped, starting sign up
📝 Sign up started - Email: test@exsample.com, Name: John Doe, Password length: 14
🔐 Password validation - Length: 14, Strength: 5, Error: none
✅ All validations passed, attempting registration...
🔄 Calling authService.register...
✅ Registration successful!
🏁 Sign up completed
🔵 Sign up completed
Publishing changes from within view updates is not allowed, this will cause undefined behavior. (3x)
```

## What Changes
- **Fix state publishing timing in AuthenticationService**: Defer BOTH `@Published` property updates (`currentSession` and `isAuthenticated`) to the next run loop cycle using `Task { @MainActor in }`
- **Root Cause**: Even though `createSession()` is marked `@MainActor`, updating `@Published` properties synchronously within an async call chain initiated during a view update cycle violates SwiftUI's constraints
- **Maintain audit logging sequence**: Keep audit logging after state updates to preserve HIPAA compliance trail

**Technical Solution**: The original code attempted to defer only `isAuthenticated` using `DispatchQueue.main.async`, but failed to defer `currentSession`, causing 3 warnings. The correct fix is to defer BOTH `@Published` property updates together using `Task { @MainActor in }`, which ensures updates happen in the next run loop cycle, outside the current view update context.

## Impact
- **Affected specs**: authentication (user registration flow)
- **Affected code**:
  - `HouseCall/Core/Services/AuthenticationService.swift:242-245` (primary fix location)
  - `HouseCall/Features/Authentication/Views/SignUpView.swift` (indirect - benefits from fix)
  - `HouseCall/Features/Authentication/ViewModels/SignUpViewModel.swift` (indirect - benefits from fix)
- **User Impact**: Restores ability to complete account registration without UI freeze
- **Breaking Changes**: None - this is a bug fix restoring intended behavior
- **HIPAA Compliance**: Maintains audit logging requirements while fixing user-blocking bug
