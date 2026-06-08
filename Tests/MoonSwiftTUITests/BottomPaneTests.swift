// File: Tests/MoonSwiftTUITests/BottomPaneTests.swift
// Location: MoonSwiftTUITests/
// Role: Tests for the bottom pane — tab switching, FIFO buffer management,
//       run header/footer format strings, [cleared] notices, diagnostic
//       rendering, yank, jump, and auto-switch behaviour. Pure reducer and
//       renderer tests; no FFI dependency.
// Upstream: Reducer.swift, AppState.swift, AppEvent.swift, Renderer.swift
// Downstream: (test target)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Shared helpers

/// Returns a `LuaSourceFragment` for use in tests.
private func makeFragment(code: String = "print()", path: String = "/project/test.lua") -> LuaSourceFragment {
    let url = URL(fileURLWithPath: path)
    let data = Data(code.utf8)
    let hash = SHA256.hash(data: data)
    let prov = FragmentProvenance(
        file: url,
        jsonpath: nil,
        document: 0,
        byteRange: 0..<data.count,
        lineOffset: 0,
        contentHash: hash
    )
    return LuaSourceFragment(code: code, provenance: prov)
}

/// Returns an `AppState` with a loaded source and lint engine idle,
/// suitable for run/lint sequence tests.
private func loadedState(
    code: String = "print()",
    path: String = "/project/test.lua"
) -> (AppState, SourceID) {
    let id = SourceID(path: "test.lua")
    var state = AppState()
    let fragment = makeFragment(code: code, path: path)
    state.sources[id] = .loaded(fragment)
    state.navigatorOrder = [id]
    state.selection = id
    state.lintState = .idle
    state.project = .loaded(ProjectFile(luaVersion: "5.4"), diagnostics: [])
    return (state, id)
}

private func termSize(_ cols: UInt16, _ rows: UInt16) -> TerminalSize {
    TerminalSize(cols: cols, rows: rows)
}

// MARK: - FIFO buffer tests (ux-spec §6.4)

@Suite("BottomPane — FIFO buffer (ux-spec §6.4)")
struct FIFOBufferTests {

    @Test("appendOutputLines enforces 1000-line cap without overflow")
    func appendBelowCap() {
        var bp = BottomPaneState()
        bp.appendOutputLines(Array(repeating: "x", count: 500))
        #expect(bp.outputBuffer.count == 500)
        let hasNotice = bp.outputBuffer.contains { $0.hasPrefix("[cleared") }
        #expect(!hasNotice, "No notice expected below cap")
    }

    @Test("appendOutputLines at exactly 1000 lines — no overflow, no notice")
    func appendExactlyCap() {
        var bp = BottomPaneState()
        bp.appendOutputLines(Array(repeating: "x", count: 1_000))
        #expect(bp.outputBuffer.count == 1_000)
        let hasNotice = bp.outputBuffer.contains { $0.hasPrefix("[cleared") }
        #expect(!hasNotice, "No notice expected at exactly cap")
    }

    @Test("appendOutputLines overflow: oldest lines evicted, notice inserted")
    func appendOverflowInsertsNotice() {
        var bp = BottomPaneState()
        bp.appendOutputLines(Array(repeating: "x", count: 999))
        // Adding 5 lines overflows by 4: 999 + 5 = 1004 → evict 5 (excess+1), keep 1000.
        bp.appendOutputLines(["a", "b", "c", "d", "e"])
        // Buffer must be capped at 1000.
        #expect(bp.outputBuffer.count == 1_000)
        // Last line must be "e".
        #expect(bp.outputBuffer.last == "e")
        // Notice must be present in buffer (at index 0 after eviction).
        let hasNotice = bp.outputBuffer.contains { $0.hasPrefix("[cleared —") }
        #expect(hasNotice, "FIFO overflow must insert '[cleared — N lines discarded]' notice")
    }

