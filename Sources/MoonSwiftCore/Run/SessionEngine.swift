// File: Sources/MoonSwiftCore/Run/SessionEngine.swift
// Location: MoonSwiftCore/Run/
// Role: The long-lived session engine (PRD §F5.0 — the foundation for F5 + F6).
//       Unlike RunService (run-and-discard), SessionEngine keeps ONE LuaEngine
//       alive across a run so the user can interact with its post-run state
//       (invoke Lua functions, inspect live globals, step the debugger).
//
//       Modeled on LintService's proven pattern: a `final class` whose single
//       engine is confined to a serial executor (here QoS `.userInteractive`
//       per PERF-07), with the engine field carrying the same CR-014
//       isolation-invariant discipline. The UI thread never touches LuaEngine;
//       results flow back only via the AppDriver-injected `onOutput` callback
//       and the async returns (ARCHITECTURE §5.1).
//
// ## RunState gate (DOM-02 / PERF-02)
//
// `globalNames`/`globalValue` are between-runs-only: calling them mid-execution
// is C-level UB. SessionEngine owns an explicit `RunState { idle, running,
// paused }`, a lock-guarded atomic written on the serial executor during each
// run transition. `liveState()` / `invokeLuaCall()` gate on it: not `.idle` →
// `liveState` returns `MockLiveState.empty` and `invokeLuaCall` throws
// `.enginePaused`, NEVER reaching `globalValue`/`globalNames` mid-run. The
// atomic is read on the fast path (so the gate is observable without dispatching
// onto a busy/parked executor) and re-checked inside the queue block; all writes
// happen on the serial executor, so transitions are totally ordered.
//
// ## Command delivery (PERF-11)
//
// `sendDebugCommand` / `requestPause` / `requestGlobals` are `nonisolated`: they
// resolve `id` under the NSLock-guarded session registry and call the live
// `DebugSession` mailbox / atomics DIRECTLY — they MUST NOT hop to the serial
// executor, which is occupied by the parked `runForDebug` block during a pause.
// A stale id is a silent no-op (ARCH-06).
//
// ## F5.0 + F6.0 scope
//
// startSession installs the engine + print capture + stdlib baseline. Mock
// SERVER registration (engine.register(server:)) is the F5.1/F5.2 increment to
// startSession. F6.0 (#9) wired the debug pause hook into runForDebug via the
// new runForDebugOnQueue helper, which builds a LuaDebugHandler via
// makeDebugHookHandler (DebugHookAdapter.swift) and runs the fragment under
// engine.runDebug (full LINE/CALL/RET mask).
//
// Upstream: LuaSwift (LuaEngine, LuaError, LuaValue, LuaEngineConfiguration,
//           LuaDebugCommand), RunConfig, MockStore, LuaSourceFragment,
//           CoreRunOutcome, Diagnostic, DebugSession, DebugSnapshot, MockLiveState
// Downstream: AppDriver effect handlers (construct it with onOutput, drive it)

import Foundation
import LuaSwift

/// Production implementation of `SessionEngineProtocol`.
public final class SessionEngine: SessionEngineProtocol {

    /// The lifecycle phase of the session engine's VM.
    private enum RunState: Sendable {
        case idle
        case running
        case paused
    }

    // MARK: - Serial executor

    /// All session-engine operations run exclusively on this queue. `LuaEngine`
    /// is not thread-safe; the serial queue enforces single-threaded access.
    /// QoS `.userInteractive` (PERF-07): post-run invocation / live state are on
    /// the user's interactive path.
    private let queue: DispatchQueue

    // MARK: - Injected dependency

    /// Forwards captured `print` output. The AppDriver constructs this so it can
    /// post `AppEvent` values without SessionEngine importing TUI types.
    private let onOutput: @Sendable (String) -> Void

    // MARK: - Engine + config (guarded by `queue`)

