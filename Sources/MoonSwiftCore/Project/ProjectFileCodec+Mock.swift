// File: Sources/MoonSwiftCore/Project/ProjectFileCodec+Mock.swift
// Location: MoonSwiftCore/Project/
// Role: Mock-table decode and encode helpers for ProjectFileCodec (F5.5).
//       Factored into a separate file to keep ProjectFileCodec.swift under
//       the 400-line size limit. This file owns the TOML ↔ MockStore
//       translation and emits diagnostics for unknown `type`/`behavior`
//       string values and missing `writable` booleans — rules whose raw
//       string evidence is visible only at decode time.
//
//       Division of labour between codec and validation (F5.5):
//         CODEC   — raw-string checks: unknown type, unknown behavior,
//                   writable not-boolean. These require the raw TOML value
//                   that is lost after decoding.
//         VALIDATION — semantic checks: empty namespace/name, duplicate key,
//                   reserved prefix, catalog collision, conditional fields,
//                   syntax pre-pass. These operate on the decoded model.
//
//       TOMLKit [[array-of-tables]] decoding:
//         `[[mock.value]]` is a sub-array under the top-level `"mock"` table.
//         TOMLKit represents it as `table["mock"]?.table?["value"]?.array`.
//         Each element is a `TOMLTable`; entries missing required TOML keys
//         are silently skipped (the incomplete entry is not loaded — it cannot
//         be meaningfully represented in the model).
//
//       Encode: rebuilds the mock table from scratch on each save (mirrors
//         the `[run]`/`[lint]`/`[settings]` pattern).
//
//       Conditional-field encoding (DATA-06): `returnValue` and `errorMessage`
//         are `String?`; a nil field is OMITTED from the encoded TOML rather
//         than written as an empty string.
//
// Upstream: TOMLKit, MockStore, MockValueDef, MockFunctionDef, MockValueType,
//           MockBehavior, Diagnostic
// Downstream: ProjectFileCodec.decode / .save

import Foundation
import TOMLKit

// MARK: - ProjectFileCodecMock

/// Stateless helper — all methods are static. Called exclusively by
/// `ProjectFileCodec.decode` and `ProjectFileCodec.save`.
enum ProjectFileCodecMock {

    // MARK: - Decode

    /// Decodes `[[mock.value]]` and `[[mock.function]]` arrays-of-tables from
    /// the top-level TOMLKit document tree.
    ///
    /// Returns the decoded `MockStore` plus any diagnostics for raw-string
    /// violations (unknown `type`, unknown `behavior`, `writable` not boolean).
    /// Semantic validation (empty name, duplicates, catalog collision, etc.)
    /// is handled separately by `ProjectValidation+Mock.swift`.
    static func decodeMockStore(
        from table: TOMLTable
    ) -> (store: MockStore, diagnostics: [Diagnostic]) {
        guard let mockTable = table["mock"]?.table else {
            return (.empty, [])
        }

        var diagnostics: [Diagnostic] = []
        let values = decodeMockValues(from: mockTable, diagnostics: &diagnostics)
        let functions = decodeMockFunctions(from: mockTable, diagnostics: &diagnostics)
        return (MockStore(values: values, functions: functions), diagnostics)
    }

    private static func decodeMockValues(
        from mockTable: TOMLTable,
        diagnostics: inout [Diagnostic]
    ) -> [MockValueDef] {
        guard let array = mockTable["value"]?.array else { return [] }
        var results: [MockValueDef] = []

        for index in 0..<array.count {
            guard let entry = array[index]?.table else { continue }

            // Required string fields — skip entries missing any of them.
            guard let namespace = entry["namespace"]?.string,
                let path = entry["path"]?.string,
                let typeRaw = entry["type"]?.string,
                let value = entry["value"]?.string
            else { continue }

            // `writable` must be a TOML boolean. A non-boolean value (e.g. a
            // string "true") is rejected here with the binding diagnostic.
            guard let writable = decodeWritable(entry: entry, diagnostics: &diagnostics)
            else { continue }

            // Unknown `type` string: emit diagnostic and use `.string` as safe fallback
            // so the rest of the entry is still decoded and further rules can fire.
            let valueType: MockValueType
            if let known = MockValueType(rawValue: typeRaw) {
                valueType = known
            } else {
                diagnostics.append(
                    .projectError(
                        "unknown mock type \"\(typeRaw)\" \u{2014} "
                            + "expected string | number | boolean | table | expr"
                    )
                )
                valueType = .string  // safe fallback
            }

            results.append(
                MockValueDef(
                    namespace: namespace,
                    path: path,
                    type: valueType,
                    value: value,
                    writable: writable
                )
            )
        }
        return results
    }

