// File: Sources/RatatuiKit/Terminal.swift
// Role: Lifecycle wrapper for the CRatatuiFFI terminal: init, teardown,
//       suspend/resume for $EDITOR handoff, size query, and the crash-restore
//       call point. All entry points are render/terminal-class (UI thread only).
// Upstream: CRatatuiFFI (rffi_terminal_init, rffi_terminal_teardown,
//           rffi_terminal_suspend, rffi_terminal_resume, rffi_terminal_size,
//           rffi_emergency_restore, rffi_flush)
// Downstream: MoonSwiftTUI/App/AppDriver.swift (lifecycle),
//             CellBuffer.swift, Widgets.swift, Layout.swift (handle consumer)

import CRatatuiFFI
import Foundation

// MARK: - Thread class assertion

// All render/terminal-class functions assert they are called from the UI thread.
// In debug builds this is a hard precondition failure; in release builds the
// assertion is compiled away. The UI thread is identified by the thread that
// called `Terminal.init()` — stored at construction time.
//
// The mechanism: `Thread.current` has a stable identity per OS thread.
// Comparing by `isMainThread` covers the common single-main-thread case; for
// test contexts that spin up their own "UI" thread we compare the stored
// thread object directly.
private let renderClassLabel = "render/terminal-class"
private let inputClassLabel = "input-class"

// MARK: - TerminalSize

/// The current terminal dimensions in cell coordinates.
public struct TerminalSize: Sendable, Equatable {
    /// Number of columns (width).
    public let cols: UInt16
    /// Number of rows (height).
    public let rows: UInt16

    public init(cols: UInt16, rows: UInt16) {
        self.cols = cols
        self.rows = rows
    }
}

// MARK: - Terminal

/// Manages the CRatatuiFFI terminal session: raw mode, alternate screen,
/// cursor visibility, suspend/resume for $EDITOR handoff, and final teardown.
///
/// Thread class: render/terminal-class — every method must be called from the
/// UI thread. Debug builds assert this with `dispatchPrecondition` or an
/// explicit thread comparison (see `assertRenderClass()`).
///
/// Lifecycle:
/// 1. `Terminal.init()` — enters raw mode, alt screen, hides cursor.
/// 2. Render loop runs — `flush()` after each frame.
/// 3. On `$EDITOR` handoff: `suspend()` then `resume()` bracketing the editor.
/// 4. On exit: `teardown()` — restores the terminal and frees the handle.
///
/// On panic/crash: `Terminal.emergencyRestore()` is the async-signal-safe
/// restore primitive callable from signal handlers (ARCHITECTURE.md §3f).
/// It is exempt from the error protocol and the thread-class assertion.
public final class Terminal {

    // MARK: - Properties

    /// The opaque pointer returned by `rffi_terminal_init`.
    ///
    /// `nil` after `teardown()` has been called (or after `deinit` runs the
    /// safety-net teardown). Every render-class method that uses this pointer
    /// must guard with `precondition(handle != nil, ...)` before dereferencing,
    /// so that post-teardown calls are caught in debug builds rather than
    /// silently passing a dangling pointer to Rust.
    private var handle: UnsafeMutableRawPointer?

    /// The OS thread that constructed this Terminal — used by `assertRenderClass`.
    private let owningThread: Thread

    // MARK: - Init / Teardown

    /// Enters raw mode, switches to the alternate screen, hides the cursor,
    /// and saves the original termios for emergency restore.
    ///
    /// - Throws: `FFIError` if the shim returns NULL (init failure).
    /// - Thread class: render/terminal-class.
    public init() throws {
        // Assert using Thread.current so that test contexts that designate a
        // non-main thread as the render/UI thread do not crash.  The stored
        // owningThread is Thread.current in both cases, so the call-site check
        // and the storage are always consistent.  The common production path
        // (called from the main thread) still satisfies `isMainThread` inside
        // assertRenderClass, so no behaviour change there.
        assertRenderClass(owningThread: Thread.current)
        guard let ptr = rffi_terminal_init() else {
            throw FFIError(
                code: -1,
                message: FFIError.lastErrorMessage()
            )
        }
        self.handle = ptr
        self.owningThread = Thread.current
    }

    /// Safety-net: if `teardown()` was never called (e.g. early-throw exit
    /// path), free the Rust handle and restore the terminal here. Any I/O
    /// failure in this path is swallowed — `deinit` cannot throw.
    deinit {
        if let h = handle {
            _ = rffi_terminal_teardown(h)
        }
    }

    /// Leaves the alternate screen, shows the cursor, restores termios, and
    /// frees the terminal handle. After this call the `Terminal` is invalid;
    /// do not call any other methods.
    ///
    /// - Throws: `FFIError` on shim failure.
    /// - Thread class: render/terminal-class.
    public func teardown() throws {
        assertRenderClass(owningThread: owningThread)
        guard let h = handle else {
            preconditionFailure("Terminal.teardown() called after teardown — double teardown detected")
        }
        handle = nil
        try checkFFI(rffi_terminal_teardown(h))
    }

    // MARK: - Suspend / Resume ($EDITOR handoff)

    /// Suspends the terminal for a $EDITOR handoff: leaves the alternate screen
    /// and restores termios **without** clearing the initialized flag.
    ///
    /// The EventPump must be parked before this call (ARCHITECTURE.md §5.2
    /// pump-park handshake). Swift orchestrates the unpark after `resume()`.
    ///
    /// - Throws: `FFIError` on shim failure.
    /// - Thread class: render/terminal-class.
    public func suspend() throws {
        assertRenderClass(owningThread: owningThread)
        guard let h = handle else {
            preconditionFailure("Terminal.suspend() called after teardown")
        }
        try checkFFI(rffi_terminal_suspend(h))
    }

