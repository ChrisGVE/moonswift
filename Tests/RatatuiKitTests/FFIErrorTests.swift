// File: Tests/RatatuiKitTests/FFIErrorTests.swift
// Role: Smoke tests for FFIError — verifies that a nonzero status code
//       constructs a valid FFIError with the expected fields. The actual
//       CRatatuiFFI symbols are present (stub bodies) so the link succeeds
//       in source mode without a real Rust artifact.
// Upstream: RatatuiKit/FFIError.swift
// Downstream: (test target — nothing imports this)

import Testing

@testable import RatatuiKit

@Suite("FFIError")
struct FFIErrorTests {

    @Test("FFIError stores the given code")
    func storesCode() {
        let err = FFIError(code: -1, message: "test error")
        #expect(err.code == -1)
    }

    @Test("FFIError stores the given message")
    func storesMessage() {
        let err = FFIError(code: 42, message: "terminal init failed")
        #expect(err.message == "terminal init failed")
    }

    @Test("FFIError conforms to Error")
    func conformsToError() {
        let err: Error = FFIError(code: 1, message: "test")
        #expect(err is FFIError)
    }
}
