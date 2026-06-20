// File: Sources/MoonSwiftTUI/LuaLS/LuaLSEnvironment.swift
// Folder: Sources/MoonSwiftTUI/LuaLS/
// Role: Build the curated environment handed to the lua-language-server child
//       process (F7b, SEC-05). The parent process environment is NOT inherited;
//       only an explicit allow-list of non-sensitive variables is passed through.
//       This is the OPPOSITE of NvimProcessSupervisor.spawn, which inherits the
//       full environment and overrides XDG — nvim is a trusted, vendored-config
//       binary, whereas lua-language-server is an arbitrary user-installed third
//       party that must never see credential variables (AWS_*, *_TOKEN, …).
//
// Upstream: ProcessInfo.processInfo.environment (or a test-supplied dictionary)
// Downstream: LuaLSProcess.spawn (sets the child's environment)

import Foundation

/// Curates the environment for the lua-language-server child (strict pass-list).
///
/// LuaLS needs only enough environment to find executables (`PATH`), resolve the
/// home/cache/temp directories it writes its log into (`HOME`, `TMPDIR`,
/// `XDG_*`), and format messages for the active locale (`LANG`, `LC_*`).
/// Everything else — every credential, token, and secret a developer shell
/// carries — is dropped. The list is a PASS-list, not a deny-list: new variables
/// are excluded by default, so a newly-invented `SOME_NEW_TOKEN` can never leak.
enum LuaLSEnvironment {

    /// Exact variable names passed through verbatim.
    static let allowedExact: Set<String> = ["PATH", "HOME", "TMPDIR", "LANG"]

    /// Variable-name prefixes passed through (covers `LC_ALL`, `LC_CTYPE`, and the
    /// XDG base-directory family `XDG_CONFIG_HOME`, `XDG_CACHE_HOME`, …).
    static let allowedPrefixes: [String] = ["LC_", "XDG_"]

    /// The child environment built by applying the allow-list to `parent`.
    ///
    /// Credential-bearing variables (`AWS_*`, `GITHUB_TOKEN`, `*_API_KEY`,
    /// `*_SECRET*`, `*_TOKEN`, `VAULT_TOKEN`, …) are absent from the result
    /// because they match neither `allowedExact` nor `allowedPrefixes`.
    static func childEnvironment(
        from parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        parent.filter { key, _ in
            allowedExact.contains(key) || allowedPrefixes.contains { key.hasPrefix($0) }
        }
    }
}
