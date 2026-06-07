// File: Sources/RatatuiKit/FFIError.swift
// Role: Translates nonzero CRatatuiFFI status codes into thrown Swift errors,
//       retrieving the thread-local last-error string for the diagnostic
//       message. Every RatatuiKit call that returns a status code passes
//       through this translation layer.
// Upstream: CRatatuiFFI (rffi_last_error, all entry-point return values)
// Downstream: Terminal.swift, Events.swift, Widgets.swift, CellBuffer.swift

import CRatatuiFFI

/// An error thrown when a CRatatuiFFI entry point returns a nonzero status.
///
/// `code` is the raw i32 status returned by the shim. `message` is the
/// thread-local last-error string retrieved immediately after the failure;
/// it is the best available human-readable description of the fault.
public struct FFIError: Error, Sendable {
    /// The nonzero status code returned by the shim entry point.
    public let code: Int32
    /// The thread-local last-error string, retrieved immediately after failure.
    public let message: String

    public init(code: Int32, message: String) {
        self.code = code
        self.message = message
    }

    /// Reads the current thread-local last-error string from the shim.
    public static func lastErrorMessage() -> String {
        // 512 bytes is ample for shim error strings; the shim NUL-terminates.
        var buffer = [UInt8](repeating: 0, count: 512)
        let written = buffer.withUnsafeMutableBufferPointer { ptr in
            rffi_last_error(
                ptr.baseAddress.map { UnsafeMutablePointer<CChar>(OpaquePointer($0)) },
                512
            )
        }
        guard written > 0 else { return "(no detail)" }
        // Trim to the written byte count (excluding NUL) and decode as UTF-8.
        let content = buffer.prefix(Int(written))
        return String(decoding: content, as: UTF8.self)
    }
}

/// Evaluates `status`, throwing `FFIError` when it is nonzero.
///
/// Call this after every CRatatuiFFI entry point that returns `int32_t`.
/// Example:
/// ```swift
/// try checkFFI(rffi_terminal_init())
/// ```
func checkFFI(_ status: Int32) throws {
    guard status == 0 else {
        throw FFIError(code: status, message: FFIError.lastErrorMessage())
    }
}
