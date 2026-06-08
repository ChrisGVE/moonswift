// File: Tests/MoonSwiftCoreTests/Sources/SpanLocatorYAMLSemantics.swift
// Location: MoonSwiftCoreTests/Sources/
// Role: STEP 0 investigation — pins the exact byteRange semantics SpanLocator
//       returns for each YAML scalar kind (plain, single-quoted, double-quoted,
//       literal block, folded block) so SpanSplicer+YAML can rely on them.
//       These tests are assertions, not prints: they document what SpanLocator
//       actually returns and fail if the contract changes.
// Upstream: SpanLocator (subject under investigation)
// Downstream: SpanSplicer+YAML (relies on these contracts)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - Helpers

private func fixtureData(_ name: String) throws -> Data {
    let url = Bundle.module.url(
        forResource: name, withExtension: nil, subdirectory: "Fixtures/Sources"
    )!
    return try Data(contentsOf: url)
}

/// Return the UTF-8 bytes of `data[range]` as a string for diagnostic display.
private func slice(_ data: Data, _ range: Range<Int>) -> String {
    let safe = range.clamped(to: 0..<data.count)
    return String(data: data[safe], encoding: .utf8) ?? "<non-utf8>"
}

// MARK: - Plain scalar byteRange semantics

@Suite("SpanLocator YAML — plain scalar byteRange")
struct SpanLocatorYAMLPlainSemantics {

    // splice-yaml-plain.yaml:
    //   key: hello world       (offset 0)
    //   nested:\n              (offset 17)
    //     field: plain value   (offset 25)
    //     other: stays put
    //   top: unchanged

