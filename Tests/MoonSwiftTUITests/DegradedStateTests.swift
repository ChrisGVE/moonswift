// File: Tests/MoonSwiftTUITests/DegradedStateTests.swift
// Location: MoonSwiftTUITests/
// Role: Tests for all degraded states defined in ux-spec §3.7, §4.2, §1.4.
//       Covers: small terminal, 256-color / NO_COLOR fallback, malformed project
//       (navigator + code pane + key restriction), lint engine error, Lua engine
//       error (RunOutcome.engineError), and unsupported Lua version (bottom pane
//       persistent header + r/l key blocks). All assertions are pure — no FFI.
// Upstream: Renderer.swift, Reducer.swift, AppState.swift, AppEvent.swift
// Downstream: (test target)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// Minimal terminal size that clears the 80×24 threshold.
private func minSize() -> TerminalSize { TerminalSize(cols: 80, rows: 24) }

/// Terminal sizes below the minimum.
private func smallSize(cols: UInt16 = 79, rows: UInt16 = 23) -> TerminalSize {
    TerminalSize(cols: cols, rows: rows)
}

/// Returns a `Diagnostic` for use in malformed-project state.
private func malformedDiag(_ msg: String = "unexpected key 'bad_key', line 3") -> Diagnostic {
    Diagnostic(severity: .error, message: msg, source: .projectConfig)
}

/// Returns an `AppState` with a project in `.malformed` state.
private func malformedState() -> AppState {
    var s = AppState()
    s.project = .malformed(malformedDiag())
    return s
}

/// Returns an `AppState` with a loaded source and project.
private func loadedState() -> (AppState, SourceID) {
    let id = SourceID(path: "init.lua")
    var s = AppState()
    let url = URL(fileURLWithPath: "/project/init.lua")
    let code = "print('hello')"
    let data = Data(code.utf8)
    let hash = SHA256.hash(data: data)
    let prov = FragmentProvenance(
        file: url, jsonpath: nil, document: 0,
        byteRange: 0..<data.count, lineOffset: 0, contentHash: hash)
    s.sources[id] = .loaded(LuaSourceFragment(code: code, provenance: prov))
    s.navigatorOrder = [id]
    s.selection = id
    s.lintState = .idle
    s.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    return (s, id)
}

/// Returns an `AppState` with project set to `.unsupportedVersion("5.3")`.
private func unsupportedVersionState() -> AppState {
    var (s, _) = loadedState()
    s.project = .unsupportedVersion("5.3")
    return s
}

/// Extracts all `.paragraph` lines' first-span text from render commands.
private func paragraphTexts(_ cmds: [RenderCommand]) -> [String] {
    cmds.compactMap { cmd -> [String]? in
        if case .paragraph(_, let lines, _) = cmd {
            return lines.map { $0.first?.text ?? "" }
        }
        return nil
    }.flatMap { $0 }
}

/// Extracts all `.cellRun` text values from render commands.
private func cellRunTexts(_ cmds: [RenderCommand]) -> [String] {
    cmds.compactMap {
        if case .cellRun(_, _, let text, _) = $0 { return text }
        return nil
    }
}

/// Extracts all `.navigatorList` first-item texts from render commands.
private func navigatorFirstItemText(_ cmds: [RenderCommand]) -> String? {
    for cmd in cmds {
        if case .navigatorList(_, let items, _, _) = cmd {
            return items.first?.text
        }
    }
    return nil
}

/// Returns true if any `.cellRun` text starts with the given prefix.
private func hasCellRunStarting(_ prefix: String, in cmds: [RenderCommand]) -> Bool {
    cellRunTexts(cmds).contains { $0.hasPrefix(prefix) }
}

// MARK: - Small terminal (ux-spec §1.4)

@Suite("Degraded — Small terminal (ux-spec §1.4)")
struct SmallTerminalTests {