    @Test("FIFO notice format exactly matches ux-spec §6.4")
    func overflowNoticeExactFormat() {
        var bp = BottomPaneState()
        // 1000 lines → add 3 → overflow by 3: excess=3, evicted=4 (excess+1).
        // removeFirst(4), insert notice → 1000 total.
        bp.appendOutputLines(Array(repeating: "old", count: 1_000))
        bp.appendOutputLines(["new1", "new2", "new3"])
        // Check the first line is the correctly formatted notice.
        guard let firstLine = bp.outputBuffer.first else {
            Issue.record("Buffer must not be empty after overflow")
            return
        }
        // excess=3, evicted=4 → "[cleared — 4 lines discarded]"
        #expect(
            firstLine == "[cleared — 4 lines discarded]",
            "FIFO notice must be '[cleared — N lines discarded]' where N = evicted count, got: \(firstLine)")
    }

    @Test("clearOutputWithNotice inserts [cleared] notice and resets scroll")
    func clearWithNoticeInsertsNotice() {
        var bp = BottomPaneState()
        bp.appendOutputLines(["line1", "line2", "line3"])
        bp.scrollOffset = 2

        bp.clearOutputWithNotice()

        #expect(bp.outputBuffer.count == 1)
        #expect(
            bp.outputBuffer.first == "[cleared]",
            "Manual C-l clear must insert '[cleared]' notice (ux-spec §6.4)")
        #expect(bp.scrollOffset == 0, "Clear must reset scroll offset")
    }

    @Test("C-l key in bottom pane clears output buffer with notice")
    func ctrlLClearsWithNotice() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.outputBuffer = ["line1", "line2", "line3"]
        state.bottomPane.scrollOffset = 1

        let (next, _) = reduce(state, .key(.char("l"), modifiers: .ctrl))

        #expect(next.bottomPane.outputBuffer.count == 1)
        #expect(next.bottomPane.outputBuffer.first == "[cleared]")
        #expect(next.bottomPane.scrollOffset == 0)
        #expect(next.focus == .pane(.bottomPane), "Focus must remain on bottom pane after C-l")
    }
}

// MARK: - Run tracking tests (ux-spec §6.3)

@Suite("BottomPane — Run tracking (ux-spec §6.3)")
struct RunTrackingTests {

    @Test("startRun increments runNumber and stores startTime")
    func startRunIncrementsCounter() {
        var bp = BottomPaneState()
        #expect(bp.runNumber == 0)
        #expect(bp.runStartTime == nil)

        let t1 = Date()
        bp.startRun(at: t1)
        #expect(bp.runNumber == 1)
        #expect(bp.runStartTime == t1)

        let t2 = Date()
        bp.startRun(at: t2)
        #expect(bp.runNumber == 2)
        #expect(bp.runStartTime == t2)
    }

    @Test("r key increments runNumber each time")
    func rKeyIncrementsRunNumber() {
        let (state, _) = loadedState()

        let (s1, _) = reduce(state, .key(.char("r"), modifiers: []))
        #expect(s1.bottomPane.runNumber == 1)

        // Simulate run finishing so a second r is allowed.
        let (s2, _) = reduce(s1, .runFinished(.done(value: nil, duration: .milliseconds(10))))
        let (s3, _) = reduce(s2, .key(.char("r"), modifiers: []))
        #expect(s3.bottomPane.runNumber == 2)
    }

    @Test("r key auto-switches bottom pane to Output tab")
    func rKeyAutoSwitchesToOutput() {
        let (state, _) = loadedState()
        var s = state
        s.bottomPane.activeTab = .diagnostics

        let (next, _) = reduce(s, .key(.char("r"), modifiers: []))
        #expect(next.bottomPane.activeTab == .output)
    }

    @Test("l key auto-switches bottom pane to Diagnostics tab")
    func lKeyAutoSwitchesToDiagnostics() {
        let (state, _) = loadedState()
        var s = state
        s.bottomPane.activeTab = .output

        let (next, _) = reduce(s, .key(.char("l"), modifiers: []))
        #expect(next.bottomPane.activeTab == .diagnostics)
    }
}

// MARK: - Run header format tests (ux-spec §6.3, §6.8)

@Suite("BottomPane — Run header format (ux-spec §6.3, §6.8)")
struct RunHeaderFormatTests {

    /// A fixed timestamp: 2024-03-15 14:30:45 UTC, formatted as 14:30:45.
    private var fixedDate: Date {
        var comps = DateComponents()
        comps.year = 2024
        comps.month = 3
        comps.day = 15
        comps.hour = 14
        comps.minute = 30
        comps.second = 45
        comps.timeZone = TimeZone.current
        return Calendar.current.date(from: comps) ?? Date()
    }

