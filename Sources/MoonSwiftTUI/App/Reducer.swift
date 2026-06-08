// File: Sources/MoonSwiftTUI/App/Reducer.swift
// Location: MoonSwiftTUI/App/
// Role: Pure (AppState, AppEvent) → (AppState, [Effect]) function. All state
//       transitions live here. The reducer dispatches to focused sub-reducers
//       for key events and handles service events centrally. No I/O, no side
//       effects — effects are *requested*, not executed (ARCHITECTURE.md §5.1).
// Upstream: AppState, AppEvent, Effect
// Downstream: AppDriver (calls reduce(_:_:) on the UI thread)

import Foundation
import MoonSwiftCore
import RatatuiKit

// MARK: - reduce

/// Applies `event` to `state` and returns the next state with any requested effects.
///
/// This is the heart of the Elm-style loop. The function is pure: given the
/// same inputs it always returns the same outputs. The AppDriver executes the
/// returned effects; the reducer never does.
///
/// Key dispatch: global keys are checked first (they work in every pane);
/// pane-specific keys are dispatched based on `state.focus`. Modal states
/// capture all keys before the per-pane dispatch.
public func reduce(_ state: AppState, _ event: AppEvent) -> (AppState, [Effect]) {
    var s = state

    switch event {

    // MARK: Lifecycle

    case .appStarted:
        return reduceAppStarted(s)

    // MARK: Terminal input

    case .key(let code, let modifiers):
        return reduceKey(s, code: code, modifiers: modifiers)

    case .resize:
        // Terminal resize: no state change beyond what the renderer computes
        // from the AppState + size parameter. We just need to trigger a render
        // which the AppDriver does after every drain. Record the size if we
        // ever need it in AppState — for now a no-op state change is sufficient
        // to cause the AppDriver to re-render.
        return (s, [])

    case .mouse:
        // Mouse events are no-op in P1 (vim-flavored keyboard-only navigation).
        return (s, [])

    case .paste:
        // Paste is no-op in P1 (read-only code pane; picker uses key events).
        return (s, [])

    // MARK: Tick

    case .tick:
        return reduceTick(s)

    // MARK: Source loading

    case .sourceLoaded(let id, let fragment):
        s.sources[id] = .loaded(fragment)
        // Ensure the source is in navigator order.
        if !s.navigatorOrder.contains(id) {
            s.navigatorOrder.append(id)
        }
        // Schedule syntax highlight for the newly loaded source.
        var effects: [Effect] = [.highlight(id)]
        if let tick = armTickIfNeeded(s) { effects.append(tick) }
        return (s, effects)

    case .sourceFailed(let id, let state):
        s.sources[id] = state
        if !s.navigatorOrder.contains(id) {
            s.navigatorOrder.append(id)
        }
        return (s, [armTickIfNeeded(s)].compactMap { $0 })

    case .projectLoaded(let file, let diagnostics):
        s.project = .loaded(file, diagnostics: diagnostics)
        return (s, [])

    case .projectMalformed(let diag):
        s.project = .malformed(diag)
        return (s, [])

    case .designationsSaved:
        return (s, [.loadSources])

    // MARK: Run

    case .runOutput(let lines):
        // Append unconditionally — defense-in-depth (ARCHITECTURE.md §3c).
        s.bottomPane.appendOutputLines(lines)
        return (s, [])

    case .runFinished(let outcome):
        s.runState = .completed(outcome)
        return (s, tickEffectsAfterRunEnds(s))

    // MARK: Lint

    case .lintEngineReady:
        s.lintState = .idle
        return (s, [])

    case .lintEngineFailed(let message):
        s.lintState = .failed(message)
        return (s, [])

    case .catalogProbed(let available):
        s.tomlModuleAvailable = available
        return (s, [])

    case .prePassResult(let diag):
        s.bottomPane.prePassDiagnostic = diag
        if let diag {
            // Propagate to diagnostics list and gutter marks.
            s.bottomPane.diagnostics = [diag]
            s.codePane.gutterMarks = gutterMarks(from: [diag])
        } else {
            // Clean pre-pass clears the syntax-error gutter marks while
            // preserving any luacheck diagnostics that may still be showing.
        }
        return (s, [])

    case .lintFinished(let diagnostics):
        s.lintState = .idle
        s.bottomPane.diagnostics = diagnostics
        s.codePane.gutterMarks = gutterMarks(from: diagnostics)
        return (s, [])

    // MARK: Highlight

    case .highlightReady(let id, let spans):
        s.highlight[id] = spans
        return (s, [])
    }
}