    @Test("79×24 emits belowMinimumSize with correct dimensions")
    func below80Wide() {
        let cmds = render(AppState(), size: smallSize(cols: 79, rows: 24))
        var found = false
        for cmd in cmds {
            if case .belowMinimumSize(let c, let r) = cmd {
                #expect(c == 79)
                #expect(r == 24)
                found = true
            }
        }
        #expect(found, "Expected .belowMinimumSize command")
    }

    @Test("80×23 emits belowMinimumSize")
    func below24Tall() {
        let cmds = render(AppState(), size: smallSize(cols: 80, rows: 23))
        let count = cmds.filter {
            if case .belowMinimumSize = $0 { return true }
            return false
        }.count
        #expect(count == 1)
    }

    @Test("below-minimum render is the single belowMinimumSize command (message is driver-side)")
    func belowMinimumMessage() {
        // The renderer leaves the alternate screen unavailable below minimum:
        // it emits ONLY the .belowMinimumSize data command. The literal
        // "Terminal too small (WxH)…" prompt (ux-spec §1.4) is written by the
        // AppDriver outside the alternate screen when interpreting this
        // command (see issue #2 — production RenderCommand interpreter).
        let cmds = render(AppState(), size: smallSize(cols: 60, rows: 20))
        #expect(cmds.count == 1, "Below minimum must emit exactly one command")
        if case .belowMinimumSize(let c, let r) = cmds[0] {
            #expect(c == 60)
            #expect(r == 20)
        } else {
            Issue.record("Expected .belowMinimumSize, got \(cmds[0])")
        }
    }
}

// MARK: - 256-color / NO_COLOR spinner fallback (ux-spec §4.3)

@Suite("Degraded — Color capability fallback (ux-spec §4.3)")
struct ColorCapabilityTests {

    /// Builds a state with one loading source so the navigator renders a spinner.
    private func loadingSourceState(capability: ColorCapability) -> AppState {
        let id = SourceID(path: "loading.lua")
        var s = AppState()
        s.sources[id] = .loading
        s.navigatorOrder = [id]
        s.theme.capability = capability
        s.navigator.spinnerPhase = 0
        return s
    }

    /// Finds the first navigator item text in render commands.
    private func firstNavItem(_ cmds: [RenderCommand]) -> String? {
        for cmd in cmds {
            if case .navigatorList(_, let items, _, _) = cmd { return items.first?.text }
        }
        return nil
    }

    @Test("truecolor spinner character is from the braille set (ux-spec §4.1)")
    func brailleSpinnerTruecolor() {
        let state = loadingSourceState(capability: .truecolor)
        let cmds = render(state, size: TerminalSize(cols: 80, rows: 24))
        guard let text = firstNavItem(cmds), let first = text.unicodeScalars.first else {
            Issue.record("No navigator item rendered")
            return
        }
        // Braille block: U+2800–U+28FF
        let isBraille = (0x2800...0x28FF).contains(first.value)
        #expect(isBraille, "truecolor spinner must be braille (U+2800–28FF), got U+\(String(first.value, radix: 16))")
    }

    @Test("256-color spinner character is ASCII (ux-spec §4.3)")
    func asciiSpinner256Color() {
        let state = loadingSourceState(capability: .color256)
        let cmds = render(state, size: TerminalSize(cols: 80, rows: 24))
        guard let text = firstNavItem(cmds), let first = text.first else {
            Issue.record("No navigator item rendered")
            return
        }
        let ascii = "|/-\\"
        #expect(
            ascii.contains(first),
            "256-color spinner must be ASCII (|/-\\), got: \(first)")
    }

    @Test("NO_COLOR spinner character is ASCII (ux-spec §4.3)")
    func asciiSpinnerNoColor() {
        let state = loadingSourceState(capability: .noColor)
        let cmds = render(state, size: TerminalSize(cols: 80, rows: 24))
        guard let text = firstNavItem(cmds), let first = text.first else {
            Issue.record("No navigator item rendered")
            return
        }
        let ascii = "|/-\\"
        #expect(
            ascii.contains(first),
            "noColor spinner must be ASCII (|/-\\), got: \(first)")
    }
}