    @Test("plain scalar $.key byteRange covers text only (no quotes)")
    func plainScalarTopLevel() throws {
        let data = try fixtureData("splice-yaml-plain.yaml")
        let path: [ResolvedStep] = [.key("key")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        // "hello world" = 11 bytes
        #expect(loc.byteRange.count == 11)
        let text = slice(data, loc.byteRange)
        #expect(text == "hello world")
    }

    @Test("plain scalar $.nested.field byteRange covers text only")
    func plainScalarNested() throws {
        let data = try fixtureData("splice-yaml-plain.yaml")
        let path: [ResolvedStep] = [.key("nested"), .key("field")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        let text = slice(data, loc.byteRange)
        #expect(text == "plain value")
    }

    @Test("byte immediately before plain scalar byteRange is a space (not a quote)")
    func byteBeforePlainScalar() throws {
        let data = try fixtureData("splice-yaml-plain.yaml")
        let path: [ResolvedStep] = [.key("key")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        // Byte before the range must be ' ' (the space after the colon), not '"' or '\''
        let byteBeforeRange = loc.byteRange.lowerBound - 1
        #expect(byteBeforeRange >= 0)
        let prevByte = data[byteBeforeRange]
        #expect(prevByte == UInt8(ascii: " "))
    }
}

// MARK: - Quoted scalar byteRange semantics

@Suite("SpanLocator YAML — quoted scalar byteRange")
struct SpanLocatorYAMLQuotedSemantics {

    // splice-yaml-quoted.yaml:
    //   single: 'single quoted'
    //   double: "double quoted"
    //   nested:\n
    //     sq: 'inner single'
    //     dq: "inner double"

    @Test("single-quoted scalar $.single byteRange excludes surrounding single quotes")
    func singleQuotedTopLevel() throws {
        let data = try fixtureData("splice-yaml-quoted.yaml")
        let path: [ResolvedStep] = [.key("single")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        let text = slice(data, loc.byteRange)
        // SpanLocator strips single quote on each side; content = "single quoted"
        #expect(text == "single quoted")
        // Byte before range must be the opening single-quote
        #expect(loc.byteRange.lowerBound > 0)
        #expect(data[loc.byteRange.lowerBound - 1] == UInt8(ascii: "'"))
        // Byte after range must be the closing single-quote
        #expect(data[loc.byteRange.upperBound] == UInt8(ascii: "'"))
    }

    @Test("double-quoted scalar $.double byteRange excludes surrounding double quotes")
    func doubleQuotedTopLevel() throws {
        let data = try fixtureData("splice-yaml-quoted.yaml")
        let path: [ResolvedStep] = [.key("double")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        let text = slice(data, loc.byteRange)
        #expect(text == "double quoted")
        // Byte before range must be the opening double-quote
        #expect(data[loc.byteRange.lowerBound - 1] == UInt8(ascii: "\""))
        #expect(data[loc.byteRange.upperBound] == UInt8(ascii: "\""))
    }

    @Test("single-quoted nested $.nested.sq byteRange excludes quotes")
    func singleQuotedNested() throws {
        let data = try fixtureData("splice-yaml-quoted.yaml")
        let path: [ResolvedStep] = [.key("nested"), .key("sq")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        #expect(slice(data, loc.byteRange) == "inner single")
    }

    @Test("double-quoted nested $.nested.dq byteRange excludes quotes")
    func doubleQuotedNested() throws {
        let data = try fixtureData("splice-yaml-quoted.yaml")
        let path: [ResolvedStep] = [.key("nested"), .key("dq")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        #expect(slice(data, loc.byteRange) == "inner double")
    }
}

// MARK: - Block scalar byteRange semantics

@Suite("SpanLocator YAML — block scalar byteRange")
struct SpanLocatorYAMLBlockSemantics {

    // splice-yaml-block.yaml:
    //   literal: |-\n   (offset 0)
    //     line one\n
    //     line two\n
    //   folded: >-\n
    //     folded line\n
    //   nested:\n
    //     block: |\n
    //       indented content\n
    //       second line\n
    //   other: unchanged\n

    /// The byteRange for a block scalar covers the FULL block_scalar node:
    /// the indicator (`|-`, `>-`, `|`, `>`) on the key line THROUGH the last
    /// content line (NOT including the trailing newline of the last line,
    /// depending on grammar version).
    @Test("literal block scalar $.literal byteRange starts at the | indicator")
    func literalBlockStartsAtIndicator() throws {
        let data = try fixtureData("splice-yaml-block.yaml")
        let path: [ResolvedStep] = [.key("literal")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)

        // The first byte of the range must be '|' (the block indicator character)
        let firstByte = data[loc.byteRange.lowerBound]
        #expect(firstByte == UInt8(ascii: "|"))

        // The text of the full block scalar must include "line one" and "line two"
        let blockText = slice(data, loc.byteRange)
        #expect(blockText.contains("line one"))
        #expect(blockText.contains("line two"))
    }

    @Test("folded block scalar $.folded byteRange starts at the > indicator")
    func foldedBlockStartsAtIndicator() throws {
        let data = try fixtureData("splice-yaml-block.yaml")
        let path: [ResolvedStep] = [.key("folded")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)

        let firstByte = data[loc.byteRange.lowerBound]
        #expect(firstByte == UInt8(ascii: ">"))

        let blockText = slice(data, loc.byteRange)
        #expect(blockText.contains("folded line"))
    }

    @Test("nested block scalar $.nested.block byteRange starts at the | indicator")
    func nestedLiteralBlock() throws {
        let data = try fixtureData("splice-yaml-block.yaml")
        let path: [ResolvedStep] = [.key("nested"), .key("block")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)

        let firstByte = data[loc.byteRange.lowerBound]
        #expect(firstByte == UInt8(ascii: "|"))

        let blockText = slice(data, loc.byteRange)
        #expect(blockText.contains("indented content"))
        #expect(blockText.contains("second line"))
    }

    @Test("byte immediately before block scalar byteRange is a space (after colon+space)")
    func byteBeforeBlockScalar() throws {
        let data = try fixtureData("splice-yaml-block.yaml")
        let path: [ResolvedStep] = [.key("literal")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        // byte before block scalar = space after `: `
        let prevByte = data[loc.byteRange.lowerBound - 1]
        #expect(prevByte == UInt8(ascii: " "))
    }

    @Test("literal block scalar $.literal exact byteRange is 9..<33 (excludes trailing newline)")
    func literalBlockExactRange() throws {
        let data = try fixtureData("splice-yaml-block.yaml")
        let path: [ResolvedStep] = [.key("literal")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        // Byte 9 = '|', "|-\n  line one\n  line two" = 24 bytes => range 9..<33
        // tree-sitter YAML excludes the trailing newline after the last content line.
        #expect(loc.byteRange.lowerBound == 9)
        #expect(loc.byteRange.count == 24)  // "|-\n  line one\n  line two" without trailing \n
        // Byte immediately after the range must be '\n' (the newline excluded from the node)
        #expect(data[loc.byteRange.upperBound] == UInt8(ascii: "\n"))
        let blockText = slice(data, loc.byteRange)
        #expect(blockText == "|-\n  line one\n  line two")
    }

    @Test("nested block scalar $.nested.block exact range starts at byte 76")
    func nestedBlockExactRange() throws {
        let data = try fixtureData("splice-yaml-block.yaml")
        let path: [ResolvedStep] = [.key("nested"), .key("block")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path)
        #expect(loc.byteRange.lowerBound == 76)
        let blockText = slice(data, loc.byteRange)
        #expect(blockText.hasPrefix("|"))
        #expect(blockText.contains("indented content"))
        #expect(blockText.contains("second line"))
    }
}

// MARK: - Multi-document YAML

@Suite("SpanLocator YAML — multi-document")
struct SpanLocatorYAMLMultiDocSemantics {

    // multi.yaml:
    //   scripts:\n
    //     init: "print('doc0')"\n
    //   ---\n
    //   scripts:\n
    //     init: "print('doc1')"\n

    @Test("document 0 $.scripts.init resolves to doc0 value")
    func multiDocDocument0() throws {
        let data = try fixtureData("multi.yaml")
        let path: [ResolvedStep] = [.key("scripts"), .key("init")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path, document: 0)
        let text = slice(data, loc.byteRange)
        #expect(text == "print('doc0')")
    }

    @Test("document 1 $.scripts.init resolves to doc1 value")
    func multiDocDocument1() throws {
        let data = try fixtureData("multi.yaml")
        let path: [ResolvedStep] = [.key("scripts"), .key("init")]
        let loc = try SpanLocator.locateSpan(in: data, format: .yaml, path: path, document: 1)
        let text = slice(data, loc.byteRange)
        #expect(text == "print('doc1')")
    }
}
