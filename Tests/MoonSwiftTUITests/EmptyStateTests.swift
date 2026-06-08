// File: Tests/MoonSwiftTUITests/EmptyStateTests.swift
// Location: MoonSwiftTUITests/
// Role: Tests for the empty-state detection and project-initialisation form
//       (LaunchMode.empty + InitFormState, task 24).
//
//       Coverage:
//         1. Empty state entry: `i` in .empty opens init form + fires scan.
//         2. `i` in .empty while form already open is a no-op.
//         3. `i` in .quickFile shows transient, no form.
//         4. `i` in .project is a no-op (passes through to pane dispatch).
//         5. Init form: Tab cycles luaVersion → sourceFiles → luaVersion.
//         6. Init form: Enter on luaVersion advances to sourceFiles.
//         7. Init form: j/k move file list cursor.
//         8. Init form: Space toggles file selection.
//         9. Init form: Esc cancels, clears initFormState, restores navigator focus.
//        10. Init form: Enter on sourceFiles emits writeProjectFile effect.
//        11. projectDirectoryScanned populates candidate files, clears isScanning.
//        12. projectFileWritten success: closes form, transitions to .project, fires loadProject.
//        13. projectFileWritten error: leaves form open, shows transient.
//        14. Quick-file mode: `i` shows the correct transient text.
//
// Upstream: Reducer.swift, AppState.swift, AppEvent.swift, Effect.swift

import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - Helpers

/// Build a minimal empty-mode AppState (launch = .empty, navigator focus).
private func emptyModeState() -> AppState {
    AppState(launch: .empty)
}

/// Build a quick-file AppState.
private func quickFileState() -> AppState {
    let url = URL(fileURLWithPath: "/tmp/script.lua")
    return AppState(launch: .quickFile(url))
}

/// Build a project-mode AppState.
private func projectState() -> AppState {
    let dir = URL(fileURLWithPath: "/tmp/myproject")
    return AppState(launch: .project(dir))
}

/// Return true if any effect is .scanProjectDirectory.
private func hasScanEffect(_ effects: [Effect]) -> Bool {
    effects.contains {
        if case .scanProjectDirectory = $0 { return true }
        return false
    }
}

/// Return true if any effect is .writeProjectFile.
private func hasWriteEffect(_ effects: [Effect]) -> Bool {
    effects.contains {
        if case .writeProjectFile = $0 { return true }
        return false
    }
}

/// Return the .writeProjectFile effect, if present.
private func writeEffect(from effects: [Effect]) -> Effect? {
    effects.first {
        if case .writeProjectFile = $0 { return true }
        return false
    }
}

/// Return true if any effect is .loadProject.
private func hasLoadProjectEffect(_ effects: [Effect]) -> Bool {
    effects.contains {
        if case .loadProject = $0 { return true }
        return false
    }
}

// MARK: - EmptyStateTests

@Suite("Empty state and init form (task 24)")
struct EmptyStateTests {

    // MARK: 1. i in empty state opens form and fires scan