// MARK: - Malformed project — Navigator (ux-spec §4.2)

@Suite("Degraded — Malformed project: navigator (ux-spec §4.2)")
struct MalformedProjectNavigatorTests {

    @Test("Navigator shows single 'Project file error' entry")
    func navigatorShowsErrorEntry() {
        let state = malformedState()
        let cmds = render(state, size: minSize())
        let first = navigatorFirstItemText(cmds)
        #expect(
            first == "Project file error",
            "Navigator must show 'Project file error' when project is malformed, got: \(first ?? "nil")")
    }

    @Test("Navigator 'Project file error' entry uses error token style")
    func navigatorErrorStyle() {
        var state = malformedState()
        // TerminalColor.rgb(255, 0, 0) → CellStyle.fg = 0x00FF0000 (0x00RRGGBB encoding).
        state.theme.tokens[.error] = TokenStyle(fg: .rgb(255, 0, 0))
        let cmds = render(state, size: minSize())
        for cmd in cmds {
            if case .navigatorList(_, let items, _, _) = cmd {
                if let first = items.first {
                    #expect(first.text == "Project file error")
                    // CellStyle.fg is UInt32 encoded as 0x00RRGGBB.
                    #expect(
                        first.style.fg == 0x00FF_0000,
                        "Error token fg must be 0x00FF0000 (red), got: 0x\(String(first.style.fg, radix: 16))")
                    return
                }
            }
        }
        Issue.record("No navigatorList command found")
    }
}

// MARK: - Malformed project — Code pane (ux-spec §4.2)

@Suite("Degraded — Malformed project: code pane (ux-spec §4.2)")
struct MalformedProjectCodePaneTests {

    @Test("Code pane shows '✖ Project file error' header line")
    func codePaneHeader() {
        let state = malformedState()
        let cmds = render(state, size: minSize())
        let texts = paragraphTexts(cmds)
        #expect(
            texts.contains("✖ Project file error"),
            "Code pane must start with '✖ Project file error', texts: \(texts)")
    }

    @Test("Code pane shows parse error message including file reference")
    func codePaneParseError() {
        let msg = "unexpected key 'bad_key', line 3"
        var state = AppState()
        state.project = .malformed(malformedDiag(msg))
        let cmds = render(state, size: minSize())
        let texts = paragraphTexts(cmds)
        let hasErrorLine = texts.contains { $0.contains("moonswift.toml:") && $0.contains(msg) }
        #expect(
            hasErrorLine,
            "Code pane must show 'moonswift.toml: <error>' line, texts: \(texts)")
    }

    @Test("Code pane shows reload instruction")
    func codePaneReloadInstruction() {
        let state = malformedState()
        let cmds = render(state, size: minSize())
        let texts = paragraphTexts(cmds)
        let hasInstruction = texts.contains { $0.contains("<C-r>") && $0.contains("reload") }
        #expect(
            hasInstruction,
            "Code pane must show reload instruction with '<C-r>', texts: \(texts)")
    }

    @Test("Code pane 4-line block: header, blank, error, blank, instruction")
    func codePaneBlockStructure() {
        let msg = "parse error at line 5"
        var state = AppState()
        state.project = .malformed(malformedDiag(msg))
        let cmds = render(state, size: minSize())
        // Find paragraph from the code pane region (not navigator or bottom pane).
        // The malformed block must contain all 4 key spans.
        let texts = paragraphTexts(cmds)
        #expect(texts.contains("✖ Project file error"))
        #expect(texts.contains { $0.contains("moonswift.toml:") })
        #expect(texts.contains { $0.contains("<C-r>") })
    }
}

// MARK: - Malformed project — Key restriction (ux-spec §4.2)

@Suite("Degraded — Malformed project: key restriction (ux-spec §4.2)")
struct MalformedProjectKeyTests {

