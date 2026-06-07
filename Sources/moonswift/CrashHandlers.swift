// File: Sources/moonswift/CrashHandlers.swift
// Location: Sources/moonswift/
// Role: Fatal-signal handlers that restore the terminal before the process
//       dies. Installed before terminal init so they are always active, but
//       rffi_emergency_restore is a guarded no-op until the shim's INITIALIZED
//       atomic is set (ARCHITECTURE.md §3f). The handlers are @convention(c)
//       thin functions — the only code permitted in a POSIX signal handler.
// Upstream: RatatuiKit/Terminal.swift (Terminal.emergencyRestore),
//           Darwin (signal, raise)
// Downstream: (process — called by the OS on fatal signals)
//
// Signal set (ARCHITECTURE.md §3f):
//   SIGSEGV  — null/invalid dereference
//   SIGBUS   — misaligned or mapped-memory fault
//   SIGILL   — illegal instruction (corrupt code, stack smash)
//   SIGABRT  — Swift fatalError, assert, precondition (via abort())
//   SIGTRAP  — Swift precondition / fatalError on arm64 (BRKMN instruction)
//   SIGFPE   — arithmetic fault (division by zero, integer overflow trap)
//   SIGTERM  — polite process termination (launchd, kill default)
//   SIGHUP   — hangup (controlling terminal closed)
//
// NOT handled: SIGTSTP/SIGCONT (pump EINTR retry covers those), SIGINT
// (default Ctrl-C kills the process; users who want graceful quit press q).

import Darwin
import RatatuiKit

// MARK: - Handler body

/// The body shared by every crash handler.
///
/// This function is `@convention(c)` so it can be registered with `signal(2)`.
/// It must perform only async-signal-safe operations:
/// 1. Call `rffi_emergency_restore()` via `Terminal.emergencyRestore()`.
///    The RatatuiKit wrapper calls `rffi_emergency_restore` directly — a
///    guarded no-op that writes escape sequences + best-efforts `tcsetattr`.
/// 2. Reset the signal disposition to `SIG_DFL` so the re-raise produces the
///    correct exit status (signal-terminated, not caught).
/// 3. Re-raise the signal so the process dies with the authentic signal status.
///
/// `RatatuiKit.Terminal.emergencyRestore()` is a Swift wrapper around the C
/// function `rffi_emergency_restore()`. `rffi_emergency_restore` is documented
/// as exempt from the error protocol (no TLS, no locks, no allocation) and is
/// async-signal-safe with a best-effort tcsetattr caveat (ARCHITECTURE.md §3f).
private let crashHandlerBody: @convention(c) (Int32) -> Void = { sig in
    Terminal.emergencyRestore()
    signal(sig, SIG_DFL)
    raise(sig)
}

// MARK: - Installation

/// Install the crash-restore signal handlers.
///
/// Each handler calls `rffi_emergency_restore()` (a guarded no-op until the
/// shim is initialised), resets the disposition to `SIG_DFL`, and re-raises
/// the signal so the process exits with the correct signal status.
///
/// Call this **before** terminal initialisation so there is no window in which
/// a crash would leave the terminal in raw/alternate-screen mode with no
/// handler installed. The guarded-no-op design in the shim makes this ordering
/// safe: a signal before `rffi_terminal_init` simply calls a cheap no-op and
/// the terminal is unaffected (it was never set to raw mode yet).
///
/// Thread safety: `signal(2)` modifies process-wide dispositions; call only
/// from the main thread, once, before any background threads start.
func installCrashHandlers() {
    let signals: [Int32] = [
        SIGSEGV,
        SIGBUS,
        SIGILL,
        SIGABRT,
        SIGTRAP,
        SIGFPE,
        SIGTERM,
        SIGHUP,
    ]
    for sig in signals {
        signal(sig, crashHandlerBody)
    }
}
