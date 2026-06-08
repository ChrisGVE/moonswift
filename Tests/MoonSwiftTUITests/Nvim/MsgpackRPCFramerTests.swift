// File: Tests/MoonSwiftTUITests/Nvim/MsgpackRPCFramerTests.swift
// Location: Tests/MoonSwiftTUITests/Nvim/
// Role: Unit tests for MsgpackRPCFramer — streaming msgpack-RPC decoder with
//       security caps (16 MiB frame, 64 depth, 1 048 576 element count).
// Upstream: Sources/MoonSwiftTUI/Nvim/MsgpackRPCFramer.swift
// Downstream: NvimRPCClient (reader thread pushes bytes; actor receives values)

import Foundation
import Testing

@testable import MoonSwiftCore
@testable import MoonSwiftTUI

// MARK: - Helpers

/// Build raw msgpack bytes for a 4-element nvim-RPC-style notification array:
/// [type=2, msgid=0, method, params]
private func notificationBytes(method: String, params: MessagePackValue) -> Data {
    let msg: MessagePackValue = .array([
        .uint(2),
        .uint(0),
        .string(method),
        params,
    ])
    return pack(msg)
}

/// Build a fixarray header byte for an array of `count` elements (count ≤ 15).
private func fixarrayHeader(_ count: UInt8) -> UInt8 {
    return 0x90 | count
}

// MARK: - Framer tests

@Suite("MsgpackRPCFramer")
struct MsgpackRPCFramerTests {

    // MARK: Single complete message

    @Test("single complete message decodes in one push")
    func singleMessageOneShot() {
        var framer = MsgpackRPCFramer()
        let bytes = notificationBytes(method: "test", params: .array([]))
        let decoded = framer.push(bytes)
        #expect(decoded.count == 1)
        guard case .array(let top) = decoded[0] else {
            Issue.record("Expected .array at top level")
            return
        }
        #expect(top.count == 4)
        #expect(top[0] == .uint(2))  // notification type
        #expect(top[2] == .string("test"))
    }

    // MARK: Split delivery

    @Test("message split across two pushes buffers then completes")
    func splitMessageBuffers() {
        var framer = MsgpackRPCFramer()
        let bytes = notificationBytes(method: "split", params: .array([.int(42)]))

        // Push all but the last byte — should yield nothing
        let partial = bytes.dropLast()
        let first = framer.push(Data(partial))
        #expect(first.isEmpty, "Incomplete message must not be emitted")

        // Push the final byte — now the message completes
        let last = framer.push(bytes.suffix(1))
        #expect(last.count == 1)
        guard case .array(let top) = last[0] else {
            Issue.record("Expected .array after completion")
            return
        }
        #expect(top[2] == .string("split"))
    }

    // MARK: Two concatenated messages in one push

    @Test("two concatenated messages in one push both decode")
    func twoMessagesOnePush() {
        var framer = MsgpackRPCFramer()
        let m1 = notificationBytes(method: "first", params: .array([]))
        let m2 = notificationBytes(method: "second", params: .array([.bool(true)]))
        let decoded = framer.push(m1 + m2)
        #expect(decoded.count == 2)
        if case .array(let t1) = decoded[0] {
            #expect(t1[2] == .string("first"))
        } else {
            Issue.record("Expected .array for first message")
        }
        if case .array(let t2) = decoded[1] {
            #expect(t2[2] == .string("second"))
        } else {
            Issue.record("Expected .array for second message")
        }
    }

    // MARK: Truncated trailing message stays buffered

    @Test("truncated trailing message stays buffered and completes later")
    func truncatedTrailingBuffered() {
        var framer = MsgpackRPCFramer()
        let m1 = notificationBytes(method: "complete", params: .array([]))
        let m2 = notificationBytes(method: "incomplete", params: .array([.int(7)]))

        // Send m1 + partial m2
        let partial = Data((m1 + m2).dropLast())
        let first = framer.push(partial)
        #expect(first.count == 1, "Only the complete first message should be emitted")

        // Complete m2
        let finalByte = Data([m2.last!])
        let second = framer.push(finalByte)
        #expect(second.count == 1)
        if case .array(let top) = second[0] {
            #expect(top[2] == .string("incomplete"))
        } else {
            Issue.record("Expected .array for second message")
        }
    }

