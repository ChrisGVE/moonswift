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
import MoonSwiftCore

extension AppDriver {

    /// The bound no-session transient (ux-spec §7.5 step 6).
    private static let invokeNoSessionMessage = "Invoke a Lua function: run the source first."

    /// The Lua-error substring Lua raises when the call target is not callable
    /// ("attempt to call a nil value"); used to map control-3 failures to the
    /// not-a-function transient (PRD §F5.3).
    private static let notCallableMarker = "attempt to call a nil value"

    /// Run the three F5.3 controls for `expression` and post the outcome event.
    func executeInvokeLuaCall(_ expression: String) {
        // Control 1 — lint gate. Skipped only in the skeleton/no-lint config
        // (tests without a LintService); production always has one.
        if let svc = lintService, let diag = svc.syntaxPrePass("return \(expression)") {
            channel.post(.luaInvocationLintFailed(diag.message))
            return
        }

        // Control 2 — target no-dots check (pure, but kept here so the whole
        // pipeline is one place — the reducer never runs any of it).
        guard case .valid(let targetName) = extractCallTarget(expression) else {
            channel.post(.luaInvocationTargetInvalid)
            return
        }

        // Control 3 — evaluate against the live session engine. No engine at all
        // (skeleton/tests) is the no-session case.
        guard let engine = sessionEngine else {
            channel.post(.transient(Self.invokeNoSessionMessage))
            return
        }

        Task { [channel] in
            do {
                let value = try await engine.invokeLuaCall(expression)
                channel.post(.luaInvocationResult(renderLuaValue(value)))
            } catch let e as SessionEngineError where e == .notStarted {
                // No run yet this session → the engine was never started.
                channel.post(.transient(Self.invokeNoSessionMessage))
            } catch {
                let message = error.localizedDescription
                if message.contains(Self.notCallableMarker) {
                    channel.post(.transient("\(targetName) is not a function."))
                } else {
                    channel.post(.luaInvocationFailed(message))
                }
            }
        }
    }
}
