// File: Sources/MoonSwiftCore/Sources/SourceID.swift
// Location: MoonSwiftCore/Sources/
// Role: Stable identity for a loaded source fragment, keyed by the project-file
//       path and (for structured files) the normalized JSONPath and document
//       index. Used as the key in AppState.sources and throughout the event
//       system to correlate load results with navigator entries.
// Upstream: ProjectFile (SourceEntry, FieldDesignation)
// Downstream: SourceState, SourceStore, AppState.sources, AppEvent

import Foundation

// MARK: - SourceID

/// A stable, unique identifier for one Lua source fragment.
///
/// For a whole `.lua` file the identity is determined by the project-relative
/// file path alone. For a structured-file field it is further qualified by the
/// normalized JSONPath expression and the document index (YAML multi-document).
///
/// `SourceID` is `Hashable` and `Sendable` so it can serve as a dictionary key
/// in `AppState.sources` and travel across concurrency boundaries in events.
public struct SourceID: Sendable, Hashable, Equatable, CustomStringConvertible {

    // MARK: Fields

    /// Project-relative path to the source file (e.g. `"scripts/init.lua"`).
    public let path: String

    /// Normalized JSONPath selector for structured-file fragments. `nil` for
    /// whole `.lua` files.
    public let jsonpath: String?

    /// YAML multi-document index. Always `0` for JSON, TOML, and `.lua` files.
    public let document: Int

    // MARK: Initialiser

    public init(path: String, jsonpath: String? = nil, document: Int = 0) {
        self.path = path
        self.jsonpath = jsonpath
        self.document = document
    }

    // MARK: CustomStringConvertible

    /// Human-readable description matching the display-name convention:
    /// `<path>` for whole files, `<path>:<jsonpath>` for structured fields.
    public var description: String {
        if let jsonpath {
            return "\(path):\(jsonpath)"
        }
        return path
    }
}
