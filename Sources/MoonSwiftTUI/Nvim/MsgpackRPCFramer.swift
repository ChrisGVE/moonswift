// File: Sources/MoonSwiftTUI/Nvim/MsgpackRPCFramer.swift
// Location: Sources/MoonSwiftTUI/Nvim/
// Role: Streaming msgpack-RPC frame decoder. nvim --embed writes a continuous
//       stream of length-self-describing msgpack values to its stdout pipe; the
//       reader thread pushes raw byte chunks here. The framer buffers partial
//       frames across pushes and emits each complete top-level MessagePackValue
//       in arrival order. Security caps (ARCHITECTURE.md §10.4.6, M10) bound a
//       hostile/buggy nvim: frame ≤ 16 MiB, nesting depth ≤ 64, declared
//       array/map element count ≤ 1 048 576.
//
// Architecture context (ARCHITECTURE.md §10.4.6 / §10.6 Security):
//   NvimRPCClient's reader Thread (nvim-rpc-class) calls push()/pushChecked()
//   with each read(2) chunk. The msgpack-rpc message is always a top-level
//   array ([type, msgid, …]); the framer is format-agnostic and simply emits
//   complete values. Cap violations throw FramerError; the client closes the
//   stdout pipe and posts AppEvent.nvimProcessExited(-1).
//
// Specifications:
//   msgpack format:   https://github.com/msgpack/msgpack/blob/master/spec.md
//   msgpack-RPC wire: https://github.com/msgpack-rpc/msgpack-rpc/blob/master/spec.md
//
// Design note — why a bespoke scanner rather than the vendored unpack() alone:
//   unpack() cannot distinguish "truncated, wait for more bytes" from "header
//   declares a multi-megabyte payload we must reject before reading it" — both
//   surface as MessagePackError.insufficientData. The scanner walks msgpack
//   headers to (a) find the byte length of one complete frame without requiring
//   the whole payload, and (b) reject oversize declarations from the header
//   alone. unpack() is then used only on a confirmed-complete byte prefix.

import Foundation
import MoonSwiftCore

/// A cap violation in the msgpack-RPC stream. Any case is fatal to the session:
/// the caller closes the stdout pipe and reports the process as exited.
enum FramerError: Error, Equatable {
    /// A frame's total byte length exceeds 16 MiB.
    case frameTooLarge
    /// A value's nesting depth exceeds 64.
    case depthExceeded
    /// A declared array/map element count exceeds 1 048 576.
    case elementCountExceeded
}

/// Buffers a msgpack byte stream and emits complete top-level values.
///
/// Value type with a single mutable `buffer` — the owning actor/thread holds one
/// instance and feeds it serially; it is never shared across threads.
struct MsgpackRPCFramer {

    /// Maximum total byte length of a single decoded frame.
    private static let maxFrameBytes = 16 * 1024 * 1024
    /// Maximum value nesting depth (top-level value is depth 1).
    private static let maxDepth = 64
    /// Maximum declared element count for any one array or map.
    private static let maxElements = 1_048_576

    /// Bytes received but not yet forming complete frames. A `[UInt8]` (not
    /// `Data`) so `removeFirst` re-bases indices to 0 — `Data.removeFirst`
    /// shifts `startIndex` instead, which would corrupt offset arithmetic.
    private var buffer: [UInt8] = []

    /// Append `data` and return every complete top-level value now decodable.
    /// Caps are enforced; a violation drops all output from this push (the
    /// session is doomed regardless). Use `pushChecked` to observe the error.
    mutating func push(_ data: Data) -> [MessagePackValue] {
        (try? pushChecked(data)) ?? []
    }

    /// Append `data` and return every complete top-level value now decodable,
    /// throwing `FramerError` on the first cap violation. Incomplete trailing
    /// bytes stay buffered for the next push.
    mutating func pushChecked(_ data: Data) throws -> [MessagePackValue] {
        buffer.append(contentsOf: data)

        var values: [MessagePackValue] = []
        while !buffer.isEmpty {
            // scan() returns the byte length of one complete frame at the front,
            // nil if more bytes are needed, or throws on a cap violation.
            guard let frameEnd = try scan(at: 0, depth: 1) else {
                break  // incomplete — wait for the next push
            }
            let frame = Data(buffer[0..<frameEnd])
            values.append(try unpackFirst(frame))
            buffer.removeFirst(frameEnd)
        }
        return values
    }

