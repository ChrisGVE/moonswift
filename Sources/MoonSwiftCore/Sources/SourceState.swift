// File: Sources/MoonSwiftCore/Sources/SourceState.swift
// Location: MoonSwiftCore/Sources/
// Role: Per-source loading state kept in AppState.sources, and the event
//       payload types that SourceStore uses to communicate load results back
//       to the AppDriver. All source loads are asynchronous (ARCHITECTURE.md
//       §3a): every entry starts in .loading; SourceStore posts .sourceLoaded
//       or .sourceFailed via an injected @Sendable callback.
// Upstream: Diagnostic (failure payload), LuaSourceFragment (success payload)
// Downstream: AppState.sources, AppDriver (consumes events), Reducer, Renderer

// MARK: - SourceState

/// The loading state of one source entry in `AppState.sources`.
///
/// All source loads start in `.loading` and transition to either `.loaded` or
/// one of the failure cases after the background task completes. The `.missing`
/// and `.failed` cases carry distinct diagnostics matching the UX specification
/// (ux-spec.md §4.2) so the renderer can display appropriate error messages and
/// navigator decorations without additional logic.
public enum SourceState: Sendable {

    /// The background load task has been dispatched but has not completed.
    /// The navigator shows a spinner after 100 ms (ux-spec.md §4.1).
    case loading

    /// The file was read successfully. The associated `LuaSourceFragment`
    /// contains the decoded text and its provenance.
    case loaded(LuaSourceFragment)

    /// The file does not exist at the path declared in the project file.
    ///
    /// Navigator: `✖ <filename>` in error color.
    /// Code pane: `✖ File not found: <project-relative-path>` (ux-spec.md §4.2).
    /// Bottom pane: contributes to the `⚠ N source(s) not found — see navigator`
    ///              diagnostic at project load.
    case missing

    /// The file exists but could not be loaded (I/O error or encoding failure).
    ///
    /// The `Diagnostic` payload carries the human-readable error message so the
    /// renderer can display it in the code pane and the bottom-pane diagnostic
    /// list without duplicating message-construction logic.
    case failed(Diagnostic)
}

// MARK: - SourceLoadEvent

/// The result payload that `SourceStore` delivers to the AppDriver callback
/// after a background load attempt completes.
///
/// The AppDriver wraps these payloads into `AppEvent.sourceLoaded` /
/// `AppEvent.sourceFailed` (or their equivalents) before posting to
/// `EventChannel`. `SourceStore` never sees `AppEvent` — the callback is the
/// only cross-layer interface (ARCHITECTURE.md §5.1 service-callback contract).
public enum SourceLoadEvent: Sendable {

    /// The source loaded successfully. The `LuaSourceFragment` carries both
    /// the decoded text and its provenance.
    case loaded(id: SourceID, fragment: LuaSourceFragment)

    /// The source could not be loaded. The `SourceID` identifies which entry
    /// failed; the `SourceState` is either `.missing` or `.failed(_)`.
    ///
    /// Using `SourceState` directly as the payload avoids re-encoding the
    /// distinction in a separate enum while keeping the failure cases typed.
    case failed(id: SourceID, state: SourceState)
}
