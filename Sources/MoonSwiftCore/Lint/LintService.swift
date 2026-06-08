// File: Sources/MoonSwiftCore/Lint/LintService.swift
// Location: MoonSwiftCore/Lint/
// Role: Production LintService — syntax pre-pass via compile (result discarded),
//       full luacheck pass in a long-lived unrestricted engine, pre-warming with
//       the one-shot luaswift.toml catalog probe.
//
//       Architecture (ARCHITECTURE.md §3d, §2 LintService row):
//         - syntaxPrePass(_:) — synchronous, no engine, fast path on every
//           source load: uses a throw-away engine to compile the code and
//           discard the bytecode; maps LuaError.syntaxError → Diagnostic.
//         - lint(_:knownGlobals:) — async, uses the long-lived lint engine
//           (serial executor) to call luacheck.check_strings; maps the
//           structured report to [Diagnostic].
//         - prewarm(onReady:onCatalogProbed:onFailed:) — creates the lint engine off the
//           main thread, loads luacheck, runs the one-shot toml catalog probe,
//           then calls the provided callbacks.
//
//       The lint engine is confined to a serial DispatchQueue (LuaEngine is
//       single-threaded). It runs unrestricted because the preload shim uses
//       load() (stripped by the sandbox) and only trusted vendored code runs
//       in the engine — user code enters solely as a string argument.
//
// Upstream: LuaSwift (LuaEngine, LuaError, LuaValue, LuaEngineConfiguration),
//           LuacheckLoader (preload shim), LuaModuleCatalog (globals shape),
//           LuaErrorDiagnostics (Diagnostic.from), FragmentProvenance
// Downstream: AppDriver (calls the three entry points via Effect handlers)

import Foundation
import LuaSwift

// MARK: - LintServiceProtocol

/// Protocol for the lint service — syntax pre-pass and full luacheck pass.
///
/// Conforming types are `Sendable` and run off the main thread (the lint engine
/// is serial-executor-confined). They never touch the `EventChannel` or the UI
/// thread directly; the AppDriver constructs the callback closures that do so.
///
/// ## Threading contract
///
/// - `syntaxPrePass(_:)` — synchronous, may be called from any thread; creates
///   a **fresh** throw-away engine per call and does not touch the lint engine.
/// - `lint(_:knownGlobals:)` — async; all engine work is dispatched onto the
///   service's internal serial executor.
/// - `prewarm(onReady:onCatalogProbed:onFailed:)` — async; must be called once, after
///   the first frame. The callbacks are invoked off the main thread; callers
///   must arrange for channel posting on the appropriate executor.
public protocol LintServiceProtocol: Sendable {

    /// Run the syntax pre-pass on `fragment`.
    ///
    /// Creates a short-lived engine, compiles the fragment's code, and
    /// immediately discards the result. If the code has a syntax error, returns
    /// a `Diagnostic` with the error line and message; returns `nil` when the
    /// code is syntactically valid.
    ///
    /// This is the fast path called on every source load or edit — it does NOT
    /// use the long-lived lint engine.
    ///
    /// - Parameter fragment: The Lua source to syntax-check.
    /// - Returns: A `.syntaxPrePass`-sourced `Diagnostic` on error, `nil` when clean.
    func syntaxPrePass(_ fragment: LuaSourceFragment) -> Diagnostic?

    /// Run a full luacheck pass on `fragment`.
    ///
    /// Uses the long-lived lint engine (serial executor). Requires
    /// `prewarm(onReady:onCatalogProbed:onFailed:)` to have completed; if called before
    /// the engine is ready, throws `LintServiceError.engineNotReady`.
    ///
    /// - Parameters:
    ///   - fragment: The Lua source to lint.
    ///   - knownGlobals: The luacheck globals table produced by
    ///     `LuaModuleCatalog.v0.luacheckGlobals(extraModules:tomlProbed:)` for
    ///     the current project configuration. Pre-validated by ProjectValidation.
    /// - Returns: Zero or more `Diagnostic` values, all `.luacheck`-sourced,
    ///   with fragment-relative line numbers.
    /// - Throws: `LintServiceError.engineNotReady` if the engine is not yet
    ///   initialised; `LintServiceError.engineFailed(message)` for internal
    ///   engine errors.
    func lint(
        _ fragment: LuaSourceFragment,
        knownGlobals: [String: Any]
    ) async throws -> [Diagnostic]