// MARK: - Lifecycle handler

private func reduceAppStarted(_ s: AppState) -> (AppState, [Effect]) {
    var effects: [Effect] = [.loadSources, .prewarmLint]

    // If a project is loaded, start the tick for any active transient.
    if let tick = armTickIfNeeded(s) {
        effects.append(tick)
    }
    return (s, effects)
}

// MARK: - Tick handler

private func reduceTick(_ s: AppState) -> (AppState, [Effect]) {
    var s = s
    var effects: [Effect] = []

    // Expire the transient message if its deadline has passed.
    if let t = s.transient, Date() >= t.expiry {
        s.transient = nil
    }

    // Advance spinner phase (wraps at 8 — braille set has 8 frames).
    s.navigator.spinnerPhase = (s.navigator.spinnerPhase + 1) % 8

    // Recompute whether the tick is still needed.
    if let tick = armTickIfNeeded(s) {
        effects.append(tick)
    } else {
        effects.append(.stopTick)
    }
    return (s, effects)
}

// MARK: - Key dispatch

private func reduceKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {

    // Modal states capture all keys before global/pane dispatch.
    switch s.focus {
    case .helpOverlay:
        return reduceHelpOverlayKey(s, code: code, modifiers: modifiers)
    case .pickerModal:
        return reducePickerKey(s, code: code, modifiers: modifiers)
    case .initForm:
        return reduceInitFormKey(s, code: code, modifiers: modifiers)
    case .pane:
        break
    }

    // Colon command interception: when the code pane is actively collecting a
    // `:N<Enter>` sequence, ALL keys go to the colon handler — including ones
    // that would normally be global (e.g. `q`, which would otherwise quit).
    // This mirrors how Vim intercepts command-line input before normal bindings.
    if case .pane(.codePane) = s.focus, s.codePane.colonCommand != nil {
        return reduceColonCommand(s, code: code, modifiers: modifiers)
    }

    // Filter interception: when the navigator is focused and a filter is active,
    // character keys and backspace feed the filter query before global dispatch.
    // Esc and Enter are also intercepted here to clear / commit the filter.
    if case .pane(.navigator) = s.focus, s.navigator.filterText != nil {
        return reduceNavigatorFilter(s, code: code, modifiers: modifiers)
    }

    // Global keys — active in all panes when no modal is open.
    if let result = reduceGlobalKey(s, code: code, modifiers: modifiers) {
        return result
    }

    // Per-pane dispatch.
    switch s.focus {
    case .pane(.navigator):
        return reduceNavigatorKey(s, code: code, modifiers: modifiers)
    case .pane(.codePane):
        return reduceCodePaneKey(s, code: code, modifiers: modifiers)
    case .pane(.bottomPane):
        return reduceBottomPaneKey(s, code: code, modifiers: modifiers)
    default:
        return (s, [])
    }
}

// MARK: - Global key dispatch table

