// File: Sources/MoonSwiftTUI/App/AppDriver+InvokeEffects.swift
// Location: MoonSwiftTUI/App/
// Role: P2 F5.3 — the AppDriver's side-effectful Lua-invocation handler. The
//       reducer emits `Effect.invokeLuaCall(rawExpression)` and NEVER runs the
//       controls (they are impure — they spin a throwaway lint engine and call
//       the live session engine, ARCH-R7-01). This extension runs the THREE
//       ordered controls and posts the outcome back as an `AppEvent`:
//         1. LINT — `syntaxPrePass("return <expr>")`; a syntax error posts
//            `.luaInvocationLintFailed(detail)` (inline `Invalid call
//            expression: <detail>`), stops.
//         2. TARGET no-dots check — `extractCallTarget(expr)`; a dotted/indexed/
//            method head posts `.luaInvocationTargetInvalid` (`Invalid function
//            name.`), stops before any engine call (SEC-09/SEC-10).
//         3. EVALUATE — `SessionEngineProtocol.invokeLuaCall(expr)` →
//            `evaluate("return <expr>")`; success posts
//            `.luaInvocationResult(display)` (FIRST return value, ux-spec §6.3);
//            a not-a-function / no-session failure posts a `.transient`; any other
//            runtime error posts `.luaInvocationFailed(message)`.
//
// Upstream: AppDriver (lintService, sessionEngine, channel), MoonSwiftCore
//           (extractCallTarget, SessionEngineError, renderLuaValue)
// Downstream: Reducer (invocation events + transient)

import Foundation
import LuaSwift
import MoonSwiftCore

extension AppDriver {

    /// The bound no-session transient (ux-spec §7.5 step 6).
    private static let invokeNoSessionMessage = "Invoke a Lua function: run the source first."

    /// The bound transient for an invoke attempted while the VM is busy (a run or
    /// a debug session is active, so introspection is not between-runs) — CR-021.
    /// Replaces the raw internal `SessionEngineError.enginePaused` description
    /// that previously leaked inline through the generic failure path.
    private static let invokeEnginePausedMessage =
        "Invoke unavailable while a run or debug session is active."

    /// The raw (locale-independent) Lua message fragment for a not-callable
    /// target ("attempt to call a nil value"); matched against the structured
    /// `LuaError` raw message — NOT a localized description — to map control-3
    /// failures to the not-a-function transient (PRD §F5.3, CR-022).
    private static let notCallableMarker = "attempt to call a nil value"

    /// Run the three F5.3 controls for `expression` and post the outcome event.
    ///
    /// All three controls run on a background `Task` (CR-024): control 1 spins a
    /// throwaway lint engine, so running it on the UI thread stalled a frame.
    func executeInvokeLuaCall(_ expression: String) {
        Task { [channel, lintService, sessionEngine] in
            // Control 1 — lint gate. Skipped only in the skeleton/no-lint config
            // (tests without a LintService); production always has one.
            if let svc = lintService, let diag = svc.syntaxPrePass("return \(expression)") {
                channel.post(.luaInvocationLintFailed(diag.message))
                return
            }

            // Control 2 — target no-dots check (pure, but kept in this pipeline
            // so the reducer never runs any of it).
            guard case .valid(let targetName) = extractCallTarget(expression) else {
                channel.post(.luaInvocationTargetInvalid)
                return
            }

            // Control 3 — evaluate against the live session engine. No engine at
            // all (skeleton/tests) is the no-session case.
            guard let engine = sessionEngine else {
                channel.post(.transient(Self.invokeNoSessionMessage))
                return
            }

            do {
                let value = try await engine.invokeLuaCall(expression)
                channel.post(.luaInvocationResult(renderLuaValue(value)))
            } catch let e as SessionEngineError {
                // Map each structured engine error to a short transient rather
                // than leaking its internal description inline (CR-021).
                switch e {
                case .notStarted:
                    channel.post(.transient(Self.invokeNoSessionMessage))
                case .enginePaused:
                    channel.post(.transient(Self.invokeEnginePausedMessage))
                case .engineCreationFailed:
                    channel.post(.luaInvocationFailed(e.description))
                }
            } catch let luaError as LuaError {
                // Not-callable detection on the STRUCTURED raw Lua message
                // (locale-independent), not `localizedDescription` (CR-022).
                if luaErrorRawMessage(luaError).contains(Self.notCallableMarker) {
                    channel.post(.transient("\(targetName) is not a function."))
                } else {
                    channel.post(.luaInvocationFailed(luaError.errorDescription ?? "\(luaError)"))
                }
            } catch {
                channel.post(.luaInvocationFailed(error.localizedDescription))
            }
        }
    }
}

/// The raw, unprocessed Lua error text for the not-callable check — drawn from
/// the structured `LuaError` associated values (CR-022), never the localized
/// description, so the match is independent of locale framing.
private func luaErrorRawMessage(_ error: LuaError) -> String {
    switch error {
    case .runtimeFailure(let failure): return failure.rawMessage
    case .runtimeError(let message): return message
    default: return ""
    }
}