    // MARK: Cap violations

    @Test("oversized declared array count exceeds element cap")
    func elementCountCapViolation() {
        // Build a fixarray16 header claiming > 1_048_576 elements.
        // Format: 0xdd = array32, then 4-byte count = 1_048_577
        var bytes = Data([0xdd])
        let count: UInt32 = 1_048_577
        bytes.append(UInt8((count >> 24) & 0xff))
        bytes.append(UInt8((count >> 16) & 0xff))
        bytes.append(UInt8((count >> 8) & 0xff))
        bytes.append(UInt8(count & 0xff))
        // No actual elements — framer must reject on declared count alone

        var framer = MsgpackRPCFramer()
        #expect(throws: FramerError.self) {
            _ = try framer.pushChecked(bytes)
        }
    }

    @Test("deeply nested value exceeds depth cap")
    func depthCapViolation() {
        // Build 65 nested fixarray(1) wrappers around nil.
        // Each fixarray(1) = 0x91, and nil = 0xc0.
        // Depth 64 is the limit; 65 levels must be rejected.
        var bytes = Data()
        for _ in 0..<65 {
            bytes.append(0x91)  // fixarray count=1
        }
        bytes.append(0xc0)  // nil leaf

        var framer = MsgpackRPCFramer()
        #expect(throws: FramerError.self) {
            _ = try framer.pushChecked(bytes)
        }
    }

    @Test("frame exceeding 16 MiB is rejected")
    func frameSizeCapViolation() {
        // Build a binary blob declared as 16 MiB + 1 byte.
        // bin32 header: 0xc6, then 4-byte length = 16*1024*1024 + 1
        let limit = 16 * 1024 * 1024 + 1
        var bytes = Data([0xc6])
        let len = UInt32(limit)
        bytes.append(UInt8((len >> 24) & 0xff))
        bytes.append(UInt8((len >> 16) & 0xff))
        bytes.append(UInt8((len >> 8) & 0xff))
        bytes.append(UInt8(len & 0xff))
        // Do not append actual payload — cap fires on the declared length alone

        var framer = MsgpackRPCFramer()
        #expect(throws: FramerError.self) {
            _ = try framer.pushChecked(bytes)
        }
    }

    // MARK: Nvim redraw notification end-to-end

    @Test("nvim redraw notification with grid_line and flush decodes correctly")
    func nvimRedrawNotificationDecode() {
        // Build: [2, "redraw", [["grid_line", [grid, row, col, [["x", 0, 1]]]], ["flush"]]]
        // This proves nested array + ext-embedded notification decode end-to-end
        // at the framer/[MessagePackValue] level (no NvimRedrawEvent parsing).
        let cellArray: MessagePackValue = .array([
            .array([.string("x"), .uint(0), .uint(1)])
        ])
        let gridLineEvent: MessagePackValue = .array([
            .string("grid_line"),
            .uint(1),  // grid
            .uint(0),  // row
            .uint(0),  // colStart
            cellArray,
        ])
        let flushEvent: MessagePackValue = .array([.string("flush")])
        let redrawParams: MessagePackValue = .array([gridLineEvent, flushEvent])
        let notification: MessagePackValue = .array([
            .uint(2),
            .uint(0),
            .string("redraw"),
            .array([redrawParams]),
        ])

        let bytes = pack(notification)
        var framer = MsgpackRPCFramer()
        let decoded = framer.push(bytes)

        #expect(decoded.count == 1)
        guard case .array(let top) = decoded[0], top.count == 4 else {
            Issue.record("Expected 4-element top-level array")
            return
        }
        #expect(top[2] == .string("redraw"))

        // Validate inner structure is preserved
        guard case .array(let outerBatch) = top[3],
            let firstBatch = outerBatch.first,
            case .array(let batchEvents) = firstBatch
        else {
            Issue.record("Expected nested redraw batch array")
            return
        }
        #expect(batchEvents.count == 2)

        // First event is grid_line
        if case .array(let gridLine) = batchEvents[0] {
            #expect(gridLine[0] == .string("grid_line"))
        } else {
            Issue.record("Expected grid_line array")
        }

        // Last event is flush
        if case .array(let flush) = batchEvents[1] {
            #expect(flush[0] == .string("flush"))
        } else {
            Issue.record("Expected flush array")
        }
    }
}