/// Keys that work in every pane (except when a modal is open).
///
/// Returns `nil` if the key is not a global key, so callers can fall through
/// to per-pane dispatch.
private func reduceGlobalKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect])? {
    var s = s

    switch (code, modifiers) {

    // r — run selected source
    case (.char("r"), []):
        return tryRun(s)

    // x — cancel run
    case (.char("x"), []):
        return (s, [.cancelRun])

    // l — lint selected source
    case (.char("l"), []):
        return tryLint(s)

    // q — quit
    case (.char("q"), []):
        return (s, [.cancelRun, .quit(exitCode: 0)])

    // ? — open help overlay
    case (.char("?"), []):
        s.focus = .helpOverlay
        return (s, [])

    // <C-p> — open project file in $EDITOR
    case (.char("p"), .ctrl):
        if case .loaded(_, _) = s.project,
            case .project(let root) = s.launch
        {
            let url = root.appendingPathComponent("moonswift.toml")
            return (s, [.spawnEditor(url)])
        }
        s.transient = TransientMessage(text: "No project file to open")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })

    // <C-r> — reload project file
    case (.char("r"), .ctrl):
        return (s, [.reloadProject])

    // <Tab> — cycle focus (context-sensitive: bottom pane cycles its tabs)
    case (.tab, []):
        return reduceCycleFocus(s, forward: true)

    // <S-Tab> — reverse-cycle panes (always panes, not tabs)
    case (.backTab, []):
        return reduceCycleFocus(s, forward: false)

    // <C-h> — jump to navigator
    case (.char("h"), .ctrl):
        s.focus = .pane(.navigator)
        return (s, [])

    // <C-l> — jump to code pane; EXCEPT when the bottom pane is focused,
    // where <C-l> means "clear output buffer" (ux-spec §2.3 bottom-pane
    // table, §6.4). The pane table takes precedence there, so decline the
    // key and let per-pane dispatch handle it (Fixes #1).
    case (.char("l"), .ctrl):
        if case .pane(.bottomPane) = s.focus { return nil }
        s.focus = .pane(.codePane)
        return (s, [])

    // <C-j> — jump to bottom pane
    case (.char("j"), .ctrl):
        s.focus = .pane(.bottomPane)
        return (s, [])

    // < / > — narrow / widen navigator (ux-spec.md §1.3)
    case (.char("<"), []):
        s.paneLayout.navigatorWidth = max(
            PaneLayout.navigatorMin,
            s.paneLayout.navigatorWidth - 2
        )
        return (s, [])

    case (.char(">"), []):
        s.paneLayout.navigatorWidth = min(
            PaneLayout.navigatorMax,
            s.paneLayout.navigatorWidth + 2
        )
        return (s, [])

    // { / } — shrink / grow bottom pane (ux-spec.md §1.3)
    case (.char("{"), []):
        let current = s.paneLayout.bottomPaneHeight ?? PaneLayout.defaultBottomRows
        s.paneLayout.bottomPaneHeight = max(PaneLayout.bottomPaneMin, current - 1)
        return (s, [])

    case (.char("}"), []):
        let current = s.paneLayout.bottomPaneHeight ?? PaneLayout.defaultBottomRows
        s.paneLayout.bottomPaneHeight = min(PaneLayout.bottomPaneMaxRatio, current + 1)
        return (s, [])

    default:
        return nil
    }
}

// MARK: - Navigator key dispatch table