    /// The long-lived session engine. `nil` until `startSession` completes.
    ///
    /// ## Isolation invariant (CR-014)
    ///
    /// Every read and write of `engine` MUST execute on `queue`. `nonisolated(unsafe)`
    /// is required because Swift 6 cannot see that `queue` serialises access;
    /// the queue IS the synchronisation mechanism.
    nonisolated(unsafe) private var engine: LuaEngine?
    /// The configuration the session was started with (limit formatting + mode).
    nonisolated(unsafe) private var config: RunConfig?
    /// The mock store handed to this session (installed by the F5.1/F5.2 seam).
    nonisolated(unsafe) private var mocks: MockStore = .empty
    /// Global names present after engine + mock setup, before any user code
    /// (DATA-N04). `liveState` subtracts this baseline to isolate user globals.
    nonisolated(unsafe) private var baselineStdlibNames: Set<String> = []

    // MARK: - Cancellation handle (F5.4/#44 — parity with RunService)

    /// Lock-guarded handle to the engine of the in-flight `sessionRun`, so the
    /// user `x` (`cancelRun`) and the wall-clock timer can call
    /// `requestCancellation()` from OFF the serial queue while `runOnQueue` is
    /// executing on it. Mirror of `RunService.activeEngine` (CR-014): every
    /// access is bracketed by `cancelLock`; set/cleared only in `runOnQueue`.
    /// `nonisolated(unsafe)` because `cancelLock` IS the synchronisation.
    private let cancelLock = NSLock()
    nonisolated(unsafe) private var cancellableEngine: LuaEngine?

    // MARK: - RunState atomic

    /// Guards `_runState`.
    private let stateLock = NSLock()
    nonisolated(unsafe) private var _runState: RunState = .idle

    /// Read on the gate fast path (an `async` context) and inside `queue` blocks;
    /// `withLock` is the async-safe scoped form (direct `lock()`/`unlock()` are
    /// unavailable from async contexts under Swift 6).
    private var runState: RunState {
        stateLock.withLock { _runState }
    }

    /// Writes the RunState. Called only inside `queue` blocks during a run
    /// transition, so transitions are totally ordered on the serial executor.
    private func setRunState(_ state: RunState) {
        stateLock.withLock { _runState = state }
    }

    // MARK: - Debug-session registry

    /// Guards `sessions`. The `nonisolated` command-delivery methods resolve
    /// ids here on the caller's thread; `runForDebug` inserts/removes on `queue`.
    private let registryLock = NSLock()
    nonisolated(unsafe) private var sessions: [DebugSessionID: DebugSession] = [:]

    // MARK: - Init

    /// Creates a `SessionEngine`.
    ///
    /// - Parameters:
    ///   - onOutput: Called once per captured output line; may be called from
    ///     the serial executor thread. Must be `@Sendable`.
    ///   - queueLabel: The serial executor's dispatch label (overrideable in
    ///     tests).
    public init(
        onOutput: @escaping @Sendable (String) -> Void,
        queueLabel: String = "com.moonswift.session-engine"
    ) {
        self.onOutput = onOutput
        self.queue = DispatchQueue(label: queueLabel, qos: .userInteractive)
    }

    // MARK: - SessionEngineProtocol: startSession