    /// Returns a state with malformed project and a selection (so keys that would
    /// normally do something can be verified as blocked).
    private func state() -> AppState {
        var s = malformedState()
        s.focus = .pane(.navigator)
        return s
    }

    @Test("q is allowed: emits quit effect")
    func qIsAllowed() {
        let (_, effects) = reduce(state(), .key(.char("q"), modifiers: []))
        let hasQuit = effects.contains {
            if case .quit = $0 { return true }
            return false
        }
        #expect(hasQuit, "q must emit .quit in malformed project state")
    }

    @Test("? is allowed: opens help overlay")
    func helpIsAllowed() {
        let (next, _) = reduce(state(), .key(.char("?"), modifiers: []))
        #expect(next.focus == .helpOverlay, "? must open help overlay in malformed state")
    }

    @Test("C-r is allowed: emits reloadProject effect")
    func ctrlRIsAllowed() {
        let (_, effects) = reduce(state(), .key(.char("r"), modifiers: .ctrl))
        let hasReload = effects.contains {
            if case .reloadProject = $0 { return true }
            return false
        }
        #expect(hasReload, "C-r must emit .reloadProject in malformed state")
    }

    @Test("r is blocked: produces disabled transient, no .run effect")
    func rIsBlocked() {
        let (next, effects) = reduce(state(), .key(.char("r"), modifiers: []))
        let hasRun = effects.contains {
            if case .run = $0 { return true }
            return false
        }
        #expect(!hasRun, "r must not emit .run in malformed project state")
        #expect(next.transient != nil, "r must produce a transient message in malformed state")
    }

    @Test("l is blocked: produces disabled transient, no .lint effect")
    func lIsBlocked() {
        let (next, effects) = reduce(state(), .key(.char("l"), modifiers: []))
        let hasLint = effects.contains {
            if case .lint = $0 { return true }
            return false
        }
        #expect(!hasLint, "l must not emit .lint in malformed project state")
        #expect(next.transient != nil, "l must produce a transient message in malformed state")
    }

    @Test("i is blocked: produces disabled transient, no initForm side-effect")
    func iIsBlocked() {
        let (next, effects) = reduce(state(), .key(.char("i"), modifiers: []))
        // i would normally open the init form; with malformed project it must be blocked.
        let hasScan = effects.contains {
            if case .scanProjectDirectory = $0 { return true }
            return false
        }
        #expect(!hasScan, "i must not trigger scanProjectDirectory in malformed state")
        #expect(next.transient != nil, "i must produce a transient in malformed state")
    }

    @Test("Tab is blocked: produces disabled transient")
    func tabIsBlocked() {
        let (next, _) = reduce(state(), .key(.tab, modifiers: []))
        #expect(next.transient != nil, "Tab must produce a transient in malformed state")
    }

    @Test("blocked key transient mentions fixing the file")
    func blockedTransientMentionsFile() {
        let (next, _) = reduce(state(), .key(.char("r"), modifiers: []))
        if let msg = next.transient?.text {
            // ux-spec §4.2: disabled transient should guide user to fix the file.
            #expect(
                msg.lowercased().contains("project") || msg.lowercased().contains("file"),
                "Transient must mention 'project' or 'file', got: \(msg)")
        } else {
            Issue.record("No transient produced for blocked key in malformed state")
        }
    }
}

// MARK: - Lint engine error (ux-spec §4.2)

@Suite("Degraded — Lint engine error (ux-spec §4.2)")
struct LintEngineErrorTests {

    @Test("lintEngineFailed event transitions lintState to .failed")
    func lintEngineFailedState() {
        let (next, _) = reduce(AppState(), .lintEngineFailed("sandbox violation"))
        if case .failed(let msg) = next.lintState {
            #expect(msg == "sandbox violation")
        } else {
            Issue.record("lintState must be .failed after lintEngineFailed")
        }
    }