    @Test("Width ≥ 80: full format ── Run N · HH:MM:SS ──")
    func fullFormat() {
        let header = buildRunHeader(runNumber: 3, startTime: fixedDate, width: 80)
        // Extract the timestamp portion — hour depends on local timezone in test.
        #expect(header.hasPrefix("── Run 3 · "), "Header must start with '── Run 3 · '")
        #expect(header.hasSuffix(" ──"), "Header must end with ' ──'")
        // Timestamp portion must be HH:MM:SS (8 chars).
        let parts = header.components(separatedBy: " · ")
        #expect(parts.count == 2)
        let tsPart = parts[1].replacingOccurrences(of: " ──", with: "")
        #expect(tsPart.count == 8, "Full timestamp must be HH:MM:SS (8 chars), got '\(tsPart)'")
        // Must match HH:MM:SS pattern.
        let tsRe = try? NSRegularExpression(pattern: "^\\d{2}:\\d{2}:\\d{2}$")
        let match = tsRe?.firstMatch(in: tsPart, range: NSRange(tsPart.startIndex..., in: tsPart))
        #expect(match != nil, "Timestamp must match HH:MM:SS pattern")
    }

    @Test("Width 60–79: HH:MM format ── Run N · HH:MM ──")
    func hmFormat() {
        let header = buildRunHeader(runNumber: 1, startTime: fixedDate, width: 60)
        #expect(header.hasPrefix("── Run 1 · "))
        #expect(header.hasSuffix(" ──"))
        let parts = header.components(separatedBy: " · ")
        let tsPart = parts[1].replacingOccurrences(of: " ──", with: "")
        #expect(tsPart.count == 5, "HH:MM timestamp must be 5 chars, got '\(tsPart)'")
    }

    @Test("Width 40–59: run-only format ── Run N ──")
    func runOnlyFormat() {
        let header = buildRunHeader(runNumber: 7, startTime: fixedDate, width: 40)
        #expect(header == "── Run 7 ──", "Width ≥ 40 must produce '── Run N ──', got '\(header)'")
    }

    @Test("Width < 40: compact format ──N──")
    func compactFormat() {
        let header = buildRunHeader(runNumber: 12, startTime: fixedDate, width: 39)
        #expect(header == "──12──", "Width < 40 must produce '──N──', got '\(header)'")
    }

    @Test("Width exactly 40: run-only format ── Run N ──")
    func exactlyWidth40() {
        let header = buildRunHeader(runNumber: 1, startTime: fixedDate, width: 40)
        #expect(header == "── Run 1 ──")
    }

    @Test("Width exactly 60: HH:MM format")
    func exactlyWidth60() {
        let header = buildRunHeader(runNumber: 1, startTime: fixedDate, width: 60)
        #expect(header.contains(" · "), "Width 60 must use · separator")
        let parts = header.components(separatedBy: " · ")
        let ts = parts[1].replacingOccurrences(of: " ──", with: "")
        #expect(ts.count == 5)
    }

    @Test("Width exactly 80: full HH:MM:SS format")
    func exactlyWidth80() {
        let header = buildRunHeader(runNumber: 1, startTime: fixedDate, width: 80)
        let parts = header.components(separatedBy: " · ")
        let ts = parts[1].replacingOccurrences(of: " ──", with: "")
        #expect(ts.count == 8)
    }
}

// MARK: - Run footer format tests (ux-spec §6.3)

@Suite("BottomPane — Run footer format (ux-spec §6.3)")
struct RunFooterFormatTests {

    @Test("done outcome: 'done — Xms'")
    func doneFooter() {
        let outcome = RunOutcome.done(value: nil, duration: .milliseconds(42))
        let footer = buildRunFooter(outcome: outcome)
        #expect(footer == "done — 42ms", "Done footer must be 'done — Xms', got '\(footer)'")
    }

    @Test("done outcome with zero duration: 'done — 0ms'")
    func doneZeroDuration() {
        let outcome = RunOutcome.done(value: nil, duration: .zero)
        let footer = buildRunFooter(outcome: outcome)
        #expect(footer == "done — 0ms")
    }