    public func startSession(config: RunConfig, mocks: MockStore) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SessionEngineError.notStarted)
                    return
                }
                dispatchPrecondition(condition: .onQueue(self.queue))

                // Mode inherited from the project's RunConfigMode — never
                // hardcoded (§5). Sandboxed → .default; unrestricted → .unrestricted.
                let engineConfig: LuaEngineConfiguration =
                    config.config == .unrestricted ? .unrestricted : .default
                let newEngine: LuaEngine
                do {
                    newEngine = try LuaEngine(configuration: engineConfig)
                } catch {
                    continuation.resume(
                        throwing: SessionEngineError.engineCreationFailed(error.localizedDescription)
                    )
                    return
                }

                // Instruction limit: armed once (post-init, only when > 0). The
                // long-lived engine keeps the hook for the session lifetime.
                if config.instructionLimit > 0 {
                    newEngine.setInstructionLimit(config.instructionLimit)
                }

                // Print capture: installed once on the long-lived engine, so
                // both sessionRun and invokeLuaCall route print() to onOutput.
                self.installPrintCapture(engine: newEngine)

                // F5.1: register a MockValueServer per namespace so mock globals
                // are part of the stdlib baseline (DATA-N04) and are never
                // misreported as user globals by liveState().
                for ns in mocks.namespaces {
                    let defs = mocks.values(in: ns)
                    let server = MockValueServer(namespace: ns, defs: defs, engine: newEngine)
                    newEngine.register(server: server)
                }
                // F5.2 seam: synthesized callbacks per function registered here.
                // Each MockFunctionDef materializes eagerly (fixed-return) or
                // captures a trivial closure (echo-args / raise-error) and registers
                // the result as a global Lua callable under def.name.
                for def in mocks.functions {
                    let callback = def.makeMaterializedCallback(engine: newEngine)
                    newEngine.registerFunction(name: def.name, callback: callback)
                }

                self.engine = newEngine
                self.config = config
                self.mocks = mocks
                // DATA-N04: capture the baseline AFTER engine + mock setup so
                // liveState's user-global filter excludes stdlib and mocks alike.
                self.baselineStdlibNames = Set(newEngine.globalNames(includingStandardLibrary: true))
                self.setRunState(.idle)

                continuation.resume()
            }
        }
    }

    // MARK: - SessionEngineProtocol: sessionRun

    public func sessionRun(_ fragment: LuaSourceFragment) async -> CoreRunOutcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<CoreRunOutcome, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                continuation.resume(returning: self.runOnQueue(fragment))
            }
        }
    }

    // MARK: - SessionEngineProtocol: runForDebug

    public func runForDebug(
        _ fragment: LuaSourceFragment,
        breakpoints: Set<Int>,
        onPause: @escaping @Sendable (DebugSnapshot) -> Void,
        // Defaulted on the concrete engine so tests that do not exercise the
        // resume seam (the adapter/engine suites that predate F6.2) compile
        // unchanged. The protocol requirement is NOT defaulted — production
        // callers (AppDriver+DebugEffects) must supply it explicitly (ARCH-07).
        onResumed: @escaping @Sendable () -> Void = {}
    ) async -> (DebugSessionID, CoreRunOutcome) {
        // The DebugSession (mailbox owner) is created up front so its id can be
        // returned and command delivery can address it before the VM thread starts.
        let session = DebugSession(breakpoints: breakpoints)
        registerSession(session)

        let outcome = await withCheckedContinuation { (continuation: CheckedContinuation<CoreRunOutcome, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                // baselineStdlibNames is queue-guarded (nonisolated(unsafe), written
                // only on queue in startSession/endSession). Reading here is safe.
                let baseline = self.baselineStdlibNames
                continuation.resume(
                    returning: self.runForDebugOnQueue(
                        fragment,
                        session: session,
                        baselineStdlibNames: baseline,
                        onPause: onPause,
                        onResumed: onResumed
                    )
                )
            }
        }

        // Completion ends the session: discard the DebugSession and its mailbox.
        // A later command addressed at this id is a silent no-op (ARCH-06).
        unregisterSession(session.id)
        return (session.id, outcome)
    }

    // MARK: - SessionEngineProtocol: command delivery (nonisolated)

    public func sendDebugCommand(_ id: DebugSessionID, _ command: LuaDebugCommand) {
        liveSession(id)?.deliver(command)
    }

    public func requestPause(_ id: DebugSessionID) {
        liveSession(id)?.requestPause()
    }

    public func requestGlobals(_ id: DebugSessionID) {
        liveSession(id)?.requestGlobals()
    }

    public func cancelRun() {
        // Cooperative cancellation of the in-flight `sessionRun` (user `x`).
        // Mirrors RunService.cancel: read the engine under the lock, copy out,
        // call requestCancellation OUTSIDE the lock (it may block). A run that has
        // already finished leaves `cancellableEngine` nil → silent no-op.
        #if MOONSWIFT_LUASWIFT_22
            cancelLock.lock()
            let engine = cancellableEngine
            cancelLock.unlock()
            engine?.requestCancellation()
        #endif
    }

    // MARK: - SessionEngineProtocol: invokeLuaCall

    public func invokeLuaCall(_ callExpression: String) async throws -> LuaValue {
        // Fast-path gate (DOM-02): never enter the engine mid-run.
        guard runState == .idle else { throw SessionEngineError.enginePaused }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LuaValue, Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: SessionEngineError.notStarted)
                    return
                }
                dispatchPrecondition(condition: .onQueue(self.queue))
                guard let engine = self.engine else {
                    continuation.resume(throwing: SessionEngineError.notStarted)
                    return
                }
                guard self.runState == .idle else {
                    continuation.resume(throwing: SessionEngineError.enginePaused)
                    return
                }
                self.setRunState(.running)
                defer { self.setRunState(.idle) }
                #if MOONSWIFT_LUASWIFT_22
                    engine.resetCancellation()
                #endif
                do {
                    // RQ2: evaluate the full call expression natively under the
                    // session's RunConfigMode. The lint + no-dots target checks
                    // already ran in the AppDriver (§F5.3) before this call.
                    let value = try engine.evaluate("return \(callExpression)")
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - SessionEngineProtocol: liveState

    public func liveState() async -> MockLiveState {
        // Fast-path gate (DOM-02): mid-run / paused → empty, no engine touch.
        guard runState == .idle else { return .empty }
        return await withCheckedContinuation { (continuation: CheckedContinuation<MockLiveState, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: .empty)
                    return
                }
                dispatchPrecondition(condition: .onQueue(self.queue))
                guard let engine = self.engine, self.runState == .idle else {
                    continuation.resume(returning: .empty)
                    return
                }
                continuation.resume(returning: self.buildLiveState(engine: engine))
            }
        }
    }

    // MARK: - SessionEngineProtocol: endSession

    public func endSession() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.engine = nil
                self.config = nil
                self.mocks = .empty
                self.baselineStdlibNames = []
                self.setRunState(.idle)
                continuation.resume()
            }
        }
        // Discard all live debug sessions and their mailboxes.
        registryLock.withLock { sessions.removeAll() }
    }

    // MARK: - Private: run-on-queue

    /// Runs `fragment` under the F6.0 debug hook adapter on the serial executor.
    ///
    /// Installs the debug hook via `makeDebugHookHandler`, runs under
    /// `engine.runDebug` (full LINE/CALL/RET mask), and removes the handler after
    /// the run so non-debug `sessionRun` calls carry zero overhead
    /// (`LuaEngine+Debug.swift:48` no-debug overhead guarantee).
    ///
    /// The `setRunState` closure bridges `DebugHookRunState` back to the engine's
    /// private `RunState`: `.paused` when the adapter parks, `.running` when it
    /// resumes. The `defer` sets `.idle` after `runDebug` returns.
    private func runForDebugOnQueue(
        _ fragment: LuaSourceFragment,
        session: DebugSession,
        baselineStdlibNames: Set<String>,
        onPause: @escaping @Sendable (DebugSnapshot) -> Void,
        onResumed: @escaping @Sendable () -> Void
    ) -> CoreRunOutcome {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let engine, let config else {
            let diag = Diagnostic(
                severity: .error,
                line: 0,
                message: "Session engine not started — call startSession first",
                source: .runtime
            )
            return .error(diag, traceback: nil)
        }

        let handler = makeDebugHookHandler(
            session: session,
            fragment: fragment,
            baselineStdlibNames: baselineStdlibNames,
            setRunState: { [weak self] state in
                guard let self else { return }
                switch state {
                case .paused: self.setRunState(.paused)
                case .running: self.setRunState(.running)
                }
            },
            onPause: onPause,
            onResumed: onResumed
        )
        engine.setDebugHandler(handler)
        defer {
            engine.setDebugHandler(nil)
            setRunState(.idle)
        }

        setRunState(.running)
        #if MOONSWIFT_LUASWIFT_22
            engine.resetCancellation()
        #endif

        let start = ContinuousClock.now
        let result: LuaValue
        do {
            result = try engine.runDebug(fragment.code)
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
        return .done(value: luaValueDisplayString(result), duration: duration)
    }

    /// Runs `fragment` in the session engine on the serial executor and maps the
    /// result to a `CoreRunOutcome`. Sets RunState `.running` for the body and
    /// `.idle` after. The engine survives — this is the keep-alive contract.
    private func runOnQueue(_ fragment: LuaSourceFragment) -> CoreRunOutcome {
        dispatchPrecondition(condition: .onQueue(queue))
        guard let engine, let config else {
            let diag = Diagnostic(
                severity: .error,
                line: 0,
                message: "Session engine not started — call startSession first",
                source: .runtime
            )
            return .error(diag, traceback: nil)
        }
        setRunState(.running)
        defer { setRunState(.idle) }
        #if MOONSWIFT_LUASWIFT_22
            engine.resetCancellation()
        #endif

        // Register the engine for off-queue cancellation (user `x` via cancelRun,
        // and the wall-clock timer) for the duration of this run.
        cancelLock.lock()
        cancellableEngine = engine
        cancelLock.unlock()
        defer {
            cancelLock.lock()
            cancellableEngine = nil
            cancelLock.unlock()
        }

        // Wall-clock limit parity with RunService: arm a timer that cancels the
        // engine after the limit; cancel it when the run finishes naturally.
        var wallClockTask: Task<Void, Never>? = nil
        if config.wallClockLimitMs > 0 {
            wallClockTask = startWallClockTimer(limitMs: config.wallClockLimitMs, engine: engine)
        }
        defer { wallClockTask?.cancel() }

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
        return .done(value: luaValueDisplayString(result), duration: duration)
    }

    /// Start a background task that cancels the engine after `limitMs` ms (parity
    /// with `RunService.startWallClockTimer`). Returns the `Task` so the caller
    /// cancels it when the run finishes naturally (no spurious cancel after a fast
    /// run). Without LuaSwift#22 the timer fires but `requestCancellation` is a
    /// no-op — the run continues (ProjectValidation warned at load time).
    private func startWallClockTimer(limitMs: Int, engine: LuaEngine) -> Task<Void, Never> {
        Task.detached {
            try? await Task.sleep(for: .milliseconds(limitMs))
            guard !Task.isCancelled else { return }
            #if MOONSWIFT_LUASWIFT_22
                engine.requestCancellation()
            #endif
        }
    }

    /// Maps a `LuaError` to a `CoreRunOutcome`, mirroring RunService so the
    /// renderer formats limit footers identically (ux-spec §6.3).
    private func outcome(
        for luaError: LuaError,
        provenance: FragmentProvenance,
        config: RunConfig
    ) -> CoreRunOutcome {
        switch luaError {
        case .instructionLimitExceeded:
            return .limitExceeded(kind: .instructions(count: config.instructionLimit))
        case .cancelled:
            // LuaError.cancelled exists in LuaSwift 1.12.4; produced by .stop debug
            // command or by engine.requestCancellation() (F6.0). The MOONSWIFT_LUASWIFT_22
            // gate only covers engine.resetCancellation() — catching .cancelled is ungated.
            return .cancelled
        default:
            let diag = Diagnostic.from(luaError: luaError, provenance: provenance)
            return .error(diag, traceback: nil)
        }
    }

    // MARK: - Private: live-state introspection (between-runs only)

    /// Builds a `MockLiveState` from #21 introspection. Caller guarantees
    /// RunState == .idle, so `globalNames`/`globalValue` are safe.
    private func buildLiveState(engine: LuaEngine) -> MockLiveState {
        dispatchPrecondition(condition: .onQueue(queue))

        // Mock functions: registered callback names, internal sink excluded.
        let mockFunctionNames = engine.registeredFunctionNames
            .filter { !$0.hasPrefix("__moonswift_") }
            .sorted()

        // Mock values: one entry per registered value-server namespace. Per-path
        // expansion is refined by F5.4; F5.0 reports namespace-level presence.
        let mockValues = engine.registeredValueServerNames.sorted().map { name in
            MockLiveValue(name: name, displayValue: render(engine.globalValue(name)))
        }

        // User globals: all current globals minus the post-setup baseline
        // (DATA-N04) and the internal sink.
        let userNames = Set(engine.globalNames(includingStandardLibrary: true))
            .subtracting(baselineStdlibNames)
            .filter { !$0.hasPrefix("__moonswift_") }
            .sorted()
        let userGlobals = userNames.map { name in
            MockLiveValue(name: name, displayValue: render(engine.globalValue(name)))
        }

        return MockLiveState(
            mockValues: mockValues,
            mockFunctionNames: mockFunctionNames,
            userGlobals: userGlobals,
            isEmpty: false
        )
    }

    // MARK: - Private: debug-session registry helpers

    private func registerSession(_ session: DebugSession) {
        registryLock.withLock { sessions[session.id] = session }
    }

    private func unregisterSession(_ id: DebugSessionID) {
        registryLock.withLock { _ = sessions.removeValue(forKey: id) }
    }

    /// Resolves `id` to a live `DebugSession`, or `nil` if torn down (ARCH-06).
    private func liveSession(_ id: DebugSessionID) -> DebugSession? {
        registryLock.withLock { sessions[id] }
    }

    // MARK: - Private: print capture (mirrors RunService §3c)

    /// Installs the hardened `print` override on the long-lived engine.
    ///
    /// Same mechanism as `RunService.installPrintCapture`: register the sink,
    /// run a prelude that captures it into an upvalue, rebind `print` to a
    /// wrapper, and remove the sink from globals so user code cannot call it.
    private func installPrintCapture(engine: LuaEngine) {
        let sink = onOutput
        engine.registerFunction(name: "__moonswift_sink") { args in
            let line = args.map { luaValueToString($0) }.joined(separator: "\t")
            sink(line)
            return .nil
        }
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
        do {
            try engine.run(prelude)
        } catch {
            Logger.shared.debug("SessionEngine: print prelude failed: \(error)")
        }
    }
}

// MARK: - Private: LuaValue rendering (file-private)

/// Renders an introspected `LuaValue` to a `Sendable` display string for
/// `MockLiveValue`. Scalars render literally; compound values render their type
/// name (function-typed → `function`, DATA-N07). Deep table expansion / the
/// `(…)` depth-cap sentinel is the inspector's concern (F5.4 refinement).
private func render(_ value: LuaValue?) -> String {
    guard let value else { return "nil" }
    return luaValueToString(value)
}

/// Converts a `LuaValue` to a Lua-print-compatible display string. Delegates to
/// the shared public ``renderLuaValue(_:)`` (Run/LuaValueDisplay.swift) so the
/// engine and the TUI invoke path share ONE renderer.
private func luaValueToString(_ value: LuaValue) -> String {
    renderLuaValue(value)
}

/// Converts an `evaluate` return value to a display string, `nil` for Lua nil.
/// Delegates to the shared public ``luaValueDisplayOrNil(_:)``.
private func luaValueDisplayString(_ value: LuaValue) -> String? {
    luaValueDisplayOrNil(value)
}
