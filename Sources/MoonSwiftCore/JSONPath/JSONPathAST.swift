// File: Sources/MoonSwiftCore/JSONPath/JSONPathAST.swift
// Role: Typed abstract syntax tree (AST) for the RFC 9535 JSONPath subset
//       supported in MoonSwift P1. The parser produces a [PathSegment] array;
//       the evaluator traverses it against a TreeValue decoded tree.
//
//       A JSONPath expression is a root `$` followed by zero or more segments.
//       Each segment is either a child segment or a descendant segment, and each
//       carries one selector.
//
// Reference: RFC 9535 §2.1–§2.4 (https://www.rfc-editor.org/rfc/rfc9535)
//
// Upstream: JSONPathParser (produces), JSONPathEvaluator (consumes)
// Downstream: JSONPathExpression

// MARK: - PathSegment

/// One step in a parsed JSONPath expression.
///
/// Each segment advances one level of the `TreeValue` tree. A child segment
/// steps down by one level; a descendant segment descends recursively into all
/// children first and then applies the selector.
///
/// RFC 9535 §2.5 defines descendant segments with the `..` shorthand.
enum PathSegment: Sendable, Equatable {

    /// A child step — match direct children of the current node set.
    ///
    /// Examples: `$.name` → `.child(.name("name"))`;
    ///           `$.a[0]` → `.child(.name("a"))`, `.child(.index(0))`.
    case child(Selector)

    /// A descendant step — recursively match the selector against the current
    /// node and all of its descendants (breadth-first per RFC 9535 §2.5.2).
    ///
    /// Example: `$..name` → `.descendant(.name("name"))`.
    case descendant(Selector)
}

// MARK: - Selector

/// The selector applied by a `PathSegment`.
///
/// RFC 9535 §2.3 defines five selector kinds. This subset implements four;
/// filter selectors and slices are rejected at parse time.
enum Selector: Sendable, Equatable {

    /// Match a single key in a map node.
    ///
    /// Produced by dot notation (`$.key`) and bracket notation (`$['key']`).
    case name(String)

    /// Match a single element in an array node by non-negative position.
    ///
    /// Produced by `$[0]`, `$.a[2]`, etc.
    case index(Int)

    /// Match all direct children (keys of a map, or all elements of an array).
    ///
    /// Produced by `.*` or `[*]`.
    case wildcard
}