    /// Pre-warm the lint engine off the main thread.
    ///
    /// Creates the long-lived unrestricted engine, loads luacheck via the
    /// preload shim, then runs the one-shot luaswift.toml catalog probe. Calls
    /// `onReady` when the engine and luacheck are ready, then calls
    /// `onCatalogProbed(tomlAvailable:)` once the probe finishes.
    ///
    /// When engine creation or luacheck installation fails, `onReady` is NOT
    /// called; instead `onFailed` is called with a human-readable message so
    /// the TUI can display a "lint engine error" state rather than remaining
    /// stuck in the "initializing" state forever. (CR-012)
    ///
    /// Must be called exactly once (AppDriver, after the first frame).
    ///
    /// - Parameters:
    ///   - onReady: Called when the lint engine is ready. AppDriver wraps this
    ///     to post `AppEvent.lintEngineReady`.
    ///   - onCatalogProbed: Called with the probe result. AppDriver wraps this
    ///     to post `AppEvent.catalogProbed(tomlAvailable:)`.
    ///   - onFailed: Called with an error message when the engine cannot be
    ///     initialised. AppDriver wraps this to post `AppEvent.lintEngineFailed`.
    func prewarm(
        onReady: @escaping @Sendable () -> Void,
        onCatalogProbed: @escaping @Sendable (_ tomlAvailable: Bool) -> Void,
        onFailed: @escaping @Sendable (_ message: String) -> Void
    ) async
}

// MARK: - LintServiceError

/// Errors thrown by `LintServiceProtocol.lint`.
public enum LintServiceError: Error, Sendable, Equatable, CustomStringConvertible {
    /// `lint` was called before `prewarm` completed.
    case engineNotReady
    /// The lint engine reported an internal failure.
    case engineFailed(String)

    public var description: String {
        switch self {
        case .engineNotReady:
            return "Lint engine not ready — prewarm has not completed"
        case .engineFailed(let message):
            return "Lint engine error: \(message)"
        }
    }
}

// MARK: - LintService

/// Production implementation of `LintServiceProtocol`.
///
/// Holds one long-lived `LuaEngine` (unrestricted, with the luacheck preload
/// shim installed) and dispatches all engine calls onto a private serial queue
/// (`lintQueue`). The engine is not created until `prewarm` is called.
public final class LintService: LintServiceProtocol {

    // MARK: - Serial executor for the lint engine

    /// All lint engine operations run exclusively on this queue.
    ///
    /// `LuaEngine` is not thread-safe; the serial queue enforces single-threaded
    /// access without adding a lock. Declared `nonisolated(unsafe)` because the
    /// value is set once in `init` and never mutated, but Swift 6 strict
    /// concurrency requires the annotation for reference types shared across
    /// isolation boundaries.
    nonisolated(unsafe) private let lintQueue: DispatchQueue

    // MARK: - Lint engine (guarded by lintQueue)

    /// The long-lived luacheck engine. `nil` until `prewarm` completes.
    ///
    /// All reads and writes must happen on `lintQueue`. Declared
    /// `nonisolated(unsafe)` because `lintQueue` provides the serialisation
    /// guarantee manually; Swift 6 strict concurrency does not track this.
    nonisolated(unsafe) private var lintEngine: LuaEngine?

    // MARK: - Init

    /// Creates a `LintService`.
    ///
    /// - Parameter queueLabel: The dispatch queue label for the serial lint
    ///   executor. Defaults to the stable per-process label used in production.
    ///   Overrideable in tests for diagnostics.
    public init(queueLabel: String = "com.moonswift.lint-engine") {
        lintQueue = DispatchQueue(label: queueLabel, qos: .userInitiated)
    }

