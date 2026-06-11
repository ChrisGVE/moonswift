// File: Tests/MoonSwiftTUITests/Nvim/AuditFixWaveBTests.swift
// Location: MoonSwiftTUITests/Nvim/
// Role: Targeted tests for the wave-B audit-fix CRs not already covered by
//       other suites:
//
//   CR-002  — non-UTF-8 bytes in an edited temp file must not silently produce
//             an empty string that overwrites the source. Verified at the POSIX
//             level (String(data:encoding:.utf8) returns nil for invalid bytes).
//
//   CR-011  — $EDITOR is split on whitespace so that "code -w" spawns `code`
//             with leading arg `-w`. Tested via the argument-construction logic
//             that maps editorComponents → leadingArgs + [url.path].
//
//   CR-022  — diffView [c] cancel restores .conflictModal(pending) exactly,
//             clearing pendingConflictModal in the process (reducer sequence).
//
// CR-003 (stdout write-end closed before shutdownReader) is already covered by
// NvimRPCClientTests.swift — every test there closes the write end first, and
// the "shutdownReader returns after stdout pipe is closed (EOF)" test exercises
// the ordering contract directly.
//
// CR-006 (syntaxPrePassBlocked outcome taxonomy) is covered by:
//   WriteBackCoordinatorTests.swift, WriteBackIntegrationTests.swift,
//   NvimDiffViewTests.swift.
//
// Relationships:
//   → AppDriver+NvimEffects.swift (CR-002 guard, CR-011 argv split)
//   → Reducer.swift (CR-022 reduceDiffViewKey [c] arm)
//   → AppState.swift (CR-022 pendingConflictModal field)
//   → NvimRPCClientTests.swift (CR-003 ordering — see above)

import CryptoKit
import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - CR-002: non-UTF-8 guard

/// CR-002b: when the edited file contains non-UTF-8 bytes,
/// `String(data:encoding:.utf8)` must return nil so the driver can surface an
/// `.ioFailure` rather than silently treating the content as an empty string.
///
/// This is a pure-logic POSIX-level test — it verifies the Swift stdlib
/// contract that the driver relies on for its guard-let, independent of the
/// driver's UI-thread-only lifecycle.
@Suite("CR-002 — non-UTF-8 guard (String init encoding contract)")
struct NonUTF8GuardTests {

    @Test("String(data:encoding:.utf8) returns nil for lone continuation byte 0x80")
    func loneContinuationByte() {
        let invalid = Data([0x80])
        let result = String(data: invalid, encoding: .utf8)
        #expect(result == nil, "0x80 is a lone continuation byte — must not decode as UTF-8")
    }

    @Test("String(data:encoding:.utf8) returns nil for truncated 2-byte sequence 0xC3")
    func truncatedTwoByteSequence() {
        // 0xC3 alone: start of a 2-byte sequence with no continuation byte.
        let invalid = Data([0xC3])
        let result = String(data: invalid, encoding: .utf8)
        #expect(result == nil, "Truncated 2-byte UTF-8 sequence must not decode")
    }

    @Test("String(data:encoding:.utf8) returns nil for overlong NUL 0xC0 0x80")
    func overlongNul() {
        // Overlong encoding of NUL — invalid in strict UTF-8 (RFC 3629).
        let invalid = Data([0xC0, 0x80])
        let result = String(data: invalid, encoding: .utf8)
        #expect(result == nil, "Overlong NUL 0xC0 0x80 is invalid UTF-8 — must not decode")
    }

    @Test("String(data:encoding:.utf8) succeeds for valid ASCII bytes")
    func validASCII() {
        let valid = Data("return 1\n".utf8)
        let result = String(data: valid, encoding: .utf8)
        #expect(result == "return 1\n", "Valid UTF-8 bytes must decode successfully")
    }

    @Test("String(data:encoding:.utf8) succeeds for valid multi-byte UTF-8 (emoji)")
    func validMultibyte() {
        // U+1F600 GRINNING FACE — 4-byte UTF-8 sequence F0 9F 98 80.
        let text = "local x = 1 -- 😀"
        let valid = Data(text.utf8)
        let result = String(data: valid, encoding: .utf8)
        #expect(result == text, "Valid multi-byte UTF-8 must decode correctly")
    }