private func reduceNavigatorKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    switch (code, modifiers) {

    case (.char("j"), []):
        // Navigate within the filtered list, then map back to the full order index.
        let filtered = filteredIDs(from: s)
        if !filtered.isEmpty {
            let currentPos = filteredPosition(
                selectedIndex: s.navigator.selectedIndex, filtered: filtered, order: s.navigatorOrder)
            let nextPos = min((currentPos ?? 0) + 1, filtered.count - 1)
            s.navigator.selectedIndex = fullOrderIndex(
                filteredPos: nextPos, filtered: filtered, order: s.navigatorOrder)
        }
        return (s, [])

    case (.char("k"), []):
        let filtered = filteredIDs(from: s)
        if !filtered.isEmpty {
            let currentPos = filteredPosition(
                selectedIndex: s.navigator.selectedIndex, filtered: filtered, order: s.navigatorOrder)
            let prevPos = max((currentPos ?? 0) - 1, 0)
            s.navigator.selectedIndex = fullOrderIndex(
                filteredPos: prevPos, filtered: filtered, order: s.navigatorOrder)
        }
        return (s, [])

    case (.char("g"), []):
        // Jump to the first entry in the filtered list.
        let filtered = filteredIDs(from: s)
        if !filtered.isEmpty {
            s.navigator.selectedIndex = fullOrderIndex(
                filteredPos: 0, filtered: filtered, order: s.navigatorOrder)
        }
        return (s, [])

    case (.char("G"), []):
        // Jump to the last entry in the filtered list.
        let filtered = filteredIDs(from: s)
        if !filtered.isEmpty {
            s.navigator.selectedIndex = fullOrderIndex(
                filteredPos: filtered.count - 1,
                filtered: filtered,
                order: s.navigatorOrder
            )
        }
        return (s, [])

    case (.enter, []), (.char("o"), []), (.char(" "), []):
        return selectNavigatorEntry(s)

    case (.char("/"), []):
        // Activate inline filter mode with an empty query. Pressing / again
        // when filter is already active closes it (toggle, ux-spec §2.2).
        s.navigator.filterText = s.navigator.filterText == nil ? "" : nil
        return (s, [])

    case (.escape, []):
        // Esc clears the filter when active; otherwise it is a no-op.
        if s.navigator.filterText != nil {
            s.navigator.filterText = nil
        }
        return (s, [])

    case (.char("m"), []):
        // Open the structured-file picker for the selected entry.
        // Only meaningful for structured-file sources (SourceID has a jsonpath).
        return openPickerOrTransient(s)

    default:
        return (s, [])
    }
}

// MARK: - Navigator filter input handler

/// Handles keyboard input while the navigator inline filter is active.
///
/// All printable characters are appended to the filter query; `<Backspace>`
/// deletes the last character; `<Esc>` cancels and clears the filter; `<Enter>`
/// commits the filter (loads the current selection). Navigation keys (`j`/`k`/
/// `g`/`G`) are NOT intercepted here — typing any letter including 'j' and 'k'
/// appends to the query (ux-spec §2.2: typing chars feeds the query).
private func reduceNavigatorFilter(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    switch (code, modifiers) {

    case (.escape, []):
        // Clear the filter and return to normal navigator mode.
        s.navigator.filterText = nil
        return (s, [])

    case (.enter, []):
        // Commit: load the currently highlighted filtered entry.
        return selectNavigatorEntry(s)

    case (.backspace, []):
        // Delete the last character from the query.
        if var query = s.navigator.filterText, !query.isEmpty {
            query.removeLast()
            s.navigator.filterText = query
        }
        return (s, [])

    case (.char("/"), []):
        // Second press of / closes the filter (toggle, ux-spec §2.2).
        s.navigator.filterText = nil
        return (s, [])

    case (.char(let scalar), []) where !CharacterSet.controlCharacters.contains(scalar):
        // Append a printable character to the filter query (ux-spec §2.2: typing feeds
        // the query; navigation is via arrow keys or after Enter commit). This catch-all
        // intentionally matches every printable character including 'j', 'k', 'g', 'G'
        // so the user can search for entries whose names contain those letters.
        let ch = String(scalar)
        s.navigator.filterText = (s.navigator.filterText ?? "") + ch
        // Re-anchor selection to the first matching entry when the query grows.
        let filtered = filteredIDs(from: s)
        if !filtered.isEmpty {
            s.navigator.selectedIndex =
                fullOrderIndex(filteredPos: 0, filtered: filtered, order: s.navigatorOrder)
        }
        return (s, [])

    default:
        // All other keys (modifiers, function keys, etc.) are ignored in filter mode.
        return (s, [])
    }
}

// MARK: - Code pane key dispatch table

