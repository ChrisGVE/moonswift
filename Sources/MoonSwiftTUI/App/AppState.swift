// File: Sources/MoonSwiftTUI/App/AppState.swift
// Role: Defines the single value-semantics application state that the
//       Elm-style reducer owns. Every mutable piece of UI truth lives here;
//       nothing else mutates anything (ARCHITECTURE.md §1, §4.2).
//       `AppState` is a `Sendable` struct so it can cross actor boundaries
//       safely under Swift 6 strict concurrency.
// Upstream: MoonSwiftCore (ProjectFile, SourceID, Diagnostic types)
// Downstream: Reducer.swift (produces AppState), Renderer.swift (reads AppState)

// AppState is the root of the in-memory state tree described in
// ARCHITECTURE.md §4.2. The full tree is elaborated in subsequent tasks
// (F1, F2, F3 …). This file provides the minimal declaration that satisfies
// the Swift 6 compiler for the skeleton build (task 1).
public struct AppState: Sendable {
    // Placeholder until the full state tree is built in F1+.
    // Each field documented in ARCHITECTURE.md §4.2 will be added here
    // in the task that implements the corresponding feature.
    public init() {}
}
