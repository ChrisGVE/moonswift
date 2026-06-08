// File: Sources/MoonSwiftCore/Run/RunService.swift
// Location: MoonSwiftCore/Run/
// Role: Executes Lua scripts in fresh LuaSwift engines with captured print
//       output, instruction/wall-clock limits, and cooperative cancellation
//       (or honest degradation when LuaSwift#22 is absent). One run at a time;
//       the concurrent-run guard lives in the reducer (ARCHITECTURE §3c).
// Upstream: LuaSwift (LuaEngine, LuaError, LuaValue, LuaEngineConfiguration),
//           MoonSwiftCore (LuaSourceFragment, RunConfig, Diagnostic, Logger)
// Downstream: AppDriver (consumes CoreRunOutcome via @Sendable callbacks)
//
// ## Engine lifecycle (ARCHITECTURE §3c)
//
// Every call to `run(_:config:output:)` creates a fresh `LuaEngine`, runs the
// script, then discards the engine. Engines are never reused across runs. The
// P2 "session engine" extension will add a separate keep-alive path behind its
// own protocol boundary.
//
// ## Print capture (ARCHITECTURE §3c, hardened)
//
// LuaSwift has no output-redirection API at this pin: `print` would write to
// process stdout and corrupt the alternate screen. RunService overrides it:
//
//   1. Register `__moonswift_sink` via `registerFunction(name:callback:)`.
//   2. Run a tiny prelude (before user code) that:
//      a. Captures the sink into a wrapper's *upvalue* (unreachable after step c).
//      b. Rebinds `print` via `rawset(_G, "print", wrapper)` — the wrapper calls
//         `tostring` on each argument (respecting `__tostring` metamethods),
//         joins them with tabs, and forwards the line to the captured sink.
//      c. Removes the sink from globals via `rawset(_G, "__moonswift_sink", nil)`.
//
// After the prelude, the sink is reachable only through the wrapper's upvalue:
// user code cannot call it directly (spoofing is impossible) but can still
// reassign `print` — accepted for a developer tool.
//
// Known limitation: in `unrestricted` mode, `io.write` still reaches the real
// stdout and will visually corrupt the alternate screen until the next redraw.
// An engine-level output-redirection API is noted as a candidate LuaSwift issue.
//
// ## Cancellation (ARCHITECTURE §3c)
//
// LuaSwift#22 (requestCancellation / resetCancellation / LuaError.cancelled) is
// NOT available at the currently pinned revision (verified against
// .build/checkouts/LuaSwift/Sources/LuaSwift/LuaError.swift — no `.cancelled`
// case exists). The compile-time flag `MOONSWIFT_LUASWIFT_22` gates the two
// code paths:
//
//   #22 available   → requestCancellation() is called; the run aborts as
//                     LuaError.cancelled; outcome is CoreRunOutcome.cancelled.
//   #22 unavailable → cancel() posts a transient via the onTransient callback;
//                     the run continues to its natural end (or instruction limit).
//
// The active build path at this pin is the degradation path. The `#22 available`
// block is preserved inside #if MOONSWIFT_LUASWIFT_22 so it compiles and is
// correct when the flag is added in the version-bump task.
//
// ## Concurrent-run guard (ARCHITECTURE §3c)
//
// RunService does not enforce a single-run constraint itself: that guard lives
// entirely in the reducer, which drops new `Effect.run` events while
// `runState == .running`. This is documented here so that a future reader does
// not add a redundant lock inside RunService.

import Foundation
import LuaSwift

// MARK: - RunServiceProtocol

/// Executes a Lua script fragment and reports output lines and the final outcome.
///
/// Conforming types are `Sendable` and execute on a background executor — they
/// never touch the UI thread or the `EventChannel` directly (ARCHITECTURE §5.1).
/// The AppDriver constructs the `output` and `finish` callbacks so that their
/// bodies wrap domain payloads into `AppEvent` values and post to the channel.
///
/// The concurrent-run guard is the *reducer's* responsibility: the reducer drops
/// `Effect.run` while `runState == .running`. `RunService` does not enforce this.
public protocol RunServiceProtocol: Sendable {

