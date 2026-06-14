// File: Tests/MoonSwiftCoreTests/Diagnostics/LuaErrorLineParserDeletionGuardTests.swift
// Folder: Tests/MoonSwiftCoreTests/Diagnostics/
// Role: P2 F6.4 deletion guard (task #37). Asserts the `LuaErrorLineParser`
//       seam stays DELETED: (1) the source file is absent, and (2) no Sources
//       `.swift` file USES the symbol (member access `LuaErrorLineParser.` or a
//       redefinition `enum/struct/class LuaErrorLineParser`). Historical doc
//       notes that merely mention the name ("the deleted `LuaErrorLineParser`")
//       are allowed — only code usage and the file's return are guarded, so an
//       accidental re-introduction fails CI while the change history stays
//       readable. Runtime errors now use LuaSwift #19 structured errors; the
//       residual compile-line extraction lives inline in LuaErrorDiagnostics.
//
// Upstream: (filesystem scan of the repo Sources tree)
// Downstream: (test target)

import Foundation
import Testing

@Suite("F6.4 — LuaErrorLineParser deletion guard (task #37)")
struct LuaErrorLineParserDeletionGuardTests {

    /// Walk up from this test file to the repository root (the directory that
    /// contains both `Package.swift` and `Sources/`).
    private func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let pkg = dir.appendingPathComponent("Package.swift")
            let sources = dir.appendingPathComponent("Sources")
            if fm.fileExists(atPath: pkg.path), fm.fileExists(atPath: sources.path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return dir
    }

    @Test("the LuaErrorLineParser source file no longer exists")
    func fileRemoved() {
        let path = repoRoot()
            .appendingPathComponent("Sources/MoonSwiftCore/Diagnostics/LuaErrorLineParser.swift")
        #expect(
            !FileManager.default.fileExists(atPath: path.path),
            "LuaErrorLineParser.swift must stay deleted (F6.4)")
    }

    @Test("no Sources file USES the LuaErrorLineParser symbol (code, not doc notes)")
    func noCodeReferences() {
        let sources = repoRoot().appendingPathComponent("Sources")
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: sources, includingPropertiesForKeys: nil) else {
            Issue.record("could not enumerate \(sources.path)")
            return
        }
        var offenders: [String] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (i, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
            {
                let line = String(rawLine)
                // Skip comment lines so historical "deleted LuaErrorLineParser"
                // notes do not trip the guard; flag only real code usage.
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") || trimmed.hasPrefix("*") {
                    continue
                }
                if line.contains("LuaErrorLineParser.")
                    || line.range(
                        of: #"(enum|struct|class)\s+LuaErrorLineParser"#,
                        options: .regularExpression) != nil
                {
                    offenders.append("\(url.lastPathComponent):\(i + 1): \(trimmed)")
                }
            }
        }
        #expect(offenders.isEmpty, "LuaErrorLineParser must be unused in code: \(offenders)")
    }
}