private func reduceCodePaneKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    switch (code, modifiers) {

    case (.char("j"), []):
        s.codePane.scrollOffset += 1
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    case (.char("k"), []):
        s.codePane.scrollOffset = max(0, s.codePane.scrollOffset - 1)
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    case (.char("d"), []):
        s.codePane.scrollOffset += halfPageSize
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    case (.char("u"), []):
        s.codePane.scrollOffset = max(0, s.codePane.scrollOffset - halfPageSize)
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    case (.char("f"), []):
        s.codePane.scrollOffset += fullPageSize
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    case (.char("b"), []):
        s.codePane.scrollOffset = max(0, s.codePane.scrollOffset - fullPageSize)
        s.codePane.cursorLine = s.codePane.scrollOffset
        return (s, [])

    case (.char("g"), []):
        s.codePane.scrollOffset = 0
        s.codePane.cursorLine = 0
        return (s, [])

    case (.char("G"), []):
        // Jump to bottom — renderer clamps; use a large sentinel value.
        s.codePane.scrollOffset = Int.max / 2
        s.codePane.cursorLine = Int.max / 2
        return (s, [])

    // : — begin colon command entry (ux-spec §2.3 ":N<Enter>" and ":q").
    case (.char(":"), []):
        s.codePane.colonCommand = ""
        return (s, [])

    case (.char("n"), []):
        return jumpToDiagnostic(s, direction: .next)

    case (.char("N"), []):
        return jumpToDiagnostic(s, direction: .previous)

    // [d — jump to first diagnostic
    case (.char("["), []):
        return jumpToDiagnostic(s, direction: .first)

    // ]d — jump to last diagnostic (mapped as ] because [ and ] are separate keys)
    case (.char("]"), []):
        return jumpToDiagnostic(s, direction: .last)

    default:
        return (s, [])
    }
}

// MARK: - Colon command handler (ux-spec §2.3 ":N<Enter>" jump)

/// Handles key input while the code pane `:` command is being entered.
///
/// Accepts digits (accumulated in `colonCommand`), `Enter` to execute the jump,
/// and `Esc` to cancel. The special sequence `:q` shows the "use q to quit"
/// transient per ux-spec §2.3 — it is the only recognised non-digit input.
/// Any other non-digit character cancels the command silently.
private func reduceColonCommand(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    switch (code, modifiers) {

    case (.escape, []):
        // Cancel without executing.
        s.codePane.colonCommand = nil
        return (s, [])

    case (.enter, []):
        // Execute: parse digits and jump, then clear the command buffer.
        let digits = s.codePane.colonCommand ?? ""
        s.codePane.colonCommand = nil
        if let lineNum = Int(digits), lineNum > 0 {
            // Jump to line lineNum (1-based → 0-based).
            let target = lineNum - 1
            s.codePane.cursorLine = target
            s.codePane.scrollOffset = target
        }
        return (s, [])

    case (.char(let scalar), []) where Character(scalar).isNumber:
        // Append a digit to the command buffer.
        s.codePane.colonCommand = (s.codePane.colonCommand ?? "") + String(scalar)
        return (s, [])

    case (.char("q"), []):
        // ":q" — show the "use q to quit" transient (ux-spec §2.3 exact string).
        s.codePane.colonCommand = nil
        s.transient = TransientMessage(text: "use q to quit")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })

    default:
        // Any other character cancels the command silently.
        s.codePane.colonCommand = nil
        return (s, [])
    }
}

// MARK: - Bottom pane key dispatch table

private func reduceBottomPaneKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s

    switch (code, modifiers) {

    case (.char("j"), []):
        s.bottomPane.scrollOffset += 1
        return (s, [])

    case (.char("k"), []):
        s.bottomPane.scrollOffset = max(0, s.bottomPane.scrollOffset - 1)
        return (s, [])

    case (.enter, []):
        // Jump code pane to the error line of the focused diagnostic.
        return jumpCodePaneFromBottomPane(s)

    case (.char("1"), []):
        s.bottomPane.activeTab = .output
        s.bottomPane.scrollOffset = 0
        return (s, [])

    case (.char("2"), []):
        s.bottomPane.activeTab = .diagnostics
        s.bottomPane.scrollOffset = 0
        return (s, [])

    case (.tab, []):
        // Cycle tabs within the bottom pane (context-sensitive Tab).
        switch s.bottomPane.activeTab {
        case .output:
            s.bottomPane.activeTab = .diagnostics
        case .diagnostics:
            s.bottomPane.activeTab = .output
        }
        s.bottomPane.scrollOffset = 0
        return (s, [])

    case (.char("l"), .ctrl):
        s.bottomPane.outputBuffer.removeAll()
        s.bottomPane.scrollOffset = 0
        return (s, [])

    default:
        return (s, [])
    }
}