    /// Execute the script fragment asynchronously.
    ///
    /// - Parameters:
    ///   - fragment: The source fragment to execute (code + provenance).
    ///   - config: Run-time configuration (engine mode, limits).
    ///   - output: Called once per captured output line. May be called from any
    ///     thread; implementations guarantee FIFO order per run.
    /// - Returns: The final outcome of the run.
    func run(
        _ fragment: LuaSourceFragment,
        config: RunConfig,
        output: @escaping @Sendable (String) -> Void
    ) async -> CoreRunOutcome

    /// Request cancellation of the current run, if any.
    ///
    /// With LuaSwift#22 this sends a cooperative cancellation signal; the run
    /// exits as `CoreRunOutcome.cancelled` within the hook's poll interval
    /// (< 200 ms target). Without #22, this posts a transient status message
    /// and the run continues to its natural end.
    ///
    /// Safe to call when no run is in progress (no-op).
    func cancel()
}

// MARK: - RunService

/// Production implementation of `RunServiceProtocol`.
///
/// Lives on a background executor (not the UI thread). The AppDriver holds the
/// single shared instance and dispatches `Effect.run` / `Effect.cancelRun` to it.
public final class RunService: RunServiceProtocol {

    // MARK: Injected dependencies

    /// Called by `cancel()` when LuaSwift#22 is absent — posts a transient
    /// status bar message. The AppDriver constructs this closure so it can post
    /// to the channel without RunService importing TUI types.
    private let onTransient: @Sendable (String) -> Void

    // MARK: State

    /// Lock-protected reference to the currently executing engine.
    ///
    /// ## Isolation invariant (CR-014)
    ///
    /// Every read and every write of `activeEngine` **must** be bracketed by
    /// `lock.lock()` / `lock.unlock()`. The three access sites are:
    ///
    ///   1. `executeSync` — write under `lock` immediately after engine creation (set).
    ///   2. `executeSync` `defer` — write under `lock` after execution finishes (clear).
    ///   3. `cancel` (MOONSWIFT_LUASWIFT_22 path) — read under `lock`, copy out,
    ///      then call `requestCancellation()` on the local copy outside the lock
    ///      to avoid holding the lock during a potentially blocking call.
    ///
    /// `nonisolated(unsafe)` is required because Swift 6 strict concurrency
    /// cannot see that `lock` serialises all accesses; `NSLock` IS the
    /// synchronisation mechanism. Any new access site added in future must
    /// likewise be bracketed by `lock`.
    private let lock = NSLock()
    nonisolated(unsafe) private var activeEngine: LuaEngine?

    // MARK: - Init

    /// Creates a `RunService`.
    ///
    /// - Parameter onTransient: Called with a human-readable message when the
    ///   user requests cancellation but LuaSwift#22 is unavailable. The closure
    ///   should post `AppEvent.transient(message)` to the event channel. Must be
    ///   `@Sendable` — it may be called from any thread.
    public init(onTransient: @Sendable @escaping (String) -> Void) {
        self.onTransient = onTransient
    }

    // MARK: - RunServiceProtocol

