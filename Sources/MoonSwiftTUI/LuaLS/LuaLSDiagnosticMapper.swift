// File: Sources/MoonSwiftTUI/LuaLS/LuaLSDiagnosticMapper.swift
// Folder: Sources/MoonSwiftTUI/LuaLS/
// Role: Translate lua-language-server LSP diagnostics into MoonSwift's own
//       `Diagnostic` model (F7b). The only impedance mismatches are coordinate
//       base (LSP is 0-based line/character, MoonSwift is 1-based) and the
//       severity scale (LSP has four levels, MoonSwift has two). Pure, with no
//       process or actor dependency, so it is unit-tested directly.
//
// Upstream: LanguageServerProtocol.PublishDiagnosticsParams (from LuaLSClient)
// Downstream: LuaLSClient → AppEvent.lualsDiagnostics → Diagnostics tab

import Foundation
import LanguageServerProtocol
import MoonSwiftCore

// `Diagnostic` is declared in BOTH MoonSwiftCore and LanguageServerProtocol, so
// every use below is module-qualified to keep the impedance-match explicit.

/// Maps a published LSP diagnostics batch to MoonSwift `Diagnostic` values.
enum LuaLSDiagnosticMapper {

    /// Map every LSP diagnostic in `params` to a `.luals`-sourced `Diagnostic`.
    static func map(_ params: PublishDiagnosticsParams) -> [MoonSwiftCore.Diagnostic] {
        params.diagnostics.map { map(lspDiagnostic: $0) }
    }

    /// Map a single LSP diagnostic.
    ///
    /// - Severity: LSP `.error` (1) maps to `.error`; `.warning`, `.information`,
    ///   and `.hint` all map to `.warning`. MoonSwift has no informational tier,
    ///   and silently dropping info/hint would hide real LuaLS findings, so they
    ///   are surfaced as warnings (the conservative, non-lossy choice; PRD F7b
    ///   leaves the mapping to implementation).
    /// - Position: LSP line/character are 0-based; MoonSwift line/column are
    ///   1-based, hence the `+ 1`.
    static func map(lspDiagnostic d: LanguageServerProtocol.Diagnostic) -> MoonSwiftCore.Diagnostic {
        let severity: MoonSwiftCore.Diagnostic.Severity = (d.severity == .error) ? .error : .warning
        return MoonSwiftCore.Diagnostic(
            severity: severity,
            line: d.range.start.line + 1,
            column: d.range.start.character + 1,
            code: codeString(d.code),
            message: d.message,
            source: .luals
        )
    }

    /// Render the LSP diagnostic code (an `Int`-or-`String` union) as a string,
    /// or `nil` when the server supplied no code.
    private static func codeString(_ code: DiagnosticCode?) -> String? {
        switch code {
        case .optionA(let intCode): return String(intCode)
        case .optionB(let stringCode): return stringCode
        case nil: return nil
        }
    }
}
