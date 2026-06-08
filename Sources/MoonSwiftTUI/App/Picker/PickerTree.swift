// File: Sources/MoonSwiftTUI/App/Picker/PickerTree.swift
// Location: MoonSwiftTUI/App/Picker/
// Role: Flattens a TreeValue decoded tree into a visible row list for the
//       structured-file picker modal. Tracks which nodes are expanded and
//       provides the path-annotation data the reducer and renderer need.
//       (ux-spec.md §3.6, PRD F1.3)
// Upstream: MoonSwiftCore.TreeValue, MoonSwiftCore.NormalizedPath,
//           MoonSwiftCore.ResolvedStep
// Downstream: PickerState (holds PickerTree), Reducer (mutates expansion),
//             Renderer (reads visibleRows for display)

import MoonSwiftCore

// MARK: - Path rendering helper

/// Renders a concrete `[ResolvedStep]` array to RFC 9535 normalized-form string.
///
/// Rules (mirrors `NormalizedPath.description` in MoonSwiftCore, reproduced here
/// because `NormalizedPath.init(steps:)` is internal):
/// - Dot notation `$.name` for keys containing only `[A-Za-z0-9_]` characters.
/// - Bracket notation `$['name']` for all other keys.
/// - Index notation `$[N]` for array indices.
func pickerNormalizedPath(steps: [ResolvedStep]) -> String {
    var out = "$"
    for step in steps {
        switch step {
        case .key(let name):
            if pickerIsDotNotationSafe(name) {
                out += ".\(name)"
            } else {
                let escaped =
                    name
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "'", with: "\\'")
                out += "['\(escaped)']"
            }
        case .index(let idx):
            out += "[\(idx)]"
        }
    }
    return out
}

/// Returns true when `name` can be expressed in dot notation (ASCII letters,
/// digits, underscores only — same rule as NormalizedPath.isDotNotationSafe).
private func pickerIsDotNotationSafe(_ name: String) -> Bool {
    guard !name.isEmpty else { return false }
    return name.unicodeScalars.allSatisfy { ch in
        (ch >= "a" && ch <= "z") || (ch >= "A" && ch <= "Z") || (ch >= "0" && ch <= "9") || ch == "_"
    }
}

// MARK: - PickerRowKind

/// The kind of content a picker row represents.
///
/// Used by the renderer to choose the annotation label (`str`, `int`, `bool`,
/// `arr`, `obj`) and to determine whether the row is markable. Only `.str` rows
/// are markable; all others are shown in dim style (ux-spec §3.6).
public enum PickerRowKind: Sendable, Equatable {
    /// A string scalar — the only markable field type (ux-spec §3.6).
    case str
    /// An integer scalar (int64 or double).
    case int
    /// A boolean scalar.
    case bool
    /// An array node (collapsible).
    case arr
    /// A map/object node (collapsible).
    case obj
    /// A null or unknown value.
    case nullValue

    /// The annotation label shown in the picker tree (ux-spec §3.6).
    public var annotation: String {
        switch self {
        case .str: return "str"
        case .int: return "int"
        case .bool: return "bool"
        case .arr: return "arr"
        case .obj: return "obj"
        case .nullValue: return "null"
        }
    }

    /// True when the row can be toggled with Enter/m (ux-spec §3.6).
    public var isMarkable: Bool {
        self == .str
    }
}

// MARK: - PickerRow

/// One visible row in the picker tree view.
///
/// The renderer uses `depth`, `label`, `kind`, and `normalized` to compose
/// each display line. The `nodeID` allows the expansion set to remain stable
/// across re-flattening when expansion changes.
public struct PickerRow: Sendable, Equatable {

    // MARK: Display

    /// Indentation depth (0 = top level).
    public let depth: Int

    /// The key name or array index label for this row (e.g. `"scripts"`, `"[0]"`).
    public let label: String

    /// The type annotation for this row.
    public let kind: PickerRowKind

    /// True when this is a collapsible node (arr or obj) that is currently expanded.
    public let isExpanded: Bool

    /// Scalar string value, present only for `.str` rows — used by the renderer
    /// to show the value inline and by the status-line path display.
    public let stringValue: String?

    // MARK: Path

    /// RFC 9535 normalized JSONPath from the document root to this node.
    ///
    /// Used as the persistence key when the user marks this row (ux-spec §3.6
    /// "status line shows the generated normalized JSONPath").
    public let normalized: String

    /// The concrete resolved steps, kept for future use (e.g. breadcrumb display).
    public let steps: [ResolvedStep]

    // MARK: Identity

    /// A stable node identifier (same path = same ID across re-flattening).
    /// Equal to `normalized`.
    public var nodeID: String { normalized }

    // MARK: Init

    public init(
        depth: Int,
        label: String,
        kind: PickerRowKind,
        isExpanded: Bool,
        stringValue: String?,
        normalized: String,
        steps: [ResolvedStep]
    ) {
        self.depth = depth
        self.label = label
        self.kind = kind
        self.isExpanded = isExpanded
        self.stringValue = stringValue
        self.normalized = normalized
        self.steps = steps
    }
}

// MARK: - PickerTree

