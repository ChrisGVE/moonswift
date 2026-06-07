// File: Sources/MoonSwiftCore/Sources/FragmentProvenance.swift
// Location: MoonSwiftCore/Sources/
// Role: Provenance model for a loaded Lua source fragment — the binding link
//       between a fragment's decoded text and its position in the original
//       on-disk file. Carries the byte span, line offset, content hash, and
//       the computed display name (F1.2 convention). All five features that
//       consume provenance (navigator labels, diagnostics, run line-mapping,
//       F6 breakpoints, F8 write-back conflict guard) read from this single type.
// Upstream: SourceStore (produces), CryptoKit (SHA256)
// Downstream: LuaSourceFragment, RunService, LintService, Renderer, AppState
//             (via SourceState), SourceLoadEvent

import CryptoKit
import Foundation

// MARK: - FragmentProvenance

/// Positional and identity metadata for one Lua source fragment.
///
/// All location fields (`byteRange`, `lineOffset`) refer to the file bytes as
/// they existed at load time. The `contentHash` guards against external
/// modification between load and write-back (F8). The `displayName` computed
/// property implements the F1.2 display-name convention: it is derived
/// deterministically from `file` and `jsonpath` and therefore cannot drift out
/// of sync with its inputs (ARCHITECTURE.md §4.3).
///
/// **For whole `.lua` files:**
/// - `jsonpath` is `nil`
/// - `document` is `0`
/// - `byteRange` spans the entire file (`0..<fileByteCount`)
/// - `lineOffset` is `0` (fragment line 1 = file line 1)
/// - `displayName` is the filename (last path component)
///
/// **For structured-file fields (task 16):**
/// - `jsonpath` holds the normalized path (e.g. `"$.scripts.init"`)
/// - `document` is the YAML multi-document index
/// - `byteRange` and `lineOffset` locate the field's value inside the file
/// - `displayName` is `<filename>:<normalized-jsonpath>`
public struct FragmentProvenance: Sendable, Equatable {

    // MARK: Stored fields

    /// Absolute URL to the source file on disk.
    public let file: URL

    /// Normalized RFC 9535 JSONPath expression that selected this fragment.
    /// `nil` for whole `.lua` files; non-nil for structured-file fields
    /// (task 16 populates this for JSON/YAML/TOML sources).
    public let jsonpath: String?

    /// YAML multi-document index. Always `0` for JSON, TOML, and `.lua` files.
    public let document: Int

    /// Byte range of the fragment's value content in the original file.
    ///
    /// For a whole `.lua` file this is `0..<data.count` (the entire file).
    /// For a structured-file field this is the byte extent of the string value,
    /// excluding any surrounding quotes or delimiters (set by tree-sitter in
    /// task 16).
    public let byteRange: Range<Int>

    /// File-relative line of the fragment's first line, minus 1.
    ///
    /// Adding this to a fragment-relative line number (1-based) gives the
    /// 1-based file line: `fileLine = lineOffset + fragmentLine`.
    /// For whole `.lua` files this is `0`. For structured-file fields it is
    /// the 0-based file line where the field value begins (set by tree-sitter
    /// in task 16).
    public let lineOffset: Int

    /// SHA-256 digest of the complete file bytes at load time.
    ///
    /// Used by F8 write-back to detect external modifications between load and
    /// write-back (conflict guard). Captured at load by `SourceStore` before
    /// the bytes are decoded; covers the full file, not just the fragment.
    public let contentHash: SHA256Digest

    // MARK: Initialiser

    public init(
        file: URL,
        jsonpath: String?,
        document: Int,
        byteRange: Range<Int>,
        lineOffset: Int,
        contentHash: SHA256Digest
    ) {
        self.file = file
        self.jsonpath = jsonpath
        self.document = document
        self.byteRange = byteRange
        self.lineOffset = lineOffset
        self.contentHash = contentHash
    }

    // MARK: Computed property — display name (F1.2 convention)

    /// Human-readable name for this fragment, used in the navigator, diagnostics,
    /// and (P2) stack-frame display.
    ///
    /// Convention (F1.2, ARCHITECTURE.md §4.3):
    /// - Whole `.lua` file → filename (last path component of `file`)
    /// - Structured-file field → `<filename>:<normalized-jsonpath>`
    ///
    /// This is a **computed** (never stored) property so that the name and its
    /// inputs can never drift apart. It is a display-only name; it does not
    /// reach the Lua engine until LuaSwift#23 ships (ARCHITECTURE.md §4.3).
    public var displayName: String {
        let filename = file.lastPathComponent
        if let jsonpath {
            return "\(filename):\(jsonpath)"
        }
        return filename
    }
}

// MARK: - LuaSourceFragment

/// A fully loaded Lua source fragment — its decoded text and provenance.
///
/// This is the unit passed to `RunService`, `LintService`, and the `Highlighter`.
/// The `code` field contains the raw Lua source text for the fragment (for whole
/// `.lua` files: the entire file contents; for structured fields: only the string
/// value, set by task 16). The `provenance` carries all location and identity
/// metadata needed to map diagnostics back to file positions and to guard
/// write-back.
public struct LuaSourceFragment: Sendable, Equatable {

    /// The Lua source text for this fragment.
    ///
    /// For whole `.lua` files this is the full file content. For structured-file
    /// fields (task 16) this is the decoded string value only, with no
    /// surrounding quotes or delimiters.
    public let code: String

    /// Positional and identity metadata linking this text to its on-disk origin.
    public let provenance: FragmentProvenance

    public init(code: String, provenance: FragmentProvenance) {
        self.code = code
        self.provenance = provenance
    }
}