    // MARK: - LintServiceProtocol: syntaxPrePass

    public func syntaxPrePass(_ fragment: LuaSourceFragment) -> Diagnostic? {
        // Create a short-lived unrestricted engine just for compilation.
        // Unrestricted is used here because the spike confirmed that compile()
        // itself does not use load(); a sandboxed engine would also work, but
        // using the same configuration keeps the behaviour predictable.
        let engine: LuaEngine
        do {
            engine = try LuaEngine(
                configuration: LuaEngineConfiguration(
                    sandboxed: false,
                    packagePath: nil,
                    memoryLimit: 0
                )
            )
        } catch {
            // Engine creation failure is not a syntax error in the user code.
            // Return nil (no syntax diagnostic); the main lint pass will surface
            // the engine failure separately.
            return nil
        }

        do {
            // compile(_:) throws LuaError.syntaxError on syntax errors.
            // The returned Data (bytecode) is discarded immediately — this is
            // purely a syntax-validity check. When LuaSwift ships precompile(_:)
            // → CompiledChunk this call will be replaced (ARCHITECTURE §5.3).
            _ = try engine.compile(fragment.code)
            return nil
        } catch let luaError as LuaError {
            if case .syntaxError = luaError {
                // Map through the shared seam. The seam sets source = .runtime;
                // we override it to .syntaxPrePass here.
                let base = Diagnostic.from(luaError: luaError, provenance: fragment.provenance)
                return Diagnostic(
                    severity: .error,
                    line: base.line,
                    column: base.column,
                    code: base.code,
                    message: base.message,
                    source: .syntaxPrePass
                )
            }
            // Other LuaError cases (should not occur in compile path): ignore.
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - LintServiceProtocol: lint

    public func lint(
        _ fragment: LuaSourceFragment,
        knownGlobals: [String: Any]
    ) async throws -> [Diagnostic] {
        // Capture self weakly to avoid reference cycles in the detached task.
        return try await withCheckedThrowingContinuation { continuation in
            lintQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: LintServiceError.engineNotReady)
                    return
                }
                guard let engine = self.lintEngine else {
                    continuation.resume(throwing: LintServiceError.engineNotReady)
                    return
                }

                do {
                    let diagnostics = try self.runLuacheck(
                        engine: engine,
                        fragment: fragment,
                        knownGlobals: knownGlobals
                    )
                    continuation.resume(returning: diagnostics)
                } catch let e as LintServiceError {
                    continuation.resume(throwing: e)
                } catch {
                    continuation.resume(
                        throwing: LintServiceError.engineFailed(error.localizedDescription)
                    )
                }
            }
        }
    }

    // MARK: - LintServiceProtocol: prewarm

    public func prewarm(
        onReady: @escaping @Sendable () -> Void,
        onCatalogProbed: @escaping @Sendable (_ tomlAvailable: Bool) -> Void,
        onFailed: @escaping @Sendable (_ message: String) -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lintQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }

                // Step 1: Create the lint engine and install the preload shim.
                do {
                    let engine = try LuaEngine(
                        configuration: LuaEngineConfiguration(
                            sandboxed: false,
                            packagePath: nil,
                            memoryLimit: 0
                        )
                    )
                    let modules = try vendoredLuacheckModules()
                    try installLuacheckPreloadShim(engine: engine, modules: modules)
                    self.lintEngine = engine
                } catch {
                    // Engine setup failed — report the failure via onFailed so the
                    // TUI transitions from "initializing" to "failed" rather than
                    // remaining stuck. (CR-012: onFailed was previously absent here.)
                    // onReady is NOT called; onCatalogProbed is NOT called (they are
                    // irrelevant when the engine is unusable).
                    onFailed(error.localizedDescription)
                    continuation.resume()
                    return
                }

                // Step 2: Signal that the engine and luacheck are ready.
                onReady()

                // Step 3: Run the one-shot toml catalog probe on the lint engine.
                // The probe attempts to access luaswift.toml inside the engine.
                // If it resolves, toml is available in the running binary.
                let tomlAvailable = self.probeTomlAvailability()
                onCatalogProbed(tomlAvailable)

                continuation.resume()
            }
        }
    }

    // MARK: - Private: luacheck invocation

    /// Runs luacheck.check_strings on `fragment.code` inside `engine`.
    ///
    /// Builds the options table from `knownGlobals`, calls check_strings, and
    /// converts the structured Lua report to `[Diagnostic]` with
    /// fragment-relative line numbers.
    ///
    /// The `knownGlobals` value is the output of
    /// `LuaModuleCatalog.luacheckGlobals(extraModules:tomlProbed:)`, which
    /// returns a nested field map `{ "luaswift": { "fields": { … } } }`. This
    /// is passed as the TOP-LEVEL `globals` option in the check_strings call
    /// so luacheck merges it with the standard globals set and recognises the
    /// full luaswift.* namespace.
    ///
    /// Passing it at the top level (not per-file) matches how the spike test
    /// (fixture d) passes custom globals: `{globals = {...}}` as the outer
    /// options table. The per-file options array element is empty `{}` since
    /// all options live at the global scope here.
    ///
    /// Must be called exclusively on `lintQueue`.
    private func runLuacheck(
        engine: LuaEngine,
        fragment: LuaSourceFragment,
        knownGlobals: [String: Any]
    ) throws -> [Diagnostic] {
        // Encode the catalog field-map as the top-level `globals` option.
        // This tells luacheck which additional globals (beyond the default
        // Lua standard library) are in scope for the script being checked.
        let globalsLiteral = luaTableLiteral(from: knownGlobals)

        // Embed the code using a Lua long string (injection-safe).
        let codeLiteral = luaLongString(fragment.code)

        // Pass globals at the outer options level so luacheck merges them
        // with the default Lua standard globals. Per-file options are empty.
        // // swift-format-ignore
        let script = """
            local luacheck = require("luacheck")
            local opts = {
                globals = \(globalsLiteral),
            }
            return luacheck.check_strings({\(codeLiteral)}, opts)
            """

        let report: LuaValue
        do {
            report = try engine.evaluate(script)
        } catch let luaError as LuaError {
            throw LintServiceError.engineFailed(luaError.localizedDescription)
        } catch {
            throw LintServiceError.engineFailed(error.localizedDescription)
        }

        return diagnostics(from: report, provenance: fragment.provenance)
    }

    // MARK: - Private: report parsing

    /// Convert a check_strings return value to `[Diagnostic]`.
    ///
    /// check_strings returns a processed report table. LuaSwift bridges the
    /// per-file result as either `.array([LuaValue])` (pure integer keys) or
    /// `.table([String: LuaValue])` (mixed keys with integer keys as decimal
    /// strings). Both forms are handled here (docs/internals/lint.md §Report shape).
    private func diagnostics(
        from report: LuaValue,
        provenance: FragmentProvenance
    ) -> [Diagnostic] {
        guard let fileRep = extractFileReport(from: report) else { return [] }
        return extractIssues(from: fileRep).compactMap { issue in
            diagnostic(from: issue, provenance: provenance)
        }
    }

    /// Extract the per-file result table from the outer processed report.
    ///
    /// The outer report has the per-file result at Lua integer index 1.
    /// LuaSwift represents this as either `.table(["1": ...])` (mixed keys) or
    /// `.array([...])` (pure integer keys — the 0th element is index 1 in Lua).
    private func extractFileReport(from report: LuaValue) -> LuaValue? {
        switch report {
        case .table(let outer):
            return outer["1"]
        case .array(let arr):
            return arr.isEmpty ? nil : arr[0]
        default:
            return nil
        }
    }

    /// Extract all issue dictionaries (integer-keyed entries) from a per-file report.
    private func extractIssues(from fileRep: LuaValue) -> [[String: LuaValue]] {
        switch fileRep {
        case .array(let arr):
            return arr.compactMap { element -> [String: LuaValue]? in
                if case .table(let t) = element { return t } else { return nil }
            }
        case .table(let dict):
            return dict.compactMap { key, val -> [String: LuaValue]? in
                guard Int(key) != nil, case .table(let t) = val else { return nil }
                return t
            }
        default:
            return []
        }
    }

    /// Map one luacheck issue dictionary to a `Diagnostic`.
    ///
    /// An issue has at minimum: `code` (string), `line` (number), `column`
    /// (number), and `msg` (string from get_message — added by check_strings).
    /// The line is fragment-relative (luacheck counts from 1 within the string
    /// passed to check_strings).
    private func diagnostic(
        from issue: [String: LuaValue],
        provenance: FragmentProvenance
    ) -> Diagnostic? {
        guard
            let codeVal = issue["code"], case .string(let code) = codeVal,
            let lineVal = issue["line"], let line = lineVal.intValue,
            line > 0
        else { return nil }

        let column: Int? =
            issue["column"].flatMap { if case .number(let n) = $0 { return Int(n) } else { return nil } }

        // `msg` is populated by luacheck when check_strings formats the report.
        // Fall back to the raw code string if msg is absent (defensive).
        let message: String
        if let msgVal = issue["msg"], case .string(let m) = msgVal, !m.isEmpty {
            message = m
        } else {
            message = "luacheck \(code)"
        }

        let severity: Diagnostic.Severity = code.hasPrefix("0") ? .error : .warning

        return Diagnostic(
            severity: severity,
            line: line,
            column: column,
            code: code,
            message: message,
            source: .luacheck
        )
    }

    // MARK: - Private: toml catalog probe

    /// Probe whether `luaswift.toml` is available in the running engine.
    ///
    /// Runs a short Lua snippet that attempts to access the `toml` sub-table of
    /// the `luaswift` global. If the table exists and has at least one key, toml
    /// is available. Any error or nil result means it is not.
    ///
    /// Must be called exclusively on `lintQueue` (uses `lintEngine`).
    private func probeTomlAvailability() -> Bool {
        guard let engine = lintEngine else { return false }
        do {
            // // swift-format-ignore
            let result = try engine.evaluate(
                "return type(luaswift) == 'table' and type(luaswift.toml) == 'table'"
            )
            if case .bool(let available) = result { return available }
        } catch {
            // Any engine error means we cannot confirm availability.
        }
        return false
    }
}