    @Test("error outcome with line: 'error — <msg> → jump to line N'")
    func errorFooterWithLine() {
        let diag = Diagnostic(severity: .error, line: 7, message: "attempt to index nil", source: .runtime)
        let outcome = RunOutcome.error(diag, traceback: [])
        let footer = buildRunFooter(outcome: outcome)
        #expect(
            footer == "error — attempt to index nil → jump to line 7",
            "Error footer must include '→ jump to line N', got '\(footer)'")
    }

    @Test("error outcome with line 0: no jump affordance")
    func errorFooterNoLine() {
        let diag = Diagnostic(severity: .error, line: 0, message: "engine error", source: .runtime)
        let outcome = RunOutcome.error(diag, traceback: [])
        let footer = buildRunFooter(outcome: outcome)
        #expect(footer == "error — engine error", "Error with line 0 must not include jump affordance")
    }

    @Test("cancelled outcome: 'cancelled'")
    func cancelledFooter() {
        let footer = buildRunFooter(outcome: .cancelled)
        #expect(footer == "cancelled")
    }

    @Test("instructions limit: 'instruction limit exceeded (N instructions)' (ux-spec §6.3)")
    func instructionsLimitFooter() {
        let footer = buildRunFooter(outcome: .limitExceeded(kind: .instructions(count: 1_000)))
        #expect(footer == "instruction limit exceeded (1000 instructions)")
    }

    @Test("wall-clock limit: 'wall-clock limit exceeded (Xms)' (ux-spec §6.3)")
    func wallClockLimitFooter() {
        let footer = buildRunFooter(outcome: .limitExceeded(kind: .wallClock(durationMs: 5_000)))
        #expect(footer == "wall-clock limit exceeded (5000ms)")
    }
}

// MARK: - Diagnostic line format tests (ux-spec §6.5)

@Suite("BottomPane — Diagnostic line format (ux-spec §6.5)")
struct DiagnosticLineFormatTests {

    @Test("Error with line + col + code: 'E line:col message [code]'")
    func errorWithAllFields() {
        let d = Diagnostic(
            severity: .error, line: 5, column: 12, code: "113", message: "undefined global 'x'", source: .luacheck)
        let text = formatDiagnosticLine(d)
        #expect(
            text == "E 5:12 undefined global 'x' [113]",
            "Full diagnostic format, got '\(text)'")
    }

    @Test("Warning with line, no col, no code: 'W line message'")
    func warningNoColNoCode() {
        let d = Diagnostic(
            severity: .warning, line: 3, column: nil, code: nil, message: "unused var", source: .luacheck)
        let text = formatDiagnosticLine(d)
        #expect(text == "W 3 unused var", "Warning without col/code, got '\(text)'")
    }

    @Test("Error with col but no code: 'E line:col message'")
    func errorWithColNoCode() {
        let d = Diagnostic(
            severity: .error, line: 10, column: 5, code: nil, message: "syntax error", source: .syntaxPrePass)
        let text = formatDiagnosticLine(d)
        #expect(text == "E 10:5 syntax error")
    }

    @Test("Warning with code but no col: 'W line message [code]'")
    func warningWithCodeNoCol() {
        let d = Diagnostic(
            severity: .warning, line: 1, column: nil, code: "211", message: "unused local var", source: .luacheck)
        let text = formatDiagnosticLine(d)
        #expect(text == "W 1 unused local var [211]")
    }

    @Test("E/W prefix matches severity")
    func prefixMatchesSeverity() {
        let err = Diagnostic(severity: .error, line: 1, message: "err", source: .luacheck)
        let warn = Diagnostic(severity: .warning, line: 1, message: "warn", source: .luacheck)
        #expect(formatDiagnosticLine(err).hasPrefix("E "))
        #expect(formatDiagnosticLine(warn).hasPrefix("W "))
    }
}

// MARK: - Diagnostics tab renderer tests (ux-spec §6.5)

@Suite("BottomPane — Diagnostics tab renderer (ux-spec §6.5)")
struct DiagnosticsTabRendererTests {

    /// Returns render commands for the diagnostics tab with the given state.
    private func renderDiags(state: AppState) -> [RenderCommand] {
        let size = termSize(120, 40)
        var s = state
        s.focus = .pane(.bottomPane)
        s.bottomPane.activeTab = .diagnostics
        let commands = render(s, size: size)
        return commands
    }