    /// Verify that writing known non-UTF-8 bytes to a real temp file and reading
    /// them back still yields nil under .utf8 decoding. This exercises the I/O
    /// round-trip that the driver's guard-let covers.
    @Test("reading non-UTF-8 bytes from a temp file yields nil String(.utf8)")
    func tempFileRoundTrip() throws {
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cr002-test-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        // Write a 3-byte sequence that is invalid UTF-8 (lone high byte + two
        // arbitrary bytes that do not form a valid continuation).
        let invalidBytes = Data([0xFF, 0xFE, 0xFD])
        try invalidBytes.write(to: tmpURL, options: .atomic)

        let readBack = try Data(contentsOf: tmpURL)
        let decoded = String(data: readBack, encoding: .utf8)
        #expect(decoded == nil, "Non-UTF-8 bytes round-tripped through disk must not decode as UTF-8")
    }
}

// MARK: - CR-011: $EDITOR whitespace-split argv

/// CR-011: `$EDITOR` is split on whitespace so that values like `"code -w"` or
/// `"/usr/local/bin/vim --noplugin"` correctly produce a binary path plus
/// leading arguments that are prepended before the file path.
///
/// The logic under test (reproduced here as a pure function to avoid a TTY
/// dependency) is the same `split(separator:omittingEmptySubsequences:)` pattern
/// that `spawnEditorAndWait` uses to build `editorLeadingArgs`.
@Suite("CR-011 — $EDITOR whitespace-split argv construction")
struct EditorArgvSplitTests {

    // MARK: - Helper (mirrors the driver's argument construction)

    /// Reproduce the argv-construction logic from `spawnEditorAndWait` as a
    /// pure function so it can be tested without a live AppDriver or TTY.
    ///
    /// Returns `(binary, leadingArgs, fullArgv)` where `fullArgv` is what
    /// `Process.arguments` would be set to:  `leadingArgs + [filePath]`.
    private func buildArgv(
        editor: String,
        filePath: String
    ) -> (binary: String?, leadingArgs: [String], fullArgv: [String]) {
        let components =
            editor
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard let binary = components.first else {
            return (nil, [], [])
        }
        let leadingArgs = Array(components.dropFirst())
        return (binary, leadingArgs, leadingArgs + [filePath])
    }

    // MARK: - Tests

    @Test("bare binary produces empty leadingArgs and argv = [file]")
    func bareBinary() {
        let (binary, leading, argv) = buildArgv(editor: "/usr/bin/vi", filePath: "/tmp/x.lua")
        #expect(binary == "/usr/bin/vi")
        #expect(leading.isEmpty)
        #expect(argv == ["/tmp/x.lua"])
    }