    @Test("i in empty state opens init form with scanning flag and fires directory scan")
    func iKeyInEmptyStateOpensForm() {
        let state = emptyModeState()

        let (next, effects) = reduce(state, .key(.char("i"), modifiers: []))

        #expect(next.focus == .initForm, "Focus must be .initForm after pressing i")
        #expect(next.initFormState != nil, "initFormState must be set")
        #expect(next.initFormState?.isScanning == true, "Form must start in scanning state")
        #expect(next.initFormState?.luaVersion == "5.4", "Lua version pre-filled to 5.4")
        #expect(next.initFormState?.focusedField == .luaVersion, "First field is luaVersion")
        #expect(
            hasScanEffect(effects),
            "Must emit .scanProjectDirectory effect"
        )
    }

    // MARK: 2. i while form already open is a no-op

    @Test("i in empty state with form already open is a no-op")
    func iKeyWhenFormAlreadyOpen() {
        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState()

        let (next, effects) = reduce(state, .key(.char("i"), modifiers: []))

        #expect(next.focus == .initForm, "Focus must remain .initForm")
        #expect(!hasScanEffect(effects), "No scan when form already open")
    }

    // MARK: 3. i in quick-file mode shows transient, no form

    @Test("i in quick-file mode shows transient and does not open init form")
    func iKeyInQuickFileModeShowsTransient() {
        let state = quickFileState()

        let (next, effects) = reduce(state, .key(.char("i"), modifiers: []))

        #expect(next.initFormState == nil, "No form in quick-file mode")
        #expect(next.focus != .initForm, "Focus must not change to initForm")
        #expect(next.transient != nil, "A transient message must be shown")
        #expect(!hasScanEffect(effects), "No scan in quick-file mode")
    }

    // MARK: 4. Quick-file transient text is correct

    @Test("i in quick-file mode shows the expected transient message text")
    func iKeyQuickFileTransientText() {
        let state = quickFileState()
        let (next, _) = reduce(state, .key(.char("i"), modifiers: []))
        #expect(
            next.transient?.text == "No project: i unavailable in quick-file mode",
            "Transient text must match spec"
        )
    }

    // MARK: 5. i in project mode is a no-op (no global match → navigator dispatch)

    @Test("i in project mode does not open init form")
    func iKeyInProjectModeIsNoOp() {
        let state = projectState()

        let (next, effects) = reduce(state, .key(.char("i"), modifiers: []))

        // In .project mode reduceInitFormOpen returns nil, so the key falls
        // through to per-pane dispatch (navigator: no match → no-op).
        #expect(next.initFormState == nil, "No form in project mode")
        #expect(!hasScanEffect(effects), "No scan in project mode")
    }

    // MARK: 6. Tab cycles fields luaVersion → sourceFiles → luaVersion

    @Test("Tab cycles init form focus: luaVersion → sourceFiles → luaVersion")
    func tabCyclesFields() {
        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState(focusedField: .luaVersion)

        // Tab once: luaVersion → sourceFiles
        let (s1, _) = reduce(state, .key(.tab, modifiers: []))
        #expect(s1.initFormState?.focusedField == .sourceFiles)

        // Tab again: sourceFiles → luaVersion
        let (s2, _) = reduce(s1, .key(.tab, modifiers: []))
        #expect(s2.initFormState?.focusedField == .luaVersion)
    }

    // MARK: 7. Enter on luaVersion advances to sourceFiles

    @Test("Enter on luaVersion field advances to sourceFiles")
    func enterOnLuaVersionAdvances() {
        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState(focusedField: .luaVersion)

        let (next, effects) = reduce(state, .key(.enter, modifiers: []))

        #expect(next.initFormState?.focusedField == .sourceFiles)
        #expect(!hasWriteEffect(effects), "Enter on luaVersion must not write yet")
    }

    // MARK: 8. j/k move file list cursor

    @Test("j/k move file list cursor within bounds")
    func jkMoveCursor() {
        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState(
            candidateFiles: ["a.lua", "b.lua", "c.lua"],
            isScanning: false,
            focusedField: .sourceFiles,
            fileListCursor: 0
        )

        let (s1, _) = reduce(state, .key(.char("j"), modifiers: []))
        #expect(s1.initFormState?.fileListCursor == 1, "j moves cursor down")

        let (s2, _) = reduce(s1, .key(.char("j"), modifiers: []))
        #expect(s2.initFormState?.fileListCursor == 2, "j moves cursor down again")

        // Cursor does not go past last file.
        let (s3, _) = reduce(s2, .key(.char("j"), modifiers: []))
        #expect(s3.initFormState?.fileListCursor == 2, "j clamps at last file")

        // k moves up.
        let (s4, _) = reduce(s3, .key(.char("k"), modifiers: []))
        #expect(s4.initFormState?.fileListCursor == 1, "k moves cursor up")

        // k does not go past 0.
        let (s5, _) = reduce(s4, .key(.char("k"), modifiers: []))
        let (s6, _) = reduce(s5, .key(.char("k"), modifiers: []))
        #expect(s6.initFormState?.fileListCursor == 0, "k clamps at first file")
    }

    // MARK: 9. j/k are no-ops when field is luaVersion

    @Test("j/k do not move cursor when luaVersion field is focused")
    func jkNoOpOnLuaVersionField() {
        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState(
            candidateFiles: ["a.lua", "b.lua"],
            isScanning: false,
            focusedField: .luaVersion,
            fileListCursor: 0
        )

        let (s1, _) = reduce(state, .key(.char("j"), modifiers: []))
        #expect(s1.initFormState?.fileListCursor == 0, "j is no-op on luaVersion field")
    }

    // MARK: 10. Space toggles file selection

    @Test("Space toggles file selection on current cursor row")
    func spaceTogglesSelection() {
        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState(
            candidateFiles: ["a.lua", "b.lua"],
            isScanning: false,
            selectedFiles: [],
            focusedField: .sourceFiles,
            fileListCursor: 0
        )

        // Select a.lua
        let (s1, _) = reduce(state, .key(.char(" "), modifiers: []))
        #expect(s1.initFormState?.selectedFiles == ["a.lua"], "Space selects current file")

        // Deselect a.lua
        let (s2, _) = reduce(s1, .key(.char(" "), modifiers: []))
        #expect(s2.initFormState?.selectedFiles.isEmpty == true, "Space deselects current file")
    }

    // MARK: 11. Esc cancels init form

    @Test("Esc cancels init form, clears initFormState, restores navigator focus")
    func escCancelsForm() {
        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState(
            candidateFiles: ["a.lua"],
            isScanning: false,
            selectedFiles: ["a.lua"],
            focusedField: .sourceFiles
        )

        let (next, effects) = reduce(state, .key(.escape, modifiers: []))

        #expect(next.focus == .pane(.navigator), "Esc restores navigator focus")
        #expect(next.initFormState == nil, "Esc clears initFormState")
        #expect(!hasWriteEffect(effects), "Esc must not write project file")
    }

    // MARK: 12. Enter on sourceFiles emits writeProjectFile

    @Test("Enter on sourceFiles field emits writeProjectFile with selected sources")
    func enterOnSourceFilesConfirms() {
        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState(
            candidateFiles: ["a.lua", "b.lua"],
            isScanning: false,
            selectedFiles: ["a.lua", "b.lua"],
            focusedField: .sourceFiles,
            fileListCursor: 0
        )

        let (_, effects) = reduce(state, .key(.enter, modifiers: []))

        #expect(hasWriteEffect(effects), "Enter on sourceFiles must emit .writeProjectFile")

        // Verify the effect carries the right sources (sorted).
        if case .writeProjectFile(_, let luaVersion, let sources) = effects.first(where: {
            if case .writeProjectFile = $0 { return true }
            return false
        })! {
            #expect(luaVersion == "5.4")
            #expect(sources == ["a.lua", "b.lua"])
        }
    }

    // MARK: 13. Enter on sourceFiles with no selection still confirms

    @Test("Enter on sourceFiles with empty selection emits writeProjectFile with empty sources")
    func enterOnSourceFilesNoSelectionConfirms() {
        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState(
            candidateFiles: ["a.lua"],
            isScanning: false,
            selectedFiles: [],
            focusedField: .sourceFiles
        )

        let (_, effects) = reduce(state, .key(.enter, modifiers: []))

        #expect(hasWriteEffect(effects), "Enter with no selection still confirms")
        if case .writeProjectFile(_, _, let sources) = effects.first(where: {
            if case .writeProjectFile = $0 { return true }
            return false
        })! {
            #expect(sources.isEmpty, "No selected files → empty sources array")
        }
    }

    // MARK: 14. projectDirectoryScanned populates candidate files

    @Test("projectDirectoryScanned populates candidate files and clears isScanning")
    func projectDirectoryScannedPopulatesFiles() {
        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState(isScanning: true)

        let files = ["foo.lua", "bar.json", "baz.yaml"]
        let (next, _) = reduce(state, .projectDirectoryScanned(files))

        #expect(next.initFormState?.candidateFiles == files)
        #expect(next.initFormState?.isScanning == false)
    }

    // MARK: 15. projectDirectoryScanned when form closed is a no-op

    @Test("projectDirectoryScanned when initFormState is nil is a no-op")
    func projectDirectoryScannedNoForm() {
        let state = emptyModeState()
        // form not open — initFormState == nil

        let (next, _) = reduce(state, .projectDirectoryScanned(["a.lua"]))
        #expect(next.initFormState == nil, "No-op when form is not open")
    }

    // MARK: 16. projectFileWritten success transitions app state

    @Test("projectFileWritten success closes form, sets launch to .project, emits loadProject")
    func projectFileWrittenSuccess() {
        let projectDir = URL(fileURLWithPath: "/tmp/myproject")
        let projectFileURL = projectDir.appendingPathComponent("moonswift.toml")

        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState(isScanning: false)

        let (next, effects) = reduce(
            state,
            .projectFileWritten(projectURL: projectFileURL, error: nil)
        )

        #expect(next.initFormState == nil, "Form must be closed on success")
        #expect(next.focus == .pane(.navigator), "Focus returns to navigator")

        if case .project(let dir) = next.launch {
            // URL(fileURLWithPath:) produces no trailing slash on a plain path,
            // but deletingLastPathComponent() on a file URL does add one.
            // Compare canonical POSIX paths to normalise both sides.
            #expect(
                dir.path.trimmingCharacters(in: ["/"])
                    == projectDir.path.trimmingCharacters(in: ["/"]),
                "Launch mode must become .project with the project dir"
            )
        } else {
            Issue.record("launch mode not .project after write success")
        }

        #expect(hasLoadProjectEffect(effects), "Must emit .loadProject effect")
    }

    // MARK: 17. projectFileWritten error shows transient, leaves form open

    @Test("projectFileWritten error shows transient and leaves form open")
    func projectFileWrittenError() {
        var state = emptyModeState()
        state.focus = .initForm
        state.initFormState = InitFormState(isScanning: false)

        let (next, _) = reduce(
            state,
            .projectFileWritten(projectURL: nil, error: "disk full")
        )

        #expect(next.initFormState != nil, "Form must remain open on error")
        #expect(next.focus == .initForm, "Focus must remain in init form")
        #expect(next.transient != nil, "Transient must be shown on error")
        #expect(
            next.transient?.text.contains("disk full") == true,
            "Transient must include the error message"
        )
    }
}