    @Test("diagnostics tab shows '✖ Lint engine error: <message>' when lintState is failed")
    func diagnosticsTabShowsLintError() {
        var state = AppState()
        state.lintState = .failed("sandbox violation")
        state.bottomPane.activeTab = .diagnostics
        let cmds = render(state, size: minSize())
        let texts = paragraphTexts(cmds)
        let expected = "✖ Lint engine error: sandbox violation"
        #expect(
            texts.contains(expected),
            "Diagnostics tab must show '\(expected)', texts: \(texts)")
    }

    @Test("diagnostics tab shows lint engine error even when diagnostics list is non-empty")
    func lintErrorTakesPrecedenceOverDiags() {
        var (state, _) = loadedState()
        state.lintState = .failed("init crash")
        state.bottomPane.diagnostics = [
            Diagnostic(severity: .warning, line: 1, message: "unused var", source: .luacheck)
        ]
        state.bottomPane.activeTab = .diagnostics
        let cmds = render(state, size: minSize())
        let texts = paragraphTexts(cmds)
        #expect(
            texts.contains("✖ Lint engine error: init crash"),
            "Lint engine error must override normal lint results, texts: \(texts)")
        #expect(
            !texts.contains { $0.contains("unused var") },
            "Normal lint results must not appear when engine failed, texts: \(texts)")
    }

    @Test("l while lint engine failed: transient shown, no .lint effect")
    func lWhenLintFailed() {
        var (state, _) = loadedState()
        state.lintState = .failed("crash")
        let (next, effects) = reduce(state, .key(.char("l"), modifiers: []))
        let hasLint = effects.contains {
            if case .lint = $0 { return true }
            return false
        }
        #expect(!hasLint, "l must not emit .lint when lint engine is failed")
        #expect(next.transient != nil, "l must produce transient when lint engine is failed")
    }
}

// MARK: - Lua engine error / RunOutcome.engineError (ux-spec §4.2)

@Suite("Degraded — Lua engine error / RunOutcome.engineError (ux-spec §4.2)")
struct LuaEngineErrorTests {

    @Test("buildRunFooter returns exact ux-spec §4.2 string for .engineError")
    func footerFormat() {
        let footer = buildRunFooter(outcome: .engineError("state corruption"))
        #expect(
            footer == "✖ Engine error: state corruption",
            "Expected '✖ Engine error: state corruption', got: '\(footer)'")
    }

    @Test("buildRunFooter empty message: still emits '✖ Engine error: '")
    func footerEmptyMessage() {
        let footer = buildRunFooter(outcome: .engineError(""))
        #expect(
            footer == "✖ Engine error: ",
            "Expected '✖ Engine error: ', got: '\(footer)'")
    }

    @Test("runFinished(.engineError) sets runState to .completed(.engineError)")
    func reducerSetsCompletedState() {
        let (next, _) = reduce(AppState(), .runFinished(.engineError("crash")))
        if case .completed(let outcome) = next.runState,
            case .engineError(let msg) = outcome
        {
            #expect(msg == "crash")
        } else {
            Issue.record("runState must be .completed(.engineError) after .runFinished(.engineError)")
        }
    }

    @Test("RunOutcome.engineError Equatable: same message is equal")
    func equatableSameMessage() {
        #expect(RunOutcome.engineError("boom") == .engineError("boom"))
    }

    @Test("RunOutcome.engineError Equatable: different messages are not equal")
    func equatableDifferentMessages() {
        #expect(RunOutcome.engineError("a") != .engineError("b"))
    }

    @Test("RunOutcome.engineError Equatable: not equal to .cancelled")
    func equatableDistinctCase() {
        #expect(RunOutcome.engineError("x") != .cancelled)
    }
}

// MARK: - Unsupported Lua version (ux-spec §3.7)

@Suite("Degraded — Unsupported Lua version (ux-spec §3.7)")
struct UnsupportedVersionTests {

