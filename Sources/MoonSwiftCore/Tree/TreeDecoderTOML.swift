// File: Sources/MoonSwiftCore/Tree/TreeDecoderTOML.swift
// Role: Decodes a TOML document into a TreeValue tree using TOMLKit.
// Upstream: (input — raw TOML text)
// Downstream: SourceStore (passes the tree to JSONPath evaluator)
//
// Key-order:
//   The underlying toml++ C++ library uses std::map for TOML tables, which
//   stores keys in alphabetical (lexicographic) order rather than insertion
//   order. As a result, TOMLKit's TOMLTable.keys are alphabetically sorted,
//   and the resulting OrderedDictionary reflects that order — NOT the
//   authored key insertion order.
//   Contrast with the JSON decoder (custom parser, preserves insertion order)
//   and the YAML decoder (Yams preserves mapping key order from the source).
//   This is a known limitation of the toml++ backend; upgrading to a version
//   of TOMLKit backed by a toml++ build that enables TOML_ENABLE_UNRELEASED_FEATURES
//   or an insertion-ordered map would resolve it.
//
// Dotted keys and arrays-of-tables:
//   TOMLKit decodes dotted keys (a.b.c = 1) and [[array-of-tables]] into
//   nested TOMLTable/TOMLArray structures, so the recursive converter
//   naturally produces the correct nested TreeValue.map/.array trees without
//   any special handling.
//
// DateTime values:
//   TOMLKit represents date/time values as TOMLDate, TOMLTime, and
//   TOMLDateTime. Per PRD F1.2 these are "non-string" (non-designatable)
//   values; they are decoded as .null so that the JSONPath evaluator can
//   identify them as non-string targets and produce the appropriate
//   diagnostic.

import Collections
import TOMLKit

// MARK: - Public entry point

/// Decodes a TOML document into a `TreeValue` tree.
///
/// Dotted keys and `[[array-of-tables]]` sections are decoded by TOMLKit into
/// their natural nested form and map directly to nested `.map` / `.array`
/// nodes.
///
/// TOML datetime values (`date`, `time`, `date-time`) produce `.null` because
/// they have no string representation in `TreeValue` and cannot be designated
/// as Lua field targets (PRD F1.2).
///
/// - Parameter text: A TOML document as a Swift `String`.
/// - Returns: The root `.map` `TreeValue` for the document.
/// - Throws: `TreeDecoderError.tomlMalformed` with a human-readable message
///           derived from `TOMLParseError`.
public func decodeTOML(_ text: String) throws -> TreeValue {
    let table: TOMLTable
    do {
        table = try TOMLTable(string: text)
    } catch let error as TOMLParseError {
        throw TreeDecoderError.tomlMalformed(error.description)
    } catch {
        throw TreeDecoderError.tomlMalformed(error.localizedDescription)
    }
    return tableToTreeValue(table)
}

// MARK: - TOMLValueConvertible → TreeValue conversion (internal)

/// Converts a `TOMLValueConvertible` (the TOMLKit generic value protocol) to a
/// `TreeValue`.
///
/// Both `TOMLTable` and `TOMLArray` iterators yield `any TOMLValueConvertible`,
/// so this function accepts the existential rather than the concrete `TOMLValue`
/// struct.
private func tomlValueToTreeValue(_ value: any TOMLValueConvertible) -> TreeValue {
    switch value.type {

    case .string:
        guard let s = value.string else { return .null }
        return .string(s)

    case .int:
        guard let i = value.int else { return .null }
        return .int(Int64(i))

    case .double:
        guard let d = value.double else { return .null }
        return .double(d)

    case .bool:
        guard let b = value.bool else { return .null }
        return .bool(b)

    case .array:
        guard let arr = value.array else { return .null }
        return arrayToTreeValue(arr)

    case .table:
        guard let tbl = value.table else { return .null }
        return tableToTreeValue(tbl)

    case .date, .time, .dateTime:
        // TOML datetime types have no string form in TreeValue.
        // Callers that receive .null for a TOML datetime field should
        // surface a "non-string, non-designatable" diagnostic (F1.4).
        return .null

    @unknown default:
        return .null
    }
}

/// Converts a `TOMLTable` to a `TreeValue.map`, preserving key order.
private func tableToTreeValue(_ table: TOMLTable) -> TreeValue {
    var dict = OrderedDictionary<String, TreeValue>()
    for (key, value) in table {
        dict[key] = tomlValueToTreeValue(value)
    }
    return .map(dict)
}

/// Converts a `TOMLArray` to a `TreeValue.array`.
private func arrayToTreeValue(_ array: TOMLArray) -> TreeValue {
    var elements: [TreeValue] = []
    elements.reserveCapacity(array.count)
    for value in array {
        elements.append(tomlValueToTreeValue(value))
    }
    return .array(elements)
}