    @Test("'code -w' splits into binary='code' and leadingArgs=['-w']")
    func codeWithWaitFlag() {
        let (binary, leading, argv) = buildArgv(editor: "/usr/local/bin/code -w", filePath: "/tmp/frag.lua")
        #expect(binary == "/usr/local/bin/code")
        #expect(leading == ["-w"])
        #expect(
            argv == ["-w", "/tmp/frag.lua"],
            "file path must be appended after leading args, not prepended")
    }

    @Test("'vim --noplugin -u NONE' produces two leading args in order")
    func vimMultipleLeadingArgs() {
        let (binary, leading, argv) = buildArgv(
            editor: "/usr/bin/vim --noplugin -u NONE",
            filePath: "/tmp/edit.lua"
        )
        #expect(binary == "/usr/bin/vim")
        #expect(leading == ["--noplugin", "-u", "NONE"])
        #expect(
            argv.first == "--noplugin",
            "first leading arg must precede the file path")
        #expect(
            argv.last == "/tmp/edit.lua",
            "file path must be the last element of argv")
    }

    @Test("leading/trailing whitespace is ignored (omittingEmptySubsequences)")
    func extraWhitespace() {
        let (binary, leading, argv) = buildArgv(
            editor: "  /usr/bin/nano  ",
            filePath: "/tmp/f.lua"
        )
        #expect(binary == "/usr/bin/nano")
        #expect(leading.isEmpty)
        #expect(argv == ["/tmp/f.lua"])
    }

    @Test("multiple spaces between binary and flag are collapsed")
    func multipleSpacesBetweenComponents() {
        let (binary, leading, argv) = buildArgv(
            editor: "/usr/bin/vim   -R",
            filePath: "/tmp/view.lua"
        )
        #expect(binary == "/usr/bin/vim")
        #expect(leading == ["-R"])
        #expect(argv == ["-R", "/tmp/view.lua"])
    }

    @Test("file path appears at the end of argv regardless of leading arg count")
    func fileIsAlwaysLast() {
        let filePath = "/Users/chris/project/frag.lua"
        let cases: [(editor: String, expectedArgvSuffix: String)] = [
            ("/usr/bin/vi", filePath),
            ("/usr/local/bin/code -w", filePath),
            ("/usr/bin/vim -u NONE --noplugin", filePath),
        ]
        for (editor, expectedLast) in cases {
            let (_, _, argv) = buildArgv(editor: editor, filePath: filePath)
            #expect(
                argv.last == expectedLast,
                "File path must be argv.last for EDITOR='\(editor)'")
        }
    }
}

// MARK: - CR-022: diffView [c] restores conflictModal

/// CR-022: pressing [c] in the diff view must restore `.conflictModal(pending)`
/// rather than transitioning to `.nvimPane`. The pending modal is stored in
/// `AppState.pendingConflictModal` when [d] transitions to `.diffView`, and
/// must be cleared once restored.
@Suite("CR-022 — diffView [c] restores pendingConflictModal")
struct DiffViewCancelRestoresModalTests {

    // MARK: - Test fixtures

    private func makeFragment(path: String = "/tmp/conflict.lua") -> LuaSourceFragment {
        let prov = FragmentProvenance(
            file: URL(fileURLWithPath: path), jsonpath: nil, document: 0,
            byteRange: 0..<9, lineOffset: 0, contentHash: SHA256.hash(data: Data()))
        return LuaSourceFragment(code: "return 1\n", provenance: prov)
    }

    private func makeModal(path: String = "/tmp/conflict.lua") -> ConflictModalState {
        ConflictModalState(
            fileURL: URL(fileURLWithPath: path),
            expectedHash: SHA256.hash(data: Data("original".utf8)),
            editedText: "return 99\n",
            fragment: makeFragment(path: path))
    }

    /// Build state that is in `.diffView(.ready(…))` with `pendingConflictModal` set.
    private func makeReadyDiffViewState(modal: ConflictModalState) -> AppState {
        let sid = SourceID(path: "conflict.lua")
        let diffState = DiffViewState(
            leftTitle: "On disk",
            rightTitle: "Edited",
            leftLines: ["return 1"],
            rightLines: ["return 99"],
            scrollOffset: 0
        )
        var s = AppState(
            sources: [sid: .loaded(makeFragment())],
            navigatorOrder: [sid], selection: sid,
            focus: .diffView(.ready(diffState)),
            terminalSize: TerminalSize(cols: 120, rows: 40))
        s.pendingConflictModal = modal
        return s
    }

    // MARK: - Tests

