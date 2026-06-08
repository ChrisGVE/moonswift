// File: Tests/MoonSwiftCoreTests/MessagePackValueTests.swift
// Location: Tests/MoonSwiftCoreTests/
// Role: Round-trip tests for the vendored MessagePackValue codec (pack/unpack
//       identity for all types including ext handles used by nvim RPC).
// Upstream: Sources/MoonSwiftCore/Vendor/MessagePackValue/
// Downstream: MsgpackRPCFramer (framing layer), NvimRPCClient (RPC layer)

import Foundation
import Testing

@testable import MoonSwiftCore

// MARK: - nil / bool

@Suite("MessagePackValue round-trips")
struct MessagePackValueRoundTripTests {

    @Test("nil round-trips")
    func nilRoundTrip() throws {
        let packed = pack(.nil)
        let (value, remainder) = try unpack(packed)
        #expect(value == .nil)
        #expect(remainder.isEmpty)
    }

    @Test("bool true round-trips")
    func boolTrueRoundTrip() throws {
        let packed = pack(.bool(true))
        let value = try unpackFirst(packed)
        #expect(value == .bool(true))
    }

    @Test("bool false round-trips")
    func boolFalseRoundTrip() throws {
        let packed = pack(.bool(false))
        let value = try unpackFirst(packed)
        #expect(value == .bool(false))
    }

    // MARK: - integers

    @Test("positive int round-trips (fixint)")
    func positiveIntFixint() throws {
        let packed = pack(.int(42))
        let value = try unpackFirst(packed)
        // fixint encodes to uint
        #expect(value == .uint(42))
    }

    @Test("negative int round-trips")
    func negativeInt() throws {
        let packed = pack(.int(-1))
        let value = try unpackFirst(packed)
        #expect(value == .int(-1))
    }

    @Test("large negative int64 round-trips")
    func largeNegativeInt64() throws {
        let v = Int64.min
        let packed = pack(.int(v))
        let value = try unpackFirst(packed)
        #expect(value == .int(v))
    }

    @Test("uint round-trips")
    func uintRoundTrip() throws {
        let v = UInt64.max
        let packed = pack(.uint(v))
        let value = try unpackFirst(packed)
        #expect(value == .uint(v))
    }

    // MARK: - floats

    @Test("float round-trips")
    func floatRoundTrip() throws {
        let packed = pack(.float(3.14))
        let value = try unpackFirst(packed)
        if case .float(let f) = value {
            #expect(abs(f - 3.14) < 0.001)
        } else {
            Issue.record("Expected .float, got \(value)")
        }
    }

    @Test("double round-trips")
    func doubleRoundTrip() throws {
        let packed = pack(.double(3.141592653589793))
        let value = try unpackFirst(packed)
        #expect(value == .double(3.141592653589793))
    }

    // MARK: - string / binary

    @Test("empty string round-trips")
    func emptyString() throws {
        let packed = pack(.string(""))
        let value = try unpackFirst(packed)
        #expect(value == .string(""))
    }

    @Test("ascii string round-trips")
    func asciiString() throws {
        let packed = pack(.string("hello"))
        let value = try unpackFirst(packed)
        #expect(value == .string("hello"))
    }

    @Test("unicode string round-trips")
    func unicodeString() throws {
        let s = "🚀 nvim"
        let packed = pack(.string(s))
        let value = try unpackFirst(packed)
        #expect(value == .string(s))
    }

    @Test("binary data round-trips")
    func binaryData() throws {
        let bytes = Data([0x00, 0xff, 0x7f, 0x80])
        let packed = pack(.binary(bytes))
        let value = try unpackFirst(packed)
        #expect(value == .binary(bytes))
    }

    // MARK: - array / map

    @Test("empty array round-trips")
    func emptyArray() throws {
        let packed = pack(.array([]))
        let value = try unpackFirst(packed)
        #expect(value == .array([]))
    }

    @Test("heterogeneous array round-trips")
    func heterogeneousArray() throws {
        let arr: MessagePackValue = .array([.nil, .bool(true), .int(7), .string("x")])
        let packed = pack(arr)
        let value = try unpackFirst(packed)
        #expect(value == arr)
    }

    @Test("nested array round-trips")
    func nestedArray() throws {
        let inner: MessagePackValue = .array([.uint(1), .uint(2)])
        let outer: MessagePackValue = .array([inner, .string("outer")])
        let packed = pack(outer)
        let value = try unpackFirst(packed)
        #expect(value == outer)
    }

    @Test("map round-trips")
    func mapRoundTrip() throws {
        let m: MessagePackValue = .map([.string("key"): .int(99)])
        let packed = pack(m)
        let value = try unpackFirst(packed)
        #expect(value == m)
    }

    // MARK: - ext types (nvim handles: Buffer=ext0, Window=ext1, Tabpage=ext2)

    @Test("ext type 0 (nvim Buffer) round-trips with fixext1")
    func extType0Buffer() throws {
        let payload = Data([0x01])
        let packed = pack(.extended(0, payload))
        let value = try unpackFirst(packed)
        #expect(value == .extended(0, payload))
    }

    @Test("ext type 1 (nvim Window) round-trips with fixext1")
    func extType1Window() throws {
        let payload = Data([0x02])
        let packed = pack(.extended(1, payload))
        let value = try unpackFirst(packed)
        #expect(value == .extended(1, payload))
    }

    @Test("ext type 2 (nvim Tabpage) round-trips with fixext1")
    func extType2Tabpage() throws {
        let payload = Data([0x00])
        let packed = pack(.extended(2, payload))
        let value = try unpackFirst(packed)
        #expect(value == .extended(2, payload))
    }

    @Test("ext type 0 with fixext2 payload round-trips")
    func extType0Fixext2() throws {
        let payload = Data([0x00, 0x01])
        let packed = pack(.extended(0, payload))
        let value = try unpackFirst(packed)
        #expect(value == .extended(0, payload))
    }

    @Test("ext with variable-length payload round-trips")
    func extVariableLength() throws {
        let payload = Data(repeating: 0xab, count: 10)
        let packed = pack(.extended(0, payload))
        let value = try unpackFirst(packed)
        #expect(value == .extended(0, payload))
    }

    // MARK: - unpackAll (concatenated messages)

    @Test("unpackAll decodes two concatenated messages")
    func unpackAllTwo() throws {
        let d1 = pack(.string("a"))
        let d2 = pack(.int(1))
        let values = try unpackAll(d1 + d2)
        #expect(values.count == 2)
        #expect(values[0] == .string("a"))
        #expect(values[1] == .uint(1))
    }

    // MARK: - insufficient data

    @Test("unpack throws insufficientData on truncated input")
    func insufficientData() {
        // Pack a 5-element array, then truncate to 2 bytes
        let packed = pack(.array([.int(1), .int(2), .int(3), .int(4), .int(5)]))
        let truncated = packed.prefix(2)
        #expect(throws: MessagePackError.insufficientData) {
            _ = try unpackFirst(Data(truncated))
        }
    }
}