// MARK: - Modal key handlers (stubs for P1)

private func reduceHelpOverlayKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s
    switch (code, modifiers) {
    case (.escape, []), (.char("?"), []):
        s.focus = .pane(.navigator)
    default:
        break
    }
    return (s, [])
}

private func reducePickerKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s
    if case (.escape, []) = (code, modifiers) {
        s.focus = .pane(.navigator)
    }
    return (s, [])
}

private func reduceInitFormKey(
    _ s: AppState,
    code: KeyCode,
    modifiers: KeyModifiers
) -> (AppState, [Effect]) {
    var s = s
    if case (.escape, []) = (code, modifiers) {
        s.focus = .pane(.navigator)
    }
    return (s, [])
}

// MARK: - Focus cycling

private func reduceCycleFocus(
    _ s: AppState,
    forward: Bool
) -> (AppState, [Effect]) {
    var s = s

    guard case .pane(let current) = s.focus else {
        // In a modal state, Tab has no focus-cycle effect.
        return (s, [])
    }

    // Context-sensitive Tab: when the bottom pane is focused, cycle its tabs.
    if forward && current == .bottomPane {
        switch s.bottomPane.activeTab {
        case .output:
            s.bottomPane.activeTab = .diagnostics
        case .diagnostics:
            // Tab at the last tab cycles back to navigator.
            s.focus = .pane(.navigator)
        }
        s.bottomPane.scrollOffset = 0
        return (s, [])
    }

    let order: [PaneID] = [.navigator, .codePane, .bottomPane]
    if let idx = order.firstIndex(of: current) {
        let next: Int
        if forward {
            next = (idx + 1) % order.count
        } else {
            next = (idx + order.count - 1) % order.count
        }
        s.focus = .pane(order[next])
    }
    return (s, [])
}

// MARK: - Run / Lint preconditions

