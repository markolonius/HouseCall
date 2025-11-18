//
//  ValidatorsTests.swift
//  HouseCallTests
//
//  Unit tests for input validation
//

import Testing
@testable import HouseCall

@Suite("Validators Tests")
struct ValidatorsTests {

    // MARK: - Email Validation Tests

    @Test("Valid email formats accepted")
    func testValidEmails() {
        let validEmails = [
            "user@example.com",
            "test.user@example.com",
            "test+tag@example.co.uk",
            "user123@test-domain.com",
            "first.last@subdomain.example.com",
            "email@123.123.123.123",
            "a@b.co"
        ]

        for email in validEmails {
            let result = Validators.validateEmail(email)
            #expect(result.isValid == true, "Email should be valid: \(email)")
        }
    }

    @Test("Invalid email formats rejected")
    func testInvalidEmails() {
        let invalidEmails = [
            "notanemail",
            "@example.com",
            "user@",
            "user @example.com",
            "user@.com",
            "user..name@example.com",
            ".user@example.com",
            "user@example",
            ""
        ]

        for email in invalidEmails {
            let result = Validators.validateEmail(email)
            #expect(result.isValid == false, "Email should be invalid: \(email)")
        }
    }

    @Test("Empty email rejected")
    func testEmptyEmail() {
        let result = Validators.validateEmail("")
        #expect(result.isValid == false)
        #expect(result.errorMessage == "Email address is required")
    }

    @Test("Email with whitespace trimmed")
    func testEmailWithWhitespace() {
        let result = Validators.validateEmail("  user@example.com  ")
        #expect(result.isValid == true)
    }

    // MARK: - Password Validation Tests

    @Test("Valid password accepted")
    func testValidPassword() {
        let validPasswords = [
            "SecurePass123!",
            "MyP@ssw0rd2024",
            "VeryL0ng&SecurePassword!",
            "Abc123!@#$%^"
        ]

        for password in validPasswords {
            let result = Validators.validatePassword(password)
            #expect(result.isValid == true, "Password should be valid: \(password)")
        }
    }

    @Test("Short password rejected (< 12 chars)")
    func testShortPassword() {
        let result = Validators.validatePassword("Short1!")
        #expect(result.isValid == false)
        #expect(result.errorMessage?.contains("12 characters") == true)
    }

    @Test("Password missing uppercase rejected")
    func testPasswordMissingUppercase() {
        let result = Validators.validatePassword("lowercase123!")
        #expect(result.isValid == false)
        #expect(result.errorMessage?.contains("uppercase") == true)
    }

    @Test("Password missing lowercase rejected")
    func testPasswordMissingLowercase() {
        let result = Validators.validatePassword("UPPERCASE123!")
        #expect(result.isValid == false)
        #expect(result.errorMessage?.contains("lowercase") == true)
    }

    @Test("Password missing number rejected")
    func testPasswordMissingNumber() {
        let result = Validators.validatePassword("NoNumbersHere!")
        #expect(result.isValid == false)
        #expect(result.errorMessage?.contains("number") == true)
    }

    @Test("Password missing special char rejected")
    func testPasswordMissingSpecialChar() {
        let result = Validators.validatePassword("NoSpecialChar1")
        #expect(result.isValid == false)
        #expect(result.errorMessage?.contains("special character") == true)
    }

    @Test("Password with all requirements passes")
    func testPasswordWithAllRequirements() {
        let result = Validators.validatePassword("ValidP@ssw0rd")
        #expect(result.isValid == true)
    }

    // MARK: - Password Confirmation Tests

    @Test("Matching passwords pass confirmation")
    func testMatchingPasswords() {
        let password = "SecurePass123!"
        let confirmation = "SecurePass123!"

        let result = Validators.validatePasswordConfirmation(
            password: password,
            confirmation: confirmation
        )
        #expect(result.isValid == true)
    }

    @Test("Non-matching passwords fail confirmation")
    func testNonMatchingPasswords() {
        let password = "SecurePass123!"
        let confirmation = "DifferentPass456!"

        let result = Validators.validatePasswordConfirmation(
            password: password,
            confirmation: confirmation
        )
        #expect(result.isValid == false)
        #expect(result.errorMessage == "Passwords do not match")
    }