// MARK: - Lua table literal encoding

/// Convert a `[String: Any]` luacheck globals dictionary to an inline Lua
/// table literal string.
///
/// Only the two shapes produced by `LuaModuleCatalog.luacheckGlobals` are
/// handled: `[String: Any]` values are encoded as nested `{ fields = {…} }`
/// tables; other values are encoded as empty tables `{}`.
///
/// This function is file-private because it is an implementation detail of
/// `LintService.runLuacheck`. The encoding is deterministic (sorted keys) so
/// the generated Lua is stable across runs.
private func luaTableLiteral(from dict: [String: Any]) -> String {
    guard !dict.isEmpty else { return "{}" }
    let pairs = dict.keys.sorted().map { key -> String in
        let escaped = key.replacingOccurrences(of: "\"", with: "\\\"")
        let value = luaValueLiteral(from: dict[key])
        return "[\"\(escaped)\"] = \(value)"
    }
    return "{ " + pairs.joined(separator: ", ") + " }"
}

/// Recursively encode a value to a Lua literal.
private func luaValueLiteral(from value: Any?) -> String {
    switch value {
    case let d as [String: Any]:
        return luaTableLiteral(from: d)
    case let s as String:
        let escaped = s.replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    case let b as Bool:
        return b ? "true" : "false"
    case let n as Int:
        return "\(n)"
    case let n as Double:
        return "\(n)"
    default:
        return "{}"
    }
}