private func tryRun(_ s: AppState) -> (AppState, [Effect]) {
    var s = s

    // Guard: a run must not be already in progress.
    if case .running = s.runState {
        s.transient = TransientMessage(text: "Run in progress")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    // Guard: a source must be selected and loaded.
    guard let id = s.selection,
        case .loaded(let fragment) = s.sources[id]
    else {
        s.transient = TransientMessage(text: "No source loaded")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    // Guard: Lua version must be supported.
    if case .unsupportedVersion = s.project {
        s.transient = TransientMessage(
            text: "Run disabled: unsupported Lua version. Edit moonswift.toml and press <C-r>."
        )
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    // Start the run.
    s.runState = .running(id: UUID(), startedAt: Date())
    s.bottomPane.activeTab = .output
    s.bottomPane.outputBuffer.removeAll()

    let runConfig: RunConfig
    if case .loaded(let file, _) = s.project {
        runConfig = file.run
    } else {
        runConfig = RunConfig()
    }

    let effects: [Effect] = [
        .run(fragment, runConfig),
        .startTick(interval: TickInterval.run),
    ]
    return (s, effects)
}

private func tryLint(_ s: AppState) -> (AppState, [Effect]) {
    var s = s

    guard case .idle = s.lintState else {
        let msg =
            s.lintState == .initializing
            ? "lint engine starting…"
            : "Lint engine not ready"
        s.transient = TransientMessage(text: msg)
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    guard let id = s.selection,
        case .loaded(let fragment) = s.sources[id]
    else {
        s.transient = TransientMessage(text: "No source loaded")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    if case .unsupportedVersion = s.project {
        s.transient = TransientMessage(
            text: "Lint disabled: unsupported Lua version. Edit moonswift.toml and press <C-r>."
        )
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }

    s.lintState = .running
    s.bottomPane.activeTab = .diagnostics
    let extraModules = extractExtraModules(from: s.project)
    return (s, [.lint(fragment, extraModules: extraModules)])
}

// MARK: - Helpers

/// Compute the minimal tick interval across all currently active consumers.
/// Returns nil if no consumer needs ticks.
private func armTickIfNeeded(_ s: AppState) -> Effect? {
    var minimum: Duration? = nil

    // Run-coalescer tick (100 ms) while a run is active.
    if case .running = s.runState {
        minimum = TickInterval.run
    }

    // Spinner tick (100 ms) while any source is loading (ux-spec §4.1).
    // The same interval as the run tick so there is no extra overhead when both
    // are active simultaneously — `startTick` always replaces the previous timer.
    let anyLoading = s.sources.values.contains {
        if case .loading = $0 { return true }
        return false
    }
    if anyLoading {
        let candidate = TickInterval.run
        if let m = minimum {
            minimum = m < candidate ? m : candidate
        } else {
            minimum = candidate
        }
    }

    // Transient expiry (1.5 s) while a transient message is showing.
    if s.transient != nil {
        let candidate = TickInterval.transientExpiry
        if let m = minimum {
            minimum = m < candidate ? m : candidate
        } else {
            minimum = candidate
        }
    }

    guard let interval = minimum else { return nil }
    return .startTick(interval: interval)
}

/// Compute tick effects to emit after a run finishes.
private func tickEffectsAfterRunEnds(_ s: AppState) -> [Effect] {
    if let tick = armTickIfNeeded(s) {
        return [tick]
    }
    return [.stopTick]
}

/// Build gutter marks from a diagnostic array.
private func gutterMarks(from diagnostics: [Diagnostic]) -> [Int: GutterMark] {
    var marks: [Int: GutterMark] = [:]
    for d in diagnostics {
        let line = max(0, d.line - 1)  // convert 1-based to 0-based
        switch d.severity {
        case .error:
            marks[line] = .error
        case .warning:
            if marks[line] == nil {
                marks[line] = .warning
            }
        }
    }
    return marks
}

/// Extract the extraModules list from the current project state.
private func extractExtraModules(from project: ProjectState) -> [String] {
    if case .loaded(let file, _) = project {
        return file.lint.extraModules
    }
    return []
}

/// Select the currently highlighted navigator entry and load it into the code pane.
///
/// Resets the full `CodePaneState` so scroll, cursor, colon command, and
/// diagnostic index all start fresh for the newly selected source.
private func selectNavigatorEntry(_ s: AppState) -> (AppState, [Effect]) {
    var s = s
    guard s.navigator.selectedIndex < s.navigatorOrder.count else {
        return (s, [])
    }
    let id = s.navigatorOrder[s.navigator.selectedIndex]
    s.selection = id
    // Full reset: scroll offset, cursor line, colonCommand, diagnosticIndex.
    s.codePane = CodePaneState()

    var effects: [Effect] = []
    // Schedule highlight if the source is loaded and has no spans yet.
    if case .loaded = s.sources[id], s.highlight[id] == nil {
        effects.append(.highlight(id))
    }
    // Run syntax pre-pass on selection.
    if case .loaded(let fragment) = s.sources[id] {
        effects.append(.syntaxPrePass(fragment))
    }
    return (s, effects)
}

// MARK: - Navigator filter helpers

/// Returns the filtered source IDs using the navigator's current filter text.
///
/// Delegates to `filteredNavigatorIDs` in Renderer.swift (the same logic drives
/// both the display list and navigation so the two stay in sync).
private func filteredIDs(from s: AppState) -> [SourceID] {
    filteredNavigatorIDs(order: s.navigatorOrder, filterText: s.navigator.filterText)
}

/// Returns the position of the selected entry within the filtered list, or nil
/// if the currently selected source ID is not present in `filtered`.
private func filteredPosition(
    selectedIndex: Int,
    filtered: [SourceID],
    order: [SourceID]
) -> Int? {
    guard order.indices.contains(selectedIndex) else { return nil }
    let id = order[selectedIndex]
    return filtered.firstIndex(of: id)
}

/// Maps a position in the filtered list back to an index in the full `order` array.
///
/// Returns the last valid index as a fallback so `selectedIndex` never goes out of range.
private func fullOrderIndex(filteredPos: Int, filtered: [SourceID], order: [SourceID]) -> Int {
    guard filtered.indices.contains(filteredPos) else { return max(0, order.count - 1) }
    let id = filtered[filteredPos]
    return order.firstIndex(of: id) ?? max(0, order.count - 1)
}

/// Opens the structured-file picker when the selected entry has a JSONPath, or
/// shows a 1.5 s transient if the selected source is not a structured file.
///
/// Only structured-file entries (ux-spec §3.6: those with a `jsonpath` in their
/// SourceID) can open the picker. Whole `.lua` file entries are not eligible.
private func openPickerOrTransient(_ s: AppState) -> (AppState, [Effect]) {
    var s = s
    guard s.navigator.selectedIndex < s.navigatorOrder.count else {
        return (s, [])
    }
    let id = s.navigatorOrder[s.navigator.selectedIndex]
    if id.jsonpath != nil {
        // Structured-file entry — open the picker modal (ux-spec §3.6).
        s.focus = .pickerModal
        return (s, [])
    } else {
        // Whole .lua file or unknown — picker is not applicable.
        s.transient = TransientMessage(text: "Picker available for structured files only")
        return (s, [armTickIfNeeded(s)].compactMap { $0 })
    }
}

// MARK: - Diagnostic navigation

private enum DiagnosticDirection { case next, previous, first, last }

/// Jumps the code pane cursor to a diagnostic using the `diagnosticIndex` counter.
///
/// Navigation is wrap-around: `n` past the last diagnostic wraps to the first;
/// `N` before the first wraps to the last (ux-spec §2.3). `diagnosticIndex` is
/// maintained across `n`/`N` calls and reset whenever the active source changes.
private func jumpToDiagnostic(
    _ s: AppState,
    direction: DiagnosticDirection
) -> (AppState, [Effect]) {
    var s = s
    let diags = s.bottomPane.diagnostics
    guard !diags.isEmpty else { return (s, []) }

    let count = diags.count
    let newIndex: Int
    switch direction {
    case .first:
        newIndex = 0
    case .last:
        newIndex = count - 1
    case .next:
        // Wrap-around: advance from current index or start from 0 on first call.
        let current = s.codePane.diagnosticIndex ?? -1
        newIndex = (current + 1) % count
    case .previous:
        // Wrap-around: step back, wrapping to last when at index 0 or unset.
        let current = s.codePane.diagnosticIndex ?? 0
        newIndex = (current - 1 + count) % count
    }

    s.codePane.diagnosticIndex = newIndex
    let targetLine = diags[newIndex].line
    s.codePane.cursorLine = max(0, targetLine - 1)
    s.codePane.scrollOffset = max(0, targetLine - 1)
    return (s, [])
}

private func jumpCodePaneFromBottomPane(_ s: AppState) -> (AppState, [Effect]) {
    var s = s
    let diags = s.bottomPane.diagnostics
    guard !diags.isEmpty else { return (s, []) }

    let idx = min(s.bottomPane.scrollOffset, diags.count - 1)
    let line = diags[idx].line
    s.codePane.cursorLine = max(0, line - 1)
    s.codePane.scrollOffset = max(0, line - 1)
    s.codePane.jumpPulseLine = max(0, line - 1)
    return (s, [armTickIfNeeded(s)].compactMap { $0 })
}

// MARK: - Scroll constants

/// Half-page scroll size (approximate; renderer clips to content bounds).
private let halfPageSize = 10

/// Full-page scroll size (approximate; renderer clips to content bounds).
private let fullPageSize = 20
