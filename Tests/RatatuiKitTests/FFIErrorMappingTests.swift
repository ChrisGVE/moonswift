// File: Tests/RatatuiKitTests/FFIErrorMappingTests.swift
// Role: Tests for FFIError status-to-thrown-error translation, covering the
//       checkFFI() helper and the lastErrorMessage() retrieval path.
//       Exercises the error protocol (ARCHITECTURE.md §5.2) without a tty.
// Upstream: RatatuiKit/FFIError.swift (FFIError, checkFFI)
// Downstream: (test target — nothing imports this)

import Testing
import CRatatuiFFI
@testable import RatatuiKit

@Suite("FFIError mapping")
struct FFIErrorMappingTests {

    @Test("checkFFI does not throw on status 0")
    func statusZeroDoesNotThrow() throws {
        try checkFFI(0)  // must not throw
    }

    @Test("checkFFI throws FFIError for negative status")
    func negativeStatusThrows() {
        #expect(throws: FFIError.self) {
            try checkFFI(-1)
        }
    }

    @Test("checkFFI throws FFIError for positive nonzero status")
    func positiveStatusThrows() {
        #expect(throws: FFIError.self) {
            try checkFFI(1)
        }
    }

    @Test("thrown FFIError carries the given code")
    func thrownErrorCode() {
        do {
            try checkFFI(-3)
            Issue.record("Expected throw")
        } catch let e as FFIError {
            #expect(e.code == -3)
        } catch {
            Issue.record("Wrong error type: \(error)")
        }
    }

    @Test("FFIError message is non-empty string (may be '(no detail)' when no error is set)")
    func errorMessageIsNonEmpty() {
        do {
            try checkFFI(-1)
        } catch let e as FFIError {
            #expect(!e.message.isEmpty)
        } catch {
            Issue.record("Wrong error type")
        }
    }

    @Test("FFIError.lastErrorMessage() returns a string (may be empty or no-detail)")
    func lastErrorMessageReturnsString() {
        // After no FFI call sets the last error, this returns "(no detail)" or empty.
        // The important invariant is that it does not crash and returns a String.
        let msg = FFIError.lastErrorMessage()
        // Just assert it is a valid (non-crashing) String.
        _ = msg.count
    }

    @Test("FFIError conforms to Error and Sendable")
    func conformances() {
        let err: Error = FFIError(code: -5, message: "test")
        #expect(err is FFIError)
        // Sendable is compile-time; test that it can cross a Sendable boundary.
        let sendable: any Error & Sendable = FFIError(code: -5, message: "test")
        _ = sendable
    }

    @Test("known error codes match shim constants")
    func knownErrorCodes() {
        // Verify these constants match what the header says, so our error
        // handling logic and documentation remain in sync.
        #expect(RFFI_TIMEOUT == 1)
        #expect(RFFI_ERR_NULL_PTR == -1)
        #expect(RFFI_ERR_PANIC == -2)
        #expect(RFFI_ERR_IO == -3)
        #expect(RFFI_ERR_NOT_INIT == -4)
        #expect(RFFI_ERR_OVERFLOW == -5)
        #expect(RFFI_ERR_INVALID_ARG == -6)
    }
}
