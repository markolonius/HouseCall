//
//  Validators.swift
//  HouseCall
//
//  Input validation for authentication forms
//  HIPAA-compliant password and passcode validation
//

import Foundation

/// Validation result with specific error messaging
struct ValidationResult {
    let isValid: Bool
    let errorMessage: String?

    static func valid() -> ValidationResult {
        return ValidationResult(isValid: true, errorMessage: nil)
    }

    static func invalid(_ message: String) -> ValidationResult {
        return ValidationResult(isValid: false, errorMessage: message)
    }
}

/// Input validators for authentication
class Validators {

    // MARK: - Email Validation

    /// Validates email address format using RFC 5322 pattern
    /// - Parameter email: Email address to validate
    /// - Returns: ValidationResult
    static func validateEmail(_ email: String) -> ValidationResult {
        let trimmedEmail = email.trimmingCharacters(in: .whitespaces)

        // Check for empty email
        guard !trimmedEmail.isEmpty else {
            return .invalid("Email address is required")
        }

        // Use NSDataDetector for robust email validation
        let dataDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(trimmedEmail.startIndex..<trimmedEmail.endIndex, in: trimmedEmail)

        guard let matches = dataDetector?.matches(in: trimmedEmail, options: [], range: range),
              matches.count == 1,
              let match = matches.first,
              match.url?.scheme == "mailto",
              match.range == range else {
            return .invalid("Please enter a valid email address")
        }

        // Additional check for common email format
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format: "SELF MATCHES %@", emailRegex)

        guard emailPredicate.evaluate(with: trimmedEmail) else {
            return .invalid("Please enter a valid email address")
        }