    /// Collects all span text from every `.paragraph` command in the frame.
    ///
    /// The renderer emits multiple `.paragraph` commands per frame (code pane,
    /// bottom pane content, help overlay). Collecting all span text and
    /// searching it for diagnostic strings is the correct approach because the
    /// bottom pane paragraph is not the first one in the command sequence.
    private func allParagraphText(from commands: [RenderCommand]) -> [String] {
        commands.compactMap { cmd -> [[Span]]? in
            if case .paragraph(_, let lines, _) = cmd { return lines }
            return nil
        }.flatMap { $0 }.flatMap { $0.map { $0.text } }
    }

    @Test("Empty state: 'No diagnostics.' shown (ux-spec §6.5)")
    func emptyStateNoDiagnostics() {
        var state = AppState()
        state.bottomPane.prePassDiagnostic = nil
        state.bottomPane.diagnostics = []

        let commands = renderDiags(state: state)
        let lines = allParagraphText(from: commands)
        let combined = lines.joined()
        #expect(
            combined.contains("No diagnostics."),
            "Empty diagnostics tab must show 'No diagnostics.', got: \(lines)")
    }

    @Test("Syntax section header is '── Syntax ──' (ux-spec §6.5)")
    func syntaxSectionHeader() {
        var state = AppState()
        // Trigger section rendering by having any result.
        state.bottomPane.prePassDiagnostic = Diagnostic(
            severity: .error, line: 1, message: "err", source: .syntaxPrePass)

        let commands = renderDiags(state: state)
        let lines = allParagraphText(from: commands)
        #expect(
            lines.contains("── Syntax ──"),
            "Diagnostics tab must show '── Syntax ──' header, found: \(lines)")
    }

    @Test("Lint section header is '── Lint ──' (ux-spec §6.5)")
    func lintSectionHeader() {
        var state = AppState()
        state.bottomPane.diagnostics = [
            Diagnostic(severity: .warning, line: 1, message: "w", source: .luacheck)
        ]

        let commands = renderDiags(state: state)
        let lines = allParagraphText(from: commands)
        #expect(
            lines.contains("── Lint ──"),
            "Diagnostics tab must show '── Lint ──' header, found: \(lines)")
    }

    @Test("Clean pre-pass shows '✔ No syntax errors.' (ux-spec §6.5)")
    func cleanPrePassNoErrors() {
        var state = AppState()
        state.bottomPane.prePassDiagnostic = nil
        state.bottomPane.diagnostics = [
            Diagnostic(severity: .warning, line: 2, message: "w", source: .luacheck)
        ]

        let commands = renderDiags(state: state)
        let lines = allParagraphText(from: commands)
        #expect(
            lines.contains("✔ No syntax errors."),
            "Clean pre-pass must show '✔ No syntax errors.', found: \(lines)")
    }

    @Test("Clean lint shows '✔ No issues found.' (ux-spec §6.5)")
    func cleanLintNoIssues() {
        var state = AppState()
        state.bottomPane.prePassDiagnostic = Diagnostic(
            severity: .error, line: 1, message: "err", source: .syntaxPrePass)
        state.bottomPane.diagnostics = []

        let commands = renderDiags(state: state)
        let lines = allParagraphText(from: commands)
        #expect(
            lines.contains("✔ No issues found."),
            "Empty lint must show '✔ No issues found.', found: \(lines)")
    }

    @Test("Diagnostics sorted by line number in Lint section")
    func diagnosticsSortedByLine() {
        var state = AppState()
        state.bottomPane.diagnostics = [
            Diagnostic(severity: .error, line: 10, message: "err10", source: .luacheck),
            Diagnostic(severity: .warning, line: 2, message: "warn2", source: .luacheck),
            Diagnostic(severity: .error, line: 5, message: "err5", source: .luacheck),
        ]

        let commands = renderDiags(state: state)
        let lines = allParagraphText(from: commands)
        // Find the lint section lines (after '── Lint ──')
        var lintLines: [String] = []
        var inLint = false
        for line in lines {
            if line == "── Lint ──" {
                inLint = true
                continue
            }
            if inLint { lintLines.append(line) }
        }
        #expect(lintLines.count == 3)
        #expect(lintLines[0].contains("2"), "First lint line must be line 2")
        #expect(lintLines[1].contains("5"), "Second lint line must be line 5")
        #expect(lintLines[2].contains("10"), "Third lint line must be line 10")
    }
}