/// Owns the decoded TreeValue and the user's current expansion state.
///
/// `visibleRows` re-flattens the tree on demand using the current expansion
/// set — the caller (reducer/renderer) always gets a fresh, consistent view.
/// Flat re-computation is fast enough for config-file sizes (PRD F1.3: files
/// are "structured config files", not large data sets).
public struct PickerTree: Sendable, Equatable {

    // MARK: Stored state

    /// The root TreeValue of the decoded document.
    public let root: TreeValue

    /// Set of `nodeID` (normalized path) strings whose collapsible nodes are
    /// currently expanded. Starts with all map/array nodes at depth 0 expanded
    /// so the first level is always visible.
    public var expanded: Set<String>

    // MARK: Init

    /// Creates a PickerTree from a decoded root value, expanding the top-level
    /// keys immediately so the tree is not empty when the picker opens.
    public init(root: TreeValue) {
        self.root = root
        // Start with the root's direct children expanded (depth-0 maps/arrays).
        // This gives the user a useful initial view without overwhelming the screen
        // with a fully-expanded deep tree.
        var initial: Set<String> = []
        if case .map(let dict) = root {
            for (key, child) in dict.elements {
                let nodeID = pickerNormalizedPath(steps: [.key(key)])
                switch child {
                case .map, .array:
                    initial.insert(nodeID)
                default:
                    break
                }
            }
        }
        self.expanded = initial
    }

    // MARK: - Visible rows

    /// Returns the current flat visible row list by depth-first traversal of the
    /// tree, skipping children of collapsed nodes.
    ///
    /// The list is recomputed on every call — callers should cache the result
    /// for a single render/interaction pass and discard it when `expanded` changes.
    public func visibleRows() -> [PickerRow] {
        var rows: [PickerRow] = []
        appendRows(value: root, steps: [], depth: -1, label: "", into: &rows)
        // The root itself is not shown as a row; only its children are.
        // We start with depth -1 and skip the root row below.
        return rows
    }

    // MARK: - Private traversal

    /// Recursively appends visible rows for `value` and — when expanded — its
    /// children. `depth == -1` means the root node (never appended as a row).
    private func appendRows(
        value: TreeValue,
        steps: [ResolvedStep],
        depth: Int,
        label: String,
        into rows: inout [PickerRow]
    ) {
        let nodeID = pickerNormalizedPath(steps: steps)

        // Root: descend without appending a row.
        if depth == -1 {
            switch value {
            case .map(let dict):
                for (key, child) in dict.elements {
                    let childSteps = steps + [.key(key)]
                    appendRows(value: child, steps: childSteps, depth: 0, label: key, into: &rows)
                }
            case .array(let arr):
                for (idx, child) in arr.enumerated() {
                    let childSteps = steps + [.index(idx)]
                    appendRows(value: child, steps: childSteps, depth: 0, label: "[\(idx)]", into: &rows)
                }
            default:
                // Scalar root: show it as a single row at depth 0.
                let (kind, strVal) = rowKind(for: value)
                rows.append(
                    PickerRow(
                        depth: 0,
                        label: "$",
                        kind: kind,
                        isExpanded: false,
                        stringValue: strVal,
                        normalized: nodeID,
                        steps: steps
                    ))
            }
            return
        }

        // Non-root node: append a row for this value.
        switch value {

        case .map(let dict):
            let isExpanded = expanded.contains(nodeID)
            rows.append(
                PickerRow(
                    depth: depth,
                    label: label,
                    kind: .obj,
                    isExpanded: isExpanded,
                    stringValue: nil,
                    normalized: nodeID,
                    steps: steps
                ))
            if isExpanded {
                for (key, child) in dict.elements {
                    let childSteps = steps + [.key(key)]
                    appendRows(
                        value: child,
                        steps: childSteps,
                        depth: depth + 1,
                        label: key,
                        into: &rows
                    )
                }
            }

        case .array(let arr):
            let isExpanded = expanded.contains(nodeID)
            rows.append(
                PickerRow(
                    depth: depth,
                    label: label,
                    kind: .arr,
                    isExpanded: isExpanded,
                    stringValue: nil,
                    normalized: nodeID,
                    steps: steps
                ))
            if isExpanded {
                for (idx, child) in arr.enumerated() {
                    let childSteps = steps + [.index(idx)]
                    appendRows(
                        value: child,
                        steps: childSteps,
                        depth: depth + 1,
                        label: "[\(idx)]",
                        into: &rows
                    )
                }
            }

        default:
            let (kind, strVal) = rowKind(for: value)
            rows.append(
                PickerRow(
                    depth: depth,
                    label: label,
                    kind: kind,
                    isExpanded: false,
                    stringValue: strVal,
                    normalized: nodeID,
                    steps: steps
                ))
        }
    }

    // MARK: - Kind resolution

    /// Maps a scalar `TreeValue` to its `PickerRowKind` and optional string value.
    private func rowKind(for value: TreeValue) -> (PickerRowKind, String?) {
        switch value {
        case .string(let s): return (.str, s)
        case .int: return (.int, nil)
        case .double: return (.int, nil)
        case .bool: return (.bool, nil)
        case .array: return (.arr, nil)
        case .map: return (.obj, nil)
        case .null: return (.nullValue, nil)
        }
    }
}