        return .valid()
    }

    // MARK: - Password Validation

    /// Validates password strength according to healthcare security standards
    /// Requirements:
    /// - Minimum 12 characters
    /// - At least one uppercase letter
    /// - At least one lowercase letter
    /// - At least one number
    /// - At least one special character
    /// - Parameter password: Password to validate
    /// - Returns: ValidationResult
    static func validatePassword(_ password: String) -> ValidationResult {
        // Check minimum length
        guard password.count >= 12 else {
            return .invalid("Password must be at least 12 characters long")
        }

        // Check for uppercase letter
        let uppercaseRegex = ".*[A-Z]+.*"
        let uppercasePredicate = NSPredicate(format: "SELF MATCHES %@", uppercaseRegex)
        guard uppercasePredicate.evaluate(with: password) else {
            return .invalid("Password must contain at least one uppercase letter")
        }

        // Check for lowercase letter
        let lowercaseRegex = ".*[a-z]+.*"
        let lowercasePredicate = NSPredicate(format: "SELF MATCHES %@", lowercaseRegex)
        guard lowercasePredicate.evaluate(with: password) else {
            return .invalid("Password must contain at least one lowercase letter")
        }

        // Check for number
        let numberRegex = ".*[0-9]+.*"
        let numberPredicate = NSPredicate(format: "SELF MATCHES %@", numberRegex)
        guard numberPredicate.evaluate(with: password) else {
            return .invalid("Password must contain at least one number")
        }

        // Check for special character
        let specialCharRegex = ".*[!@#$%^&*()_+\\-=\\[\\]{}|;:,.<>?]+.*"
        let specialCharPredicate = NSPredicate(format: "SELF MATCHES %@", specialCharRegex)
        guard specialCharPredicate.evaluate(with: password) else {
            return .invalid("Password must contain at least one special character (!@#$%^&*()_+-=[]{}|;:,.<>?)")
        }

        return .valid()
    }

    /// Validates that password and confirmation match
    /// - Parameters:
    ///   - password: Original password
    ///   - confirmation: Password confirmation
    /// - Returns: ValidationResult
    static func validatePasswordConfirmation(password: String, confirmation: String) -> ValidationResult {
        guard password == confirmation else {
            return .invalid("Passwords do not match")
        }

        return .valid()
    }

    // MARK: - Passcode Validation

    /// Validates 6-digit passcode
    /// Requirements:
    /// - Exactly 6 numeric digits
    /// - No sequential patterns (123456, 654321)
    /// - No repeated digits (111111, 000000)
    /// - Parameter passcode: Passcode to validate
    /// - Returns: ValidationResult
    static func validatePasscode(_ passcode: String) -> ValidationResult {
        // Check if exactly 6 digits
        guard passcode.count == 6 else {
            return .invalid("Passcode must be exactly 6 digits")
        }

        // Check if all characters are numeric
        guard passcode.allSatisfy({ $0.isNumber }) else {
            return .invalid("Passcode must contain only numbers")
        }

        // Check for repeated digits
        let uniqueDigits = Set(passcode)
        if uniqueDigits.count == 1 {
            return .invalid("Passcode cannot contain all the same digit (e.g., 111111)")
        }

        // Check for sequential patterns (ascending)
        if isSequential(passcode, ascending: true) {
            return .invalid("Passcode cannot be a sequential pattern (e.g., 123456)")
        }

        // Check for sequential patterns (descending)
        if isSequential(passcode, ascending: false) {
            return .invalid("Passcode cannot be a sequential pattern (e.g., 654321)")
        }

        return .valid()
    }

    /// Validates that passcode and confirmation match
    /// - Parameters:
    ///   - passcode: Original passcode
    ///   - confirmation: Passcode confirmation
    /// - Returns: ValidationResult
    static func validatePasscodeConfirmation(passcode: String, confirmation: String) -> ValidationResult {
        guard passcode == confirmation else {
            return .invalid("Passcodes do not match")
        }

        return .valid()
    }

    // MARK: - Helper Methods

    /// Checks if a string of digits is sequential
    /// - Parameters:
    ///   - digits: String of digits to check
    ///   - ascending: true for ascending sequence (123), false for descending (321)
    /// - Returns: true if sequential, false otherwise
    private static func isSequential(_ digits: String, ascending: Bool) -> Bool {
        guard digits.count >= 2 else { return false }

        let digitsArray = Array(digits)
        let expectedDifference = ascending ? 1 : -1

        for i in 0..<digitsArray.count - 1 {
            guard let currentDigit = Int(String(digitsArray[i])),
                  let nextDigit = Int(String(digitsArray[i + 1])) else {
                return false
            }

            // Handle wrap-around (9 -> 0 or 0 -> 9)
            let difference = (nextDigit - currentDigit + 10) % 10

            if difference != expectedDifference && difference != expectedDifference + 10 {
                return false
            }
        }

        return true
    }

    // MARK: - Full Name Validation

    /// Validates full name format
    /// - Parameter fullName: Full name to validate
    /// - Returns: ValidationResult
    static func validateFullName(_ fullName: String) -> ValidationResult {
        let trimmedName = fullName.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            return .invalid("Full name is required")
        }

        guard trimmedName.count >= 2 else {
            return .invalid("Please enter your full name")
        }

        // Check for at least one space (first and last name)
        guard trimmedName.contains(" ") else {
            return .invalid("Please enter your first and last name")
        }

        return .valid()
    }

    // MARK: - Password Strength Assessment

    /// Assesses password strength and returns a score
    /// - Parameter password: Password to assess
    /// - Returns: Strength score from 0 (very weak) to 5 (very strong)
    static func assessPasswordStrength(_ password: String) -> Int {
        var score = 0

        // Length score
        if password.count >= 12 { score += 1 }
        if password.count >= 16 { score += 1 }

        // Character diversity
        if password.range(of: "[A-Z]", options: .regularExpression) != nil { score += 1 }
        if password.range(of: "[a-z]", options: .regularExpression) != nil { score += 1 }
        if password.range(of: "[0-9]", options: .regularExpression) != nil { score += 1 }
        if password.range(of: "[!@#$%^&*()_+\\-=\\[\\]{}|;:,.<>?]", options: .regularExpression) != nil { score += 1 }

        return min(score, 5)
    }

    /// Gets a user-friendly description of password strength
    /// - Parameter score: Strength score (0-5)
    /// - Returns: Strength description
    static func passwordStrengthDescription(for score: Int) -> String {
        switch score {
        case 0...1: return "Very Weak"
        case 2: return "Weak"
        case 3: return "Fair"
        case 4: return "Strong"
        case 5: return "Very Strong"
        default: return "Unknown"
        }
    }
}