// MARK: - Tab bar renderer tests (ux-spec §6.1)

@Suite("BottomPane — Tab bar renderer (ux-spec §6.1)")
struct TabBarRendererTests {

    @Test("Tab bar row emits cell runs containing '[ Output ]' and '[ Diagnostics ]'")
    func tabLabelsPresent() {
        let state = AppState()
        let commands = render(state, size: termSize(120, 30))
        let cellTexts = commands.compactMap { cmd -> String? in
            if case .cellRun(_, _, let text, _) = cmd { return text }
            return nil
        }
        #expect(
            cellTexts.contains("[ Output ]"),
            "Tab bar must emit '[ Output ]' cell run, found: \(cellTexts)")
        #expect(
            cellTexts.contains("[ Diagnostics ]"),
            "Tab bar must emit '[ Diagnostics ]' cell run, found: \(cellTexts)")
    }

    @Test("Active tab '[ Output ]' has underline modifier set")
    func outputTabActiveHasUnderline() {
        var state = AppState()
        state.bottomPane.activeTab = .output
        // Seed a theme with focusBorder token so underline style resolves.
        state.theme = ThemeState(
            name: "default",
            capability: .truecolor,
            tokens: [
                .focusBorder: TokenStyle(underline: true),
                .paneBg: TokenStyle(),
                .dim: TokenStyle(),
            ]
        )
        let commands = render(state, size: termSize(120, 30))
        let outputRun = commands.first {
            if case .cellRun(_, _, "[ Output ]", _) = $0 { return true }
            return false
        }
        guard let activeRun = outputRun else {
            Issue.record("Must find a '[ Output ]' cell run")
            return
        }
        if case .cellRun(_, _, _, let style) = activeRun {
            // UNDERLINE bit = 0x0004
            #expect(style.mods & 0x0004 != 0, "Active tab must have UNDERLINE modifier")
        }
    }

    @Test("Active tab '[ Diagnostics ]' has underline modifier set")
    func diagnosticsTabActiveHasUnderline() {
        var state = AppState()
        state.bottomPane.activeTab = .diagnostics
        state.theme = ThemeState(
            name: "default",
            capability: .truecolor,
            tokens: [
                .focusBorder: TokenStyle(underline: true),
                .paneBg: TokenStyle(),
                .dim: TokenStyle(),
            ]
        )
        let commands = render(state, size: termSize(120, 30))
        let diagRun = commands.first {
            if case .cellRun(_, _, "[ Diagnostics ]", _) = $0 { return true }
            return false
        }
        guard let activeRun = diagRun else {
            Issue.record("Must find a '[ Diagnostics ]' cell run")
            return
        }
        if case .cellRun(_, _, _, let style) = activeRun {
            #expect(style.mods & 0x0004 != 0, "Active tab must have UNDERLINE modifier")
        }
    }
}

// MARK: - Yank tests (ux-spec §2.3)

@Suite("BottomPane — Yank (ux-spec §2.3)")
struct YankTests {

    @Test("y key emits .yank effect with focused output line text")
    func yKeyYanksOutputLine() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .output
        state.bottomPane.outputBuffer = ["first line", "second line", "third line"]
        state.bottomPane.scrollOffset = 1

        let (_, effects) = reduce(state, .key(.char("y"), modifiers: []))