    /// Resumes after the editor returns: re-enters raw mode and the alternate
    /// screen. The EventPump is unparked by the caller after this returns.
    ///
    /// - Throws: `FFIError` on shim failure.
    /// - Thread class: render/terminal-class.
    public func resume() throws {
        assertRenderClass(owningThread: owningThread)
        guard let h = handle else {
            preconditionFailure("Terminal.resume() called after teardown")
        }
        try checkFFI(rffi_terminal_resume(h))
    }

    // MARK: - Frame flush

    /// Flushes the current ratatui frame (diff + write). Call once per render
    /// cycle after all widget and cell writes.
    ///
    /// - Throws: `FFIError` on shim failure.
    /// - Thread class: render/terminal-class.
    public func flush() throws {
        assertRenderClass(owningThread: owningThread)
        guard let h = handle else {
            preconditionFailure("Terminal.flush() called after teardown")
        }
        try checkFFI(rffi_flush(h))
    }

    // MARK: - Terminal size

    /// Queries the current terminal dimensions.
    ///
    /// - Returns: `TerminalSize` with the current column and row counts.
    /// - Throws: `FFIError` on shim failure.
    /// - Thread class: render/terminal-class.
    public func size() throws -> TerminalSize {
        assertRenderClass(owningThread: owningThread)
        guard handle != nil else {
            preconditionFailure("Terminal.size() called after teardown")
        }
        var cols: UInt16 = 0
        var rows: UInt16 = 0
        try checkFFI(rffi_terminal_size(&cols, &rows))
        return TerminalSize(cols: cols, rows: rows)
    }

    // MARK: - Opaque handle access

    /// The raw shim handle. Passed by `RatatuiKitBackend` (MoonSwiftTUI) to
    /// widget draw calls and `CellBuffer.flush(to:)` via `FFICellWriter`.
    /// Also used by RatatuiKit-internal callers (CellBuffer, Widgets, Layout).
    ///
    /// **Warning:** callers must not store this pointer across a `teardown()` call.
    /// After teardown the pointer is dangling; accessing it via any FFI call
    /// is undefined behaviour.  This property precondition-faults in debug builds
    /// if accessed post-teardown.
    ///
    /// **Architecture note (CR-004):** this accessor is `public` only because
    /// `MoonSwiftTUI/Render/RatatuiKitBackend.swift` (a separate module) passes
    /// the handle directly to widget `draw()` and `clearWidget()` call sites.
    /// The cross-module coupling is tracked as a follow-up architecture item
    /// (CR-004 flag): ideally RatatuiKit would expose higher-level draw methods
    /// that accept a `Terminal` parameter so the raw handle never escapes the
    /// module boundary.
    public var rawHandle: UnsafeMutableRawPointer {
        guard let h = handle else {
            preconditionFailure("Terminal.rawHandle accessed after teardown")
        }
        return h
    }

    // MARK: - Cell-buffer flush

    /// Flushes a `CellBuffer`'s accumulated cell runs to the terminal surface.
    ///
    /// Constructs an `FFICellWriter` (package-internal) and calls
    /// `buffer.flush(to:)`, issuing one FFI call per contiguous same-style run
    /// (ARCHITECTURE.md §3b). Called once per frame from `RatatuiKitBackend`.
    ///
    /// - Parameter buffer: The per-frame cell accumulator to flush and reset.
    /// - Throws: `FFIError` if any shim write call fails.
    /// - Thread class: render/terminal-class.
    public func flushCells(_ buffer: CellBuffer) throws {
        assertRenderClass(owningThread: owningThread)
        guard let h = handle else {
            preconditionFailure("Terminal.flushCells(_:) called after teardown")
        }
        let writer = FFICellWriter(handle: h)
        try buffer.flush(to: writer)
    }

    // MARK: - Emergency restore (crash path)

    /// Async-signal-safe terminal restore, callable from signal handlers.
    ///
    /// Performs a raw write of the alternate-screen-exit + cursor-show +
    /// reset sequences, then a best-effort `tcsetattr` to restore termios.
    /// This function is a **guarded no-op** until `rffi_terminal_init` has
    /// set the initialized atomic flag (ARCHITECTURE.md §3f). It is **exempt**
    /// from the error protocol and the thread-class assertion — it returns
    /// nothing and best-efforts everything. Never call from normal code paths.
    public static func emergencyRestore() {
        rffi_emergency_restore()
    }
}

// MARK: - Thread-class assertion helpers

/// Asserts that the caller is on the expected owning thread (render/terminal-class).
///
/// In debug builds this is a fatal precondition. In release builds it compiles
/// away entirely. The check uses `Thread.isMainThread` for the common case
/// where the owning thread is main, and falls back to thread-object identity
/// for test contexts that designate a non-main thread as the UI thread.
///
/// This helper is package-internal so Events.swift can call it for input-class
/// assertions using a different (pump) thread reference.
@inline(__always)
func assertRenderClass(owningThread: Thread) {
    #if DEBUG
        let current = Thread.current
        let isOwner = current === owningThread || current.isMainThread && owningThread.isMainThread
        precondition(isOwner, "[\(renderClassLabel)] called from wrong thread — must be the UI thread")
    #endif
}

/// Asserts that the caller is on the EventPump thread (input-class).
///
/// In debug builds this is a fatal precondition; release builds compile it
/// away. The pump thread is stored by `EventPump` at construction time and
/// passed here each call. `Thread.isMainThread` should be false for any
/// healthy pump thread, but we compare by identity for correctness.
@inline(__always)
func assertInputClass(pumpThread: Thread) {
    #if DEBUG
        precondition(
            Thread.current === pumpThread,
            "[\(inputClassLabel)] called from wrong thread — must be the EventPump thread"
        )
    #endif
}