    // MARK: - Passcode Validation Tests

    @Test("Valid 6-digit passcode accepted")
    func testValidPasscode() {
        let validPasscodes = [
            "123789",
            "987654",
            "135792",
            "246801"
        ]

        for passcode in validPasscodes {
            let result = Validators.validatePasscode(passcode)
            #expect(result.isValid == true, "Passcode should be valid: \(passcode)")
        }
    }

    @Test("Non-6-digit passcode rejected")
    func testInvalidPasscodeLength() {
        let invalidPasscodes = [
            "12345",    // Too short
            "1234567",  // Too long
            "123",
            ""
        ]

        for passcode in invalidPasscodes {
            let result = Validators.validatePasscode(passcode)
            #expect(result.isValid == false, "Passcode should be invalid: \(passcode)")
            #expect(result.errorMessage?.contains("6 digits") == true)
        }
    }

    @Test("Passcode with letters rejected")
    func testPasscodeWithLetters() {
        let result = Validators.validatePasscode("12A456")
        #expect(result.isValid == false)
        #expect(result.errorMessage?.contains("numbers") == true)
    }

    @Test("Sequential ascending passcode rejected")
    func testSequentialAscendingPasscode() {
        let sequentialPasscodes = [
            "123456",
            "234567",
            "012345",
            "456789"
        ]

        for passcode in sequentialPasscodes {
            let result = Validators.validatePasscode(passcode)
            #expect(result.isValid == false, "Sequential passcode should be rejected: \(passcode)")
            #expect(result.errorMessage?.contains("sequential") == true)
        }
    }

    @Test("Sequential descending passcode rejected")
    func testSequentialDescendingPasscode() {
        let sequentialPasscodes = [
            "654321",
            "987654",
            "543210"
        ]

        for passcode in sequentialPasscodes {
            let result = Validators.validatePasscode(passcode)
            #expect(result.isValid == false, "Descending sequential passcode should be rejected: \(passcode)")
            #expect(result.errorMessage?.contains("sequential") == true)
        }
    }

    @Test("Repeated digits passcode rejected")
    func testRepeatedDigitsPasscode() {
        let repeatedPasscodes = [
            "111111",
            "222222",
            "000000",
            "999999"
        ]

        for passcode in repeatedPasscodes {
            let result = Validators.validatePasscode(passcode)
            #expect(result.isValid == false, "Repeated passcode should be rejected: \(passcode)")
            #expect(result.errorMessage?.contains("same digit") == true)
        }
    }

    @Test("Passcode with special characters rejected")
    func testPasscodeWithSpecialChars() {
        let result = Validators.validatePasscode("123!56")
        #expect(result.isValid == false)
        #expect(result.errorMessage?.contains("numbers") == true)
    }

    // MARK: - Passcode Confirmation Tests

    @Test("Matching passcodes pass confirmation")
    func testMatchingPasscodes() {
        let passcode = "135792"
        let confirmation = "135792"

        let result = Validators.validatePasscodeConfirmation(
            passcode: passcode,
            confirmation: confirmation
        )
        #expect(result.isValid == true)
    }

    @Test("Non-matching passcodes fail confirmation")
    func testNonMatchingPasscodes() {
        let passcode = "135792"
        let confirmation = "246801"

        let result = Validators.validatePasscodeConfirmation(
            passcode: passcode,
            confirmation: confirmation
        )
        #expect(result.isValid == false)
        #expect(result.errorMessage == "Passcodes do not match")
    }

    // MARK: - Full Name Validation Tests

    @Test("Valid full name accepted")
    func testValidFullName() {
        let validNames = [
            "John Doe",
            "Mary Jane Smith",
            "José García",
            "李 明",
            "O'Brien McDonald"
        ]

        for name in validNames {
            let result = Validators.validateFullName(name)
            #expect(result.isValid == true, "Name should be valid: \(name)")
        }
    }

    @Test("Single name rejected")
    func testSingleName() {
        let result = Validators.validateFullName("John")
        #expect(result.isValid == false)
        #expect(result.errorMessage?.contains("first and last") == true)
    }