    @Test("status bar shows [Lua 5.3: unsupported] indicator")
    func statusBarIndicator() {
        let state = unsupportedVersionState()
        let cmds = render(state, size: minSize())
        let texts = cellRunTexts(cmds)
        let hasIndicator = texts.contains { $0.contains("[Lua 5.3: unsupported]") }
        #expect(
            hasIndicator,
            "Status bar must contain '[Lua 5.3: unsupported]', cellRun texts: \(texts)")
    }

    @Test("bottom pane shows persistent header '✖ Lua version ...' line")
    func bottomPanePersistentHeader() {
        let state = unsupportedVersionState()
        let cmds = render(state, size: minSize())
        let prefix = "✖ Lua version \"5.3\" is not supported."
        let hasHeader = hasCellRunStarting(prefix, in: cmds)
        #expect(
            hasHeader,
            "Bottom pane must show '\(prefix)…', cellRun texts: \(cellRunTexts(cmds))")
    }

    @Test("bottom pane header mentions Lua 5.4 only")
    func bottomPaneHeaderMentions54() {
        let state = unsupportedVersionState()
        let cmds = render(state, size: minSize())
        let texts = cellRunTexts(cmds)
        let hasFull = texts.contains { $0.contains("MoonSwift P1 supports Lua 5.4 only.") }
        #expect(hasFull, "Header must mention 'MoonSwift P1 supports Lua 5.4 only.', texts: \(texts)")
    }

    @Test("r is blocked when version unsupported: transient, no .run effect")
    func rIsBlocked() {
        var (state, _) = loadedState()
        state.project = .unsupportedVersion("5.3")
        let (next, effects) = reduce(state, .key(.char("r"), modifiers: []))
        let hasRun = effects.contains {
            if case .run = $0 { return true }
            return false
        }
        #expect(!hasRun, "r must not emit .run for unsupported Lua version")
        #expect(next.transient != nil, "r must produce a transient for unsupported version")
    }

    @Test("l is blocked when version unsupported: transient, no .lint effect")
    func lIsBlocked() {
        var (state, _) = loadedState()
        state.project = .unsupportedVersion("5.3")
        let (next, effects) = reduce(state, .key(.char("l"), modifiers: []))
        let hasLint = effects.contains {
            if case .lint = $0 { return true }
            return false
        }
        #expect(!hasLint, "l must not emit .lint for unsupported Lua version")
        #expect(next.transient != nil, "l must produce a transient for unsupported version")
    }

    @Test("r transient for unsupported version matches ux-spec §3.7 exact text")
    func rTransientText() {
        var (state, _) = loadedState()
        state.project = .unsupportedVersion("5.3")
        let (next, _) = reduce(state, .key(.char("r"), modifiers: []))
        let expected = "Run disabled: unsupported Lua version. Edit moonswift.toml and press <C-r>."
        #expect(
            next.transient?.text == expected,
            "r transient text must match ux-spec §3.7 exactly, got: \(next.transient?.text ?? "nil")")
    }

    @Test("l transient for unsupported version matches ux-spec §3.7 exact text")
    func lTransientText() {
        var (state, _) = loadedState()
        state.project = .unsupportedVersion("5.3")
        let (next, _) = reduce(state, .key(.char("l"), modifiers: []))
        let expected = "Lint disabled: unsupported Lua version. Edit moonswift.toml and press <C-r>."
        #expect(
            next.transient?.text == expected,
            "l transient text must match ux-spec §3.7 exactly, got: \(next.transient?.text ?? "nil")")
    }

    @Test("unsupported version 5.3 label appears correctly in header")
    func versionLabelInHeader() {
        var state = AppState()
        state.project = .unsupportedVersion("5.3")
        let cmds = render(state, size: minSize())
        let texts = cellRunTexts(cmds)
        #expect(
            texts.contains { $0.contains("\"5.3\"") },
            "Header must quote the version number, texts: \(texts)")
    }
}
