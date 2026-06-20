// File: Sources/MoonSwiftCore/Mock/MockValueServer.swift
// Location: MoonSwiftCore/Mock/
// Role: LuaValueServer implementation for one mock namespace (F5.1).
//
//       Each `MockValueServer` instance owns the materialized Lua values for
//       one namespace's `[[mock.value]]` declarations. It is created by
//       `SessionEngine.startSession` (the F5.1/F5.2 seam), materializes every
//       declared value via `engine.evaluate("return \(def.value)")`, then is
//       registered with `engine.register(server:)` before the stdlib baseline
//       is captured (DATA-N04).
//
//       ## Path model
//
//       A `MockValueDef.path` is a dotted string (e.g. `"settings.debug"`).
//       `resolve(path:)` receives the components AFTER the namespace:
//       `["settings", "debug"]` for `myapp.settings.debug`. The server joins
//       the component array to a dot-key and looks it up in `materialized`.
//       For an intermediate component (`["settings"]`) no `MockValueDef` has
//       that exact key, so `.nil` is returned — the LuaValueServer proxy-table
//       mechanism continues traversal automatically.
//
//       ## Writability
//
//       `canWrite(path:)` returns the `writable` flag of the matching
//       `MockValueDef`. `write(path:value:)` stores the new `LuaValue` in the
//       mutable `materialized` dict (protected by `lock`) for writable paths,
//       and throws `LuaError.readOnlyAccess(path:)` for non-writable paths.
//       Writes are immediately visible to `resolve` and — after the run — to
//       `SessionEngine.liveState()` via `engine.globalValue(namespace)`.
//
//       ## Thread safety
//
//       `MockValueServer` is an `AnyObject` (class). `resolve` and `write` are
//       called from the Lua VM thread (the serial executor's `DispatchQueue`).
//       Materialization also runs on that queue (inside `startSession`). All
//       mutation is therefore single-threaded under normal operation; `lock` is
//       a lightweight guard for the defensive case where LuaSwift ever calls
//       these from a different thread.
//
// Upstream: MockValueDef, LuaEngine (for materialization), LuaValueServer,
//           LuaError
// Downstream: SessionEngine.startSession (creates + registers),
//             LuaValueServer protocol (LuaEngine+ValueServer.swift:40)

import Foundation
import LuaSwift

// MARK: - MockValueServer

/// LuaValueServer for one mock namespace, serving materialized Lua values
/// for every `[[mock.value]]` declaration in that namespace (F5.1).
///
/// Create via `MockValueServer(namespace:defs:engine:)`, which materializes
/// all declared values immediately. Then pass the instance to
/// `engine.register(server:)`.
public final class MockValueServer: LuaValueServer {

    // MARK: - LuaValueServer: namespace

    public let namespace: String

    // MARK: - Private state

    /// Guards `materialized` for the defensive multi-thread case.
    private let lock = NSLock()

    /// Materialized values keyed by the dot-joined path string (e.g.
    /// `"settings.debug"`). Populated once during `init`; writable paths
    /// are updated in-place by `write(path:value:)`.
    nonisolated(unsafe) private var materialized: [String: LuaValue]

    /// Per-path writability flags, keyed by dot-joined path string.
    /// Immutable after init — `MockValueDef.writable` never changes.
    private let writability: [String: Bool]

    // MARK: - Init

    /// Creates a `MockValueServer` and materializes every declared value.
    ///
    /// **Must be called on the serial executor** (inside `startSession`'s
    /// `queue.async` block), because `engine.evaluate` is not thread-safe.
    ///
    /// - Parameters:
    ///   - namespace: The Lua global name for this server (e.g. `"myapp"`).
    ///   - defs: The `[[mock.value]]` definitions belonging to `namespace`.
    ///   - engine: The just-created `LuaEngine` used for materialization.
    ///     Must be on the serial executor; its state is not yet shared.
    public init(
        namespace: String,
        defs: [MockValueDef],
        engine: LuaEngine,
        onError: (String) -> Void = { _ in }
    ) {
        self.namespace = namespace
        var materializedValues: [String: LuaValue] = [:]
        var writableFlags: [String: Bool] = [:]
        for def in defs {
            let key = def.path
            writableFlags[key] = def.writable
            // Materialize: evaluate("return <value>") under the session engine.
            // Any Lua value expression works — scalar, table constructor, function
            // literal, or computed expression (RQ1). A function literal yields a
            // `.luaFunction(ref)` that the Lua script can call.
            do {
                let value = try engine.evaluate("return \(def.value)")
                materializedValues[key] = value
            } catch {
                // Materialization failure: store `.nil` so a single bad mock
                // cannot crash session setup. The project has already been
                // syntax-validated (F5.5), so a runtime failure here is almost
                // always the sandbox blocking a call (e.g. os.execute in
                // sandboxed mode) — not a syntax problem. The error is still
                // reported through `onError` (CR-033) so an unexpected,
                // non-sandbox failure is never swallowed silently.
                onError(
                    "mock value \"\(namespace).\(key)\" failed to materialize: "
                        + "\(error.localizedDescription); using nil")
                materializedValues[key] = .nil
            }
        }
        self.materialized = materializedValues
        self.writability = writableFlags
    }

    // MARK: - LuaValueServer: resolve

    /// Resolves a path component array to a materialized `LuaValue`.
    ///
    /// The `path` array contains components AFTER the namespace:
    /// `["settings", "debug"]` for `myapp.settings.debug`. The components are
    /// joined with `"."` and looked up in `materialized`. An unrecognised or
    /// intermediate path returns `.nil`, letting the engine's proxy-table
    /// mechanism handle further traversal.
    ///
    /// - Parameter path: Path components below the namespace.
    /// - Returns: The materialized value, or `.nil` for unknown / intermediate
    ///   paths.
    public func resolve(path: [String]) -> LuaValue {
        guard !path.isEmpty else { return .nil }
        let key = path.joined(separator: ".")
        return lock.withLock { materialized[key] ?? .nil }
    }

    // MARK: - LuaValueServer: canWrite

    /// Returns whether the given path was declared `writable = true`.
    ///
    /// - Parameter path: Path components below the namespace.
    /// - Returns: `true` when the matching `MockValueDef.writable` is `true`.
    public func canWrite(path: [String]) -> Bool {
        guard !path.isEmpty else { return false }
        let key = path.joined(separator: ".")
        return writability[key] ?? false
    }

    // MARK: - LuaValueServer: write

    /// Writes `value` to a writable path, or throws for a read-only path.
    ///
    /// A successful write is immediately visible to subsequent `resolve`
    /// calls, and — after the run — to `SessionEngine.liveState()` through
    /// the engine's `globalValue(namespace)` introspection.
    ///
    /// - Parameters:
    ///   - path: Path components below the namespace.
    ///   - value: The new `LuaValue` to store.
    /// - Throws: `LuaError.readOnlyAccess(path:)` when `canWrite` is false.
    public func write(path: [String], value: LuaValue) throws {
        // Empty-path guard — mirrors `resolve`/`canWrite`. Without it the
        // namespace root reads as a malformed `"<namespace>."` key and reports
        // a misleading read-only throw; the root itself is not a writable slot.
        guard !path.isEmpty else {
            throw LuaError.readOnlyAccess(path: namespace)
        }
        let key = path.joined(separator: ".")
        let fullPath = "\(namespace).\(key)"
        guard canWrite(path: path) else {
            throw LuaError.readOnlyAccess(path: fullPath)
        }
        lock.withLock { materialized[key] = value }
    }
}
