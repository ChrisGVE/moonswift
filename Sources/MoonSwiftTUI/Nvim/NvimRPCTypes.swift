// File: Sources/MoonSwiftTUI/Nvim/NvimRPCTypes.swift
// Location: Sources/MoonSwiftTUI/Nvim/
// Role: Wire-protocol value types for the msgpack-RPC client — the error type,
//       nvim handle wrappers, and the decoded-message enum with its parser.
//       Split out of NvimRPCClient.swift to keep the actor file within the
//       400-line codesize budget (coding.md §VIII) while preserving full docs.
//
// Architecture context (ARCHITECTURE.md §10.4.6):
//   The msgpack-RPC framing is the classic 4/3-element array protocol. nvim
//   sends responses ([1, msgid, error, result]) and notifications
//   ([2, method, params]); the client sends requests ([0, msgid, method, params])
//   and notifications. RawRPCMessage models the inbound side.
//
// Relationships:
//   → NvimRPCClient.swift: consumes these types (deliver/parse seam)

import Foundation
import MoonSwiftCore

// MARK: - Public error type

/// Errors thrown or surfaced by `NvimRPCClient`.
public enum NvimRPCError: Error, Sendable, Equatable {
    /// Attempt to send after the stdin pipe has been closed (stdinOpen == false).
    case connectionClosed
    /// nvim responded with a non-nil error field: `[1, msgid, error, .nil]`.
    case remoteError(MessagePackValue)
}

// MARK: - Wire protocol value types

/// A thin wrapper for a nvim buffer identifier.
public struct NvimBuffer: Sendable, Equatable {
    public let id: Int32
    public init(id: Int32) { self.id = id }
}

/// A thin wrapper for a nvim window identifier.
public struct NvimWindow: Sendable, Equatable {
    public let id: Int32
    public init(id: Int32) { self.id = id }
}

/// A decoded msgpack-RPC message received from nvim's stdout stream.
///
/// The wire format is:
///   Request (nvim→client, rare): `[0, msgid, method, params]`
///   Response (nvim→client):      `[1, msgid, error, result]`
///   Notification (nvim→client):  `[2, method, params]`
public enum RawRPCMessage: Sendable {
    /// A response to a prior client request.
    case response(msgid: Int, error: MessagePackValue, result: MessagePackValue)
    /// A server-initiated notification (e.g. redraw events).
    case notification(method: String, params: [MessagePackValue])
    /// A server-initiated request (nvim almost never sends these; decode but drop).
    case request(msgid: Int, method: String, params: [MessagePackValue])

    // MARK: Static parser

    /// Parse a top-level `MessagePackValue` (must be a 3- or 4-element array)
    /// into a `RawRPCMessage`. Returns nil for unrecognised shapes.
    public static func parse(from value: MessagePackValue) -> RawRPCMessage? {
        guard case .array(let arr) = value else { return nil }

        // Extract the integer type tag (element 0).
        let tag: Int64
        switch arr[0] {
        case .int(let t): tag = t
        case .uint(let t): tag = Int64(bitPattern: t)
        default: return nil
        }

        switch tag {
        case 0:
            // Request: [0, msgid, method, params]
            guard arr.count == 4 else { return nil }
            guard let msgid = intValue(arr[1]),
                case .string(let method) = arr[2],
                case .array(let params) = arr[3]
            else { return nil }
            return .request(msgid: msgid, method: method, params: params)

        case 1:
            // Response: [1, msgid, error, result]
            guard arr.count == 4 else { return nil }
            guard let msgid = intValue(arr[1]) else { return nil }
            return .response(msgid: msgid, error: arr[2], result: arr[3])

        case 2:
            // Notification: [2, method, params]
            guard arr.count == 3 else { return nil }
            guard case .string(let method) = arr[1],
                case .array(let params) = arr[2]
            else { return nil }
            return .notification(method: method, params: params)

        default:
            return nil
        }
    }

    // MARK: Private helpers

    /// Extract an Int from either `.int` or `.uint` (msgid is sometimes .uint(0)).
    private static func intValue(_ v: MessagePackValue) -> Int? {
        switch v {
        case .int(let i): return Int(i)
        case .uint(let u): return Int(exactly: u)
        default: return nil
        }
    }
}