    private static func decodeMockFunctions(
        from mockTable: TOMLTable,
        diagnostics: inout [Diagnostic]
    ) -> [MockFunctionDef] {
        guard let array = mockTable["function"]?.array else { return [] }
        var results: [MockFunctionDef] = []

        for index in 0..<array.count {
            guard let entry = array[index]?.table else { continue }

            // Required fields.
            guard let name = entry["name"]?.string,
                let behaviorRaw = entry["behavior"]?.string
            else { continue }

            // Unknown `behavior` string: emit diagnostic and use `.echoArgs` as safe fallback.
            let behavior: MockBehavior
            if let known = MockBehavior(rawValue: behaviorRaw) {
                behavior = known
            } else {
                diagnostics.append(
                    .projectError(
                        "unknown mock behavior \"\(behaviorRaw)\" \u{2014} "
                            + "expected echo-args | fixed-return | raise-error"
                    )
                )
                behavior = .echoArgs  // safe fallback
            }

            // Conditional fields — present only for their specific behavior.
            let returnValue = entry["return_value"]?.string
            let errorMessage = entry["error_message"]?.string

            results.append(
                MockFunctionDef(
                    name: name,
                    behavior: behavior,
                    returnValue: returnValue,
                    errorMessage: errorMessage
                )
            )
        }
        return results
    }

    /// Reads `writable` from a mock-value entry, emitting the binding diagnostic
    /// when the TOML value is present but not a boolean type.
    ///
    /// Returns `nil` when the key is absent or has the wrong type; returns the
    /// bool when present and correctly typed.
    private static func decodeWritable(
        entry: TOMLTable,
        diagnostics: inout [Diagnostic]
    ) -> Bool? {
        // If the key is absent entirely, skip the entry (required field).
        guard entry["writable"] != nil else { return nil }
        // If the key is present but not a TOML boolean, emit the binding diagnostic.
        guard let writable = entry["writable"]?.bool else {
            diagnostics.append(.projectError("mock writable must be a boolean"))
            return nil
        }
        return writable
    }

    // MARK: - Encode

    /// Writes `store` into the `"mock"` sub-table of `table`.
    ///
    /// If `store` is empty, the `"mock"` key is removed from `table` so no
    /// spurious empty table appears in the TOML output.
    static func encodeMockStore(_ store: MockStore, into table: TOMLTable) {
        guard !store.isEmpty else {
            table["mock"] = nil
            return
        }

        let mockTable = TOMLTable()
        mockTable["value"] = TOMLValue(buildMockValueArray(store.values))
        mockTable["function"] = TOMLValue(buildMockFunctionArray(store.functions))
        table["mock"] = TOMLValue(mockTable)
    }

    private static func buildMockValueArray(_ values: [MockValueDef]) -> TOMLArray {
        let array = TOMLArray()
        for def in values {
            let entry = TOMLTable()
            entry["namespace"] = TOMLValue(stringLiteral: def.namespace)
            entry["path"] = TOMLValue(stringLiteral: def.path)
            entry["type"] = TOMLValue(stringLiteral: def.type.rawValue)
            entry["value"] = TOMLValue(stringLiteral: def.value)
            entry["writable"] = TOMLValue(booleanLiteral: def.writable)
            array.append(TOMLValue(entry))
        }
        return array
    }

    private static func buildMockFunctionArray(_ functions: [MockFunctionDef]) -> TOMLArray {
        let array = TOMLArray()
        for def in functions {
            let entry = TOMLTable()
            entry["name"] = TOMLValue(stringLiteral: def.name)
            entry["behavior"] = TOMLValue(stringLiteral: def.behavior.rawValue)
            // DATA-06: omit nil conditional fields — never write empty strings.
            if let rv = def.returnValue {
                entry["return_value"] = TOMLValue(stringLiteral: rv)
            }
            if let em = def.errorMessage {
                entry["error_message"] = TOMLValue(stringLiteral: em)
            }
            array.append(TOMLValue(entry))
        }
        return array
    }
}