    @Test("[c] in diffView(.ready) transitions focus to .conflictModal(pending)")
    func cancelRestoresFocus() {
        let modal = makeModal()
        let s = makeReadyDiffViewState(modal: modal)

        let (next, _) = reduce(s, .key(.char("c"), modifiers: []))

        guard case .conflictModal(let restored) = next.focus else {
            Issue.record("Expected .conflictModal after [c], got \(next.focus)")
            return
        }
        #expect(
            restored.editedText == modal.editedText,
            "Restored modal must carry the same editedText")
        #expect(
            restored.fileURL == modal.fileURL,
            "Restored modal must carry the same fileURL")
    }

    @Test("[c] in diffView(.ready) clears pendingConflictModal")
    func cancelClearsPending() {
        let modal = makeModal()
        let s = makeReadyDiffViewState(modal: modal)

        let (next, _) = reduce(s, .key(.char("c"), modifiers: []))

        #expect(
            next.pendingConflictModal == nil,
            "pendingConflictModal must be nil after [c] restores the modal")
    }

    @Test("[c] in diffView(.ready) emits no effects")
    func cancelEmitsNoEffects() {
        let modal = makeModal()
        let s = makeReadyDiffViewState(modal: modal)

        let (_, effects) = reduce(s, .key(.char("c"), modifiers: []))

        #expect(effects.isEmpty, "[c] cancel in diffView must produce no effects")
    }

    @Test("[c] in diffView(.building) is absorbed — no state change")
    func cancelAbsorbedInBuilding() {
        let modal = makeModal()
        let sid = SourceID(path: "conflict.lua")
        var s = AppState(
            sources: [sid: .loaded(makeFragment())],
            navigatorOrder: [sid], selection: sid,
            focus: .diffView(.building),
            terminalSize: TerminalSize(cols: 120, rows: 40))
        s.pendingConflictModal = modal

        let (next, effects) = reduce(s, .key(.char("c"), modifiers: []))

        // While building, all input is absorbed — focus unchanged, effects empty.
        guard case .diffView(.building) = next.focus else {
            Issue.record("Focus must remain .diffView(.building) while diff is still building")
            return
        }
        #expect(effects.isEmpty, "No effects while diff is building")
    }

    /// When [d] is pressed in the conflict modal, `pendingConflictModal` must be
    /// set so that the subsequent [c] in the diff view can restore it.
    @Test("[d] in conflictModal sets pendingConflictModal before transitioning to diffView")
    func diffKeySetsPending() {
        let modal = makeModal()
        let sid = SourceID(path: "conflict.lua")
        let s = AppState(
            sources: [sid: .loaded(makeFragment())],
            navigatorOrder: [sid], selection: sid,
            focus: .conflictModal(modal),
            terminalSize: TerminalSize(cols: 120, rows: 40))

        let (next, _) = reduce(s, .key(.char("d"), modifiers: []))

        #expect(
            next.pendingConflictModal != nil,
            "[d] must set pendingConflictModal before transitioning to diffView")
        guard case .diffView(.building) = next.focus else {
            Issue.record("Expected .diffView(.building) after [d], got \(next.focus)")
            return
        }
    }

    /// Full round-trip: [d] sets pendingConflictModal + transitions to diffView;
    /// diff build completes; [c] restores the conflict modal and clears pending.
    @Test("round-trip [d] → diffViewReady → [c] restores conflictModal exactly")
    func fullRoundTrip() {
        let modal = makeModal()
        let sid = SourceID(path: "conflict.lua")
        let initial = AppState(
            sources: [sid: .loaded(makeFragment())],
            navigatorOrder: [sid], selection: sid,
            focus: .conflictModal(modal),
            terminalSize: TerminalSize(cols: 120, rows: 40))

        // Step 1: [d] transitions to diffView(.building), sets pendingConflictModal.
        let (afterD, _) = reduce(initial, .key(.char("d"), modifiers: []))
        #expect(afterD.pendingConflictModal != nil)

        // Step 2: diff build completes — simulate with diffViewReady.
        let diffState = DiffViewState(
            leftTitle: "On disk", rightTitle: "Edited",
            leftLines: ["context", "old"], rightLines: ["context", "new"],
            scrollOffset: 0
        )
        let (afterReady, _) = reduce(afterD, .diffViewReady(diffState))
        guard case .diffView(.ready) = afterReady.focus else {
            Issue.record("Expected .diffView(.ready) after diffViewReady event")
            return
        }

        // Step 3: [c] restores the conflict modal.
        let (afterC, _) = reduce(afterReady, .key(.char("c"), modifiers: []))
        guard case .conflictModal(let restored) = afterC.focus else {
            Issue.record("Expected .conflictModal after [c], got \(afterC.focus)")
            return
        }
        #expect(restored.editedText == modal.editedText)
        #expect(afterC.pendingConflictModal == nil)
    }
}