        let yankEffect = effects.first {
            if case .yank = $0 { return true }
            return false
        }
        guard let yankEffect else {
            Issue.record("y key must emit .yank effect")
            return
        }
        if case .yank(let text) = yankEffect {
            #expect(text == "second line", "Yank must copy focused (scrollOffset=1) line, got '\(text)'")
        }
    }

    @Test("y key emits .yank effect with focused diagnostic line text")
    func yKeyYanksDiagnosticLine() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .diagnostics
        state.bottomPane.diagnostics = [
            Diagnostic(
                severity: .error, line: 5, column: 3, code: "113", message: "undefined global 'x'", source: .luacheck)
        ]
        state.bottomPane.scrollOffset = 0

        let (_, effects) = reduce(state, .key(.char("y"), modifiers: []))

        let yankEffect = effects.first {
            if case .yank = $0 { return true }
            return false
        }
        guard let yankEffect else {
            Issue.record("y key on diagnostics tab must emit .yank effect")
            return
        }
        if case .yank(let text) = yankEffect {
            #expect(
                text == "E 5:3 undefined global 'x' [113]",
                "Yank on diagnostics tab must use formatDiagnosticLine format, got '\(text)'")
        }
    }

    @Test("y key with empty buffer emits no effect")
    func yKeyEmptyBufferNoEffect() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .output
        state.bottomPane.outputBuffer = []

        let (_, effects) = reduce(state, .key(.char("y"), modifiers: []))

        let hasYank = effects.contains {
            if case .yank = $0 { return true }
            return false
        }
        #expect(!hasYank, "y key on empty buffer must not emit .yank effect")
    }

    @Test("y key out-of-range scroll offset emits no effect")
    func yKeyOutOfRangeNoEffect() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .output
        state.bottomPane.outputBuffer = ["only line"]
        state.bottomPane.scrollOffset = 5  // out of range

        let (_, effects) = reduce(state, .key(.char("y"), modifiers: []))

        let hasYank = effects.contains {
            if case .yank = $0 { return true }
            return false
        }
        #expect(!hasYank, "y key with out-of-range offset must not emit .yank effect")
    }
}

// MARK: - Jump code pane from bottom pane tests (ux-spec §3.5)

@Suite("BottomPane — Enter jump (ux-spec §3.5)")
struct EnterJumpTests {

    @Test("Enter in bottom pane sets code pane cursor and jumpPulseLine")
    func enterJumpsAndSetsPulse() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.diagnostics = [
            Diagnostic(severity: .error, line: 8, message: "err", source: .luacheck)
        ]
        state.bottomPane.scrollOffset = 0

        let (next, _) = reduce(state, .key(.enter, modifiers: []))

        // Code pane cursor must be placed at line 8 (1-based) → index 7 (0-based).
        #expect(next.codePane.cursorLine == 7)
        // scrollOffset centers the target: max(0, target - halfPageSize(10)) = 0.
        #expect(next.codePane.scrollOffset == 0)
        // jumpPulseLine must be set for the 500 ms highlight pulse hook (ux-spec §3.5).
        #expect(
            next.codePane.jumpPulseLine == 7,
            "Enter must set jumpPulseLine to trigger 500 ms highlight pulse")
    }

    @Test("Enter with empty diagnostics is a no-op")
    func enterEmptyDiagnosticsNoOp() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.diagnostics = []

        let (next, _) = reduce(state, .key(.enter, modifiers: []))
        #expect(next.codePane.cursorLine == 0)
        #expect(next.codePane.jumpPulseLine == nil)
    }
}

// MARK: - Tab switching tests (ux-spec §6.2)

@Suite("BottomPane — Tab switching (ux-spec §6.2)")
struct TabSwitchingTests {

    @Test("Tab key cycles Output → Diagnostics when bottom pane is focused")
    func tabCyclesOutputToDiag() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .output

        let (next, _) = reduce(state, .key(.tab, modifiers: []))
        #expect(next.bottomPane.activeTab == .diagnostics)
        #expect(next.bottomPane.scrollOffset == 0)
    }

    @Test("Tab at Diagnostics tab returns focus to navigator (ux-spec §6.2)")
    func tabAtLastTabReturnToNavigator() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .diagnostics

        let (next, _) = reduce(state, .key(.tab, modifiers: []))
        #expect(next.focus == .pane(.navigator))
    }

    @Test("1 quick-jumps to Output tab and resets scroll")
    func oneQuickJumpsToOutput() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .diagnostics
        state.bottomPane.scrollOffset = 10

        let (next, _) = reduce(state, .key(.char("1"), modifiers: []))
        #expect(next.bottomPane.activeTab == .output)
        #expect(next.bottomPane.scrollOffset == 0)
    }

    @Test("2 quick-jumps to Diagnostics tab and resets scroll")
    func twoQuickJumpsToDiagnostics() {
        var state = AppState()
        state.focus = .pane(.bottomPane)
        state.bottomPane.activeTab = .output
        state.bottomPane.scrollOffset = 5

        let (next, _) = reduce(state, .key(.char("2"), modifiers: []))
        #expect(next.bottomPane.activeTab == .diagnostics)
        #expect(next.bottomPane.scrollOffset == 0)
    }
}