    @Test("Empty full name rejected")
    func testEmptyFullName() {
        let result = Validators.validateFullName("")
        #expect(result.isValid == false)
        #expect(result.errorMessage == "Full name is required")
    }

    @Test("Name with only whitespace rejected")
    func testWhitespaceOnlyName() {
        let result = Validators.validateFullName("   ")
        #expect(result.isValid == false)
    }

    @Test("Very short name rejected")
    func testVeryShortName() {
        let result = Validators.validateFullName("A")
        #expect(result.isValid == false)
    }

    // MARK: - Password Strength Assessment Tests

    @Test("Password strength assessment (0-5 scale)")
    func testPasswordStrengthScores() {
        let testCases: [(password: String, expectedMin: Int, expectedMax: Int)] = [
            ("weak", 0, 1),              // Very weak
            ("Weak123!", 3, 4),          // Fair/Strong
            ("VeryStr0ng!Pass", 4, 5),   // Strong/Very Strong
            ("Sup3rL0ng&C0mpl3xP@ssw0rd!", 5, 5) // Very Strong
        ]

        for testCase in testCases {
            let score = Validators.assessPasswordStrength(testCase.password)
            #expect(score >= testCase.expectedMin, "Password '\(testCase.password)' score \(score) should be >= \(testCase.expectedMin)")
            #expect(score <= testCase.expectedMax, "Password '\(testCase.password)' score \(score) should be <= \(testCase.expectedMax)")
        }
    }

    @Test("Password strength increases with length")
    func testPasswordStrengthWithLength() {
        let short = "Abc123!"
        let medium = "Abc123!@#$%^"
        let long = "Abc123!@#$%^&*()ABC"

        let scoreShort = Validators.assessPasswordStrength(short)
        let scoreMedium = Validators.assessPasswordStrength(medium)
        let scoreLong = Validators.assessPasswordStrength(long)

        #expect(scoreMedium >= scoreShort)
        #expect(scoreLong >= scoreMedium)
    }

    @Test("Password strength descriptions")
    func testPasswordStrengthDescriptions() {
        #expect(Validators.passwordStrengthDescription(for: 0) == "Very Weak")
        #expect(Validators.passwordStrengthDescription(for: 1) == "Very Weak")
        #expect(Validators.passwordStrengthDescription(for: 2) == "Weak")
        #expect(Validators.passwordStrengthDescription(for: 3) == "Fair")
        #expect(Validators.passwordStrengthDescription(for: 4) == "Strong")
        #expect(Validators.passwordStrengthDescription(for: 5) == "Very Strong")
    }

    // MARK: - Edge Cases

    @Test("Unicode characters in password")
    func testUnicodePassword() {
        let password = "Pässw0rd!你好"
        let result = Validators.validatePassword(password)
        // Should pass if it meets all requirements
        #expect(result.isValid == true)
    }

    @Test("Maximum length password")
    func testMaxLengthPassword() {
        let longPassword = String(repeating: "a", count: 1000) + "A1!"
        let result = Validators.validatePassword(longPassword)
        #expect(result.isValid == true)
    }

    @Test("All special characters in password")
    func testAllSpecialCharactersPassword() {
        let password = "!@#$%^&*()_+-=[]{}|;:,.<>?Aa1"
        let result = Validators.validatePassword(password)
        #expect(result.isValid == true)
    }

    @Test("Passcode with mixed patterns accepted")
    func testMixedPatternPasscode() {
        // Not sequential, not repeated
        let result = Validators.validatePasscode("135792")
        #expect(result.isValid == true)
    }

    @Test("Email case insensitivity")
    func testEmailCaseInsensitivity() {
        let lowerCase = Validators.validateEmail("user@example.com")
        let upperCase = Validators.validateEmail("USER@EXAMPLE.COM")
        let mixedCase = Validators.validateEmail("UsEr@ExAmPlE.CoM")

        #expect(lowerCase.isValid == true)
        #expect(upperCase.isValid == true)
        #expect(mixedCase.isValid == true)
    }
}
