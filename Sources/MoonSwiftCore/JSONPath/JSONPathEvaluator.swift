// File: Sources/MoonSwiftCore/JSONPath/JSONPathEvaluator.swift
// Role: Evaluates a parsed [PathSegment] AST against a TreeValue decoded tree
//       and returns every matching (path, value) pair. The path in each match
//       records the concrete steps taken — name strings and integer indices —
//       so callers can render the normalized path and use it for provenance.
//
//       Multi-match semantics: wildcard and descendant segments may yield more
//       than one result. The evaluator collects all of them in document order
//       (the order keys appear in OrderedDictionary / array positions in order).
//
// Reference: RFC 9535 §2.3–§2.5 (https://www.rfc-editor.org/rfc/rfc9535)
//
// Upstream: JSONPathExpression (calls evaluate)
// Downstream: (none — produces [(path: ResolvedStep, value: TreeValue)] tuples)

import Collections

// MARK: - ResolvedStep

/// One concrete step in a fully-resolved match path.
///
/// Where a `Selector` in the AST may be abstract (e.g. `.wildcard`), a
/// `ResolvedStep` is always concrete: a key name or an integer index, exactly
/// as found in the `TreeValue` tree.
///
/// Callers use `ResolvedStep` arrays to render a `NormalizedPath` string and
/// to record provenance for fragment display names.
public enum ResolvedStep: Sendable, Equatable {
    /// A map key accessed by name.
    case key(String)
    /// An array element accessed by position.
    case index(Int)
}

// MARK: - JSONPathEvaluator

/// Evaluates a segment array against a `TreeValue` root and collects matches.
///
/// The evaluator is value-typed and stateless between calls: each call to
/// `evaluate(segments:on:)` starts fresh.
struct JSONPathEvaluator {

    // MARK: Entry point

    /// Evaluate `segments` against `root` and return all matching
    /// `(path, value)` pairs in document order.
    ///
    /// - Parameters:
    ///   - segments: The parsed path segments from `JSONPathParser`.
    ///   - root: The decoded `TreeValue` tree (entire document).
    /// - Returns: Every matching pair. An empty array means no match — not
    ///   an error.
    func evaluate(segments: [PathSegment], on root: TreeValue) -> [(path: [ResolvedStep], value: TreeValue)] {
        // Start with one node: the root, reached via an empty path.
        var currentSet: [(path: [ResolvedStep], value: TreeValue)] = [(path: [], value: root)]

        for segment in segments {
            var nextSet: [(path: [ResolvedStep], value: TreeValue)] = []
            for (path, node) in currentSet {
                switch segment {
                case let .child(selector):
                    nextSet.append(contentsOf: applySelector(selector, to: node, basePath: path))
                case let .descendant(selector):
                    nextSet.append(contentsOf: applyDescendant(selector, to: node, basePath: path))
                }
            }
            currentSet = nextSet
        }

        return currentSet
    }

    // MARK: - Child selector application

    /// Apply `selector` to a single node and return all matching children.
    ///
    /// For `.name`, at most one result (map key lookup). For `.index`, at most
    /// one result (array element lookup). For `.wildcard`, one result per
    /// direct child.
    private func applySelector(
        _ selector: Selector,
        to node: TreeValue,
        basePath: [ResolvedStep]
    ) -> [(path: [ResolvedStep], value: TreeValue)] {

        switch selector {

        case let .name(key):
            guard case let .map(dict) = node, let child = dict[key] else {
                return []
            }
            return [(path: basePath + [.key(key)], value: child)]

        case let .index(idx):
            guard case let .array(arr) = node, arr.indices.contains(idx) else {
                return []
            }
            return [(path: basePath + [.index(idx)], value: arr[idx])]

        case .wildcard:
            return wildcardChildren(of: node, basePath: basePath)
        }
    }

    // MARK: - Wildcard expansion

    /// Return every direct child of `node` with its concrete path step.
    private func wildcardChildren(
        of node: TreeValue,
        basePath: [ResolvedStep]
    ) -> [(path: [ResolvedStep], value: TreeValue)] {
        switch node {
        case let .map(dict):
            return dict.elements.map { (key, value) in
                (path: basePath + [.key(key)], value: value)
            }
        case let .array(arr):
            return arr.enumerated().map { (idx, value) in
                (path: basePath + [.index(idx)], value: value)
            }
        default:
            return []
        }
    }

    // MARK: - Descendant segment

    /// Apply `selector` to `node` and every descendant recursively (depth-
    /// first, children before deeper descendants — RFC 9535 §2.5.2 order).
    ///
    /// The selector is applied at each level; all matches accumulate.
    private func applyDescendant(
        _ selector: Selector,
        to node: TreeValue,
        basePath: [ResolvedStep]
    ) -> [(path: [ResolvedStep], value: TreeValue)] {
        var results: [(path: [ResolvedStep], value: TreeValue)] = []

        // Apply the selector at the current level.
        results.append(contentsOf: applySelector(selector, to: node, basePath: basePath))

        // Then recurse into children (document order).
        switch node {
        case let .map(dict):
            for (key, child) in dict.elements {
                let childPath = basePath + [.key(key)]
                results.append(contentsOf: applyDescendant(selector, to: child, basePath: childPath))
            }
        case let .array(arr):
            for (idx, child) in arr.enumerated() {
                let childPath = basePath + [.index(idx)]
                results.append(contentsOf: applyDescendant(selector, to: child, basePath: childPath))
            }
        default:
            break
        }

        return results
    }
}