    public func run(
        _ fragment: LuaSourceFragment,
        config: RunConfig,
        output: @escaping @Sendable (String) -> Void
    ) async -> CoreRunOutcome {
        // All engine work runs on a background thread via a detached task.
        // `await` suspends the caller until the engine finishes or errors out.
        return await Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return CoreRunOutcome.cancelled }
            return self.executeSync(fragment: fragment, config: config, output: output)
        }.value
    }

    public func cancel() {
        #if MOONSWIFT_LUASWIFT_22
            lock.lock()
            let engine = activeEngine
            lock.unlock()
            engine?.requestCancellation()
        #else
            // Degradation path: LuaSwift#22 not yet released at this pin.
            // The run continues to its natural end. Post a transient so the user
            // knows why the `x` key appeared to do nothing.
            onTransient("Cancellation requires a newer LuaSwift — run will finish naturally")
        #endif
    }

    // MARK: - Private: synchronous engine execution

    /// Runs the engine synchronously on whatever thread the caller provides.
    ///
    /// This is the only method that touches `activeEngine` and `LuaEngine`; all
    /// setup, execution, and teardown happen here in a straight-line sequence.
    /// `config` is threaded through so limit outcomes carry the configured
    /// threshold values for ux-spec §6.3 footer formatting.
    private func executeSync(
        fragment: LuaSourceFragment,
        config: RunConfig,
        output: @escaping @Sendable (String) -> Void
    ) -> CoreRunOutcome {
        let engineConfig: LuaEngineConfiguration =
            config.config == .unrestricted ? .unrestricted : .default

        // Create a fresh engine. A failure here is catastrophic (no Lua state)
        // and is reported as a runtime diagnostic.
        let engine: LuaEngine
        do {
            engine = try LuaEngine(configuration: engineConfig)
        } catch {
            let diag = Diagnostic(
                severity: .error,
                line: 0,
                message: "Failed to create Lua engine: \(error.localizedDescription)",
                source: .runtime
            )
            return .error(diag, traceback: nil)
        }

        // Register the engine for cancel() to reach.
        lock.lock()
        activeEngine = engine
        lock.unlock()

        defer {
            // Always clear the active engine reference after the run finishes,
            // regardless of outcome. The engine is discarded (ARC) after this block.
            lock.lock()
            activeEngine = nil
            lock.unlock()
        }

        // Apply instruction limit — only when explicitly set (> 0).
        // The arming rule (ARCHITECTURE §3c): setInstructionLimit(0) disarms the
        // hook entirely, which would also disable #22 cancellation polling if it
        // were set via the same hook. For the degradation path this is harmless;
        // on the #22 path the upstream API arms its own poll hook independently.
        if config.instructionLimit > 0 {
            engine.setInstructionLimit(config.instructionLimit)
        }

        #if MOONSWIFT_LUASWIFT_22
            // Arm cancellation polling independently of the instruction limit.
            engine.resetCancellation()
        #endif

        // Install the print capture prelude.
        installPrintCapture(engine: engine, output: output)

        // Start the wall-clock timer if configured (requires #22 on the cancel path).
        var wallClockTask: Task<Void, Never>? = nil
        if config.wallClockLimitMs > 0 {
            wallClockTask = startWallClockTimer(
                limitMs: config.wallClockLimitMs,
                engine: engine
            )
        }
        defer { wallClockTask?.cancel() }

        // Execute — always `evaluate`, never `run` (ARCHITECTURE §3c run-vs-evaluate rule).
        let start = ContinuousClock.now
        let result: LuaValue
        do {
            result = try engine.evaluate(fragment.code)
        } catch let luaError as LuaError {
            return outcome(for: luaError, provenance: fragment.provenance, config: config)
        } catch {
            let diag = Diagnostic(
                severity: .error,
                line: 0,
                message: "Unexpected engine error: \(error.localizedDescription)",
                source: .runtime
            )
            return .error(diag, traceback: nil)
        }
        let duration = ContinuousClock.now - start

        // Convert the return value to a display string. `.nil` and `.nil` are
        // indistinguishable via evaluate — both render as nil return.
        let returnValue = luaValueDisplayString(result)
        return .done(value: returnValue, duration: duration)
    }

    // MARK: - Private: print capture

    /// Installs the hardened `print` override in the given engine.
    ///
    /// Steps (ARCHITECTURE §3c print-capture design):
    ///   1. Register `__moonswift_sink` (the Swift callback) as a global.
    ///   2. Run a prelude that captures the sink into an upvalue, rebinds
    ///      `print` to a wrapper that uses the upvalue, and removes the sink
    ///      from globals — so user code cannot call the sink directly.
    private func installPrintCapture(engine: LuaEngine, output: @escaping @Sendable (String) -> Void) {
        // Step 1: register the sink Swift callback.
        engine.registerFunction(name: "__moonswift_sink") { args in
            // Collect all arguments, calling tostring on each via Lua's own
            // tostring function would require engine access from inside the callback.
            // Instead, we convert each LuaValue to its display string in Swift —
            // this matches Lua's print semantics for the base types. For tables
            // with __tostring metamethods the Lua prelude wrapper handles the
            // tostring call before forwarding the already-stringified line to us.
            let line = args.map { luaValueToString($0) }.joined(separator: "\t")
            output(line)
            return .nil
        }

        // Step 2: run the prelude. The prelude:
        //   a. Captures __moonswift_sink into a local upvalue.
        //   b. Rebinds `print` via rawset so _ENV / _G metamethods cannot intercept.
        //   c. Removes __moonswift_sink from globals so user code cannot call it.
        //
        // The wrapper uses `tostring(v)` — Lua's own tostring — so that tables
        // with __tostring metamethods stringify correctly (the raw Swift converter
        // above handles the simple cases; Lua's tostring handles the meta cases).
        // We concat the results and send a single line per print call.
        //
        // // swift-format-ignore
        let prelude = """
            local __sink = __moonswift_sink
            rawset(_G, "__moonswift_sink", nil)
            rawset(_G, "print", function(...)
                local parts = {}
                local n = select("#", ...)
                for i = 1, n do
                    parts[i] = tostring(select(i, ...))
                end
                __sink(table.concat(parts, "\\t"))
            end)
            """

        // If the prelude fails (e.g. engine init error), print capture is simply
        // absent — user output goes to stdout and corrupts the screen, but that
        // is preferable to crashing. Logged at debug level; not fatal.
        do {
            try engine.run(prelude)
        } catch {
            Logger.shared.debug("RunService: print prelude failed: \(error)")
        }
    }

    // MARK: - Private: wall-clock timer

    /// Starts a background task that cancels the engine after `limitMs` ms.
    ///
    /// Returns the `Task` so the caller can cancel it when the run finishes
    /// naturally (avoiding a spurious cancel signal after a fast run).
    ///
    /// Without LuaSwift#22 this timer still fires but `requestCancellation()` is
    /// unavailable — the engine call is wrapped in `#if MOONSWIFT_LUASWIFT_22`.
    private func startWallClockTimer(limitMs: Int, engine: LuaEngine) -> Task<Void, Never> {
        Task.detached {
            try? await Task.sleep(for: .milliseconds(limitMs))
            guard !Task.isCancelled else { return }
            #if MOONSWIFT_LUASWIFT_22
                engine.requestCancellation()
            #endif
            // Without #22 there is nothing to do — the timer fires but the run
            // continues. ProjectValidation already warned about this at load time.
        }
    }

    // MARK: - Private: outcome mapping

    /// Maps a `LuaError` to a `CoreRunOutcome`.
    ///
    /// `config` is provided so limit outcomes carry the configured threshold
    /// values (`instructionLimit` / `wallClockLimitMs`) — the renderer formats
    /// these as `instruction limit exceeded (N instructions)` / `wall-clock
    /// limit exceeded (Xms)` per ux-spec §6.3.
    private func outcome(
        for luaError: LuaError,
        provenance: FragmentProvenance,
        config: RunConfig
    ) -> CoreRunOutcome {
        switch luaError {
        case .instructionLimitExceeded:
            return .limitExceeded(kind: .instructions(count: config.instructionLimit))
        #if MOONSWIFT_LUASWIFT_22
            case .cancelled:
                // Distinguish wall-clock vs instruction limit at the call site above;
                // the cancelled case is always cooperative user cancellation here.
                return .cancelled
        #endif
        default:
            let diag = Diagnostic.from(luaError: luaError, provenance: provenance)
            return .error(diag, traceback: nil)
        }
    }
}

// MARK: - Private: LuaValue display helpers (file-private)

/// Converts a `LuaValue` to a Lua-print-compatible display string.
///
/// Matches Lua 5.x `print` output for the base types. Tables with `__tostring`
/// metamethods are handled by the Lua-side prelude wrapper (tostring is called
/// in Lua before the Swift sink receives the final string).
private func luaValueToString(_ value: LuaValue) -> String {
    switch value {
    case .string(let s):
        return s
    case .number(let n):
        // Lua prints integers without a decimal point when the value is integral.
        if n == n.rounded() && !n.isInfinite && abs(n) < 1e15 {
            return String(Int64(n))
        }
        return String(n)
    case .bool(let b):
        return b ? "true" : "false"
    case .nil:
        return "nil"
    case .table:
        return "table"
    case .array:
        return "table"
    case .complex(let re, let im):
        return "\(re)+\(im)i"
    case .luaFunction:
        return "function"
    }
}

/// Converts a `LuaValue` return from `evaluate` to a display string for the
/// output tab's "return value" line.
///
/// Returns `nil` when the value is Lua nil (so the caller can display "(no value)").
private func luaValueDisplayString(_ value: LuaValue) -> String? {
    if case .nil = value { return nil }
    return luaValueToString(value)
}