    /// Return the index just past the complete value beginning at `offset`, or
    /// nil if the buffer ends mid-value (need more bytes). Throws on cap breach.
    private func scan(at offset: Int, depth: Int) throws -> Int? {
        if depth > Self.maxDepth { throw FramerError.depthExceeded }
        guard offset < buffer.count else { return nil }

        let header = buffer[offset]
        let afterHeader = offset + 1

        // Reads a big-endian unsigned integer of `width` bytes at `pos`.
        // Returns nil (need more) if the buffer is too short.
        func readUInt(_ width: Int, at pos: Int) -> Int? {
            guard pos + width <= buffer.count else { return nil }
            var value = 0
            for i in 0..<width { value = (value << 8) | Int(buffer[pos + i]) }
            return value
        }

        // Validates and returns the end index of a `length`-byte payload whose
        // payload begins at `payloadStart`. nil if the payload is not yet fully
        // buffered. Throws frameTooLarge if the declared end exceeds the cap.
        func payloadEnd(payloadStart: Int, length: Int) throws -> Int? {
            let end = payloadStart + length
            if end > Self.maxFrameBytes { throw FramerError.frameTooLarge }
            return end <= buffer.count ? end : nil
        }

        switch header {
        // Single-byte values: fixint (pos/neg), nil, false, true.
        case 0x00...0x7f, 0xe0...0xff, 0xc0, 0xc2, 0xc3:
            return afterHeader

        // Fixed-width scalars: uint/int 8-64, float32/64.
        case 0xcc, 0xd0: return afterHeader + 1 <= buffer.count ? afterHeader + 1 : nil
        case 0xcd, 0xd1: return afterHeader + 2 <= buffer.count ? afterHeader + 2 : nil
        case 0xce, 0xd2, 0xca: return afterHeader + 4 <= buffer.count ? afterHeader + 4 : nil
        case 0xcf, 0xd3, 0xcb: return afterHeader + 8 <= buffer.count ? afterHeader + 8 : nil

        // fixstr.
        case 0xa0...0xbf:
            return try payloadEnd(payloadStart: afterHeader, length: Int(header - 0xa0))

        // str8 / bin8 (1-byte length).
        case 0xd9, 0xc4:
            guard let len = readUInt(1, at: afterHeader) else { return nil }
            return try payloadEnd(payloadStart: afterHeader + 1, length: len)
        // str16 / bin16 (2-byte length).
        case 0xda, 0xc5:
            guard let len = readUInt(2, at: afterHeader) else { return nil }
            return try payloadEnd(payloadStart: afterHeader + 2, length: len)
        // str32 / bin32 (4-byte length).
        case 0xdb, 0xc6:
            guard let len = readUInt(4, at: afterHeader) else { return nil }
            return try payloadEnd(payloadStart: afterHeader + 4, length: len)

        // fixext 1/2/4/8/16: 1 type byte + (1<<(header-0xd4)) data bytes.
        case 0xd4...0xd8:
            let dataLen = 1 << Int(header - 0xd4)
            return try payloadEnd(payloadStart: afterHeader + 1, length: dataLen)
        // ext8/16/32: length, 1 type byte, then data.
        case 0xc7:
            guard let len = readUInt(1, at: afterHeader) else { return nil }
            return try payloadEnd(payloadStart: afterHeader + 1 + 1, length: len)
        case 0xc8:
            guard let len = readUInt(2, at: afterHeader) else { return nil }
            return try payloadEnd(payloadStart: afterHeader + 2 + 1, length: len)
        case 0xc9:
            guard let len = readUInt(4, at: afterHeader) else { return nil }
            return try payloadEnd(payloadStart: afterHeader + 4 + 1, length: len)

        // fixarray.
        case 0x90...0x9f:
            return try scanChildren(
                at: afterHeader, count: Int(header - 0x90), depth: depth, isMap: false)
        // fixmap.
        case 0x80...0x8f:
            return try scanChildren(
                at: afterHeader, count: Int(header - 0x80), depth: depth, isMap: true)
        // array16 / array32.
        case 0xdc:
            guard let count = readUInt(2, at: afterHeader) else { return nil }
            if count > Self.maxElements { throw FramerError.elementCountExceeded }
            return try scanChildren(at: afterHeader + 2, count: count, depth: depth, isMap: false)
        case 0xdd:
            guard let count = readUInt(4, at: afterHeader) else { return nil }
            if count > Self.maxElements { throw FramerError.elementCountExceeded }
            return try scanChildren(at: afterHeader + 4, count: count, depth: depth, isMap: false)
        // map16 / map32.
        case 0xde:
            guard let count = readUInt(2, at: afterHeader) else { return nil }
            if count > Self.maxElements { throw FramerError.elementCountExceeded }
            return try scanChildren(at: afterHeader + 2, count: count, depth: depth, isMap: true)
        case 0xdf:
            guard let count = readUInt(4, at: afterHeader) else { return nil }
            if count > Self.maxElements { throw FramerError.elementCountExceeded }
            return try scanChildren(at: afterHeader + 4, count: count, depth: depth, isMap: true)

        // 0xc1 is reserved/never-emitted; treat as a 1-byte frame and let
        // unpackFirst surface MessagePackError.invalidData on decode.
        default:
            return afterHeader
        }
    }

    /// Scan `count` children (×2 for maps) starting at `start`, recursing one
    /// depth deeper. Returns the index past the last child, nil if incomplete.
    private func scanChildren(at start: Int, count: Int, depth: Int, isMap: Bool) throws -> Int? {
        var pos = start
        let total = isMap ? count * 2 : count
        for _ in 0..<total {
            guard let next = try scan(at: pos, depth: depth + 1) else { return nil }
            pos = next
            if pos > Self.maxFrameBytes { throw FramerError.frameTooLarge }
        }
        return pos
    }
}
