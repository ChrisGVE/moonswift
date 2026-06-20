// File: Tests/MoonSwiftTUITests/LuaLSEnvironmentTests.swift
// Role: Verify the lua-language-server child-environment allow-list (F7b,
//       SEC-05/SEC-N02). The pass-list must keep only the non-sensitive
//       variables LuaLS needs and drop every credential-bearing variable a
//       developer shell carries.
// Upstream: MoonSwiftTUI/LuaLS/LuaLSEnvironment.swift
// Downstream: (test target)

import Foundation
import Testing

@testable import MoonSwiftTUI

@Suite("LuaLSEnvironment allow-list")
struct LuaLSEnvironmentTests {

    @Test("Keeps the allowed non-sensitive variables")
    func keepsAllowed() {
        let parent = [
            "PATH": "/usr/bin",
            "HOME": "/Users/test",
            "TMPDIR": "/tmp",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "XDG_CONFIG_HOME": "/Users/test/.config",
        ]
        let child = LuaLSEnvironment.childEnvironment(from: parent)
        #expect(child == parent)  // all are on the allow-list
    }

    @Test("Strips credential-bearing variables (SEC-05)")
    func stripsSecrets() {
        let parent = [
            "PATH": "/usr/bin",
            "HOME": "/Users/test",
            "AWS_SECRET_ACCESS_KEY": "shh",
            "AWS_ACCESS_KEY_ID": "AKIA…",
            "GITHUB_TOKEN": "ghp_…",
            "VAULT_TOKEN": "hvs.…",
            "CONSUL_TOKEN": "…",
            "NOMAD_TOKEN": "…",
            "CARGO_REGISTRY_TOKEN": "…",
            "NPM_AUTHTOKEN": "…",
            "DOCKER_PASSWORD": "…",
            "HEROKU_API_KEY": "…",
            "ANTHROPIC_KEY": "…",
            "SOME_NEW_TOKEN": "…",  // not on any deny-list — must still be dropped
        ]
        let child = LuaLSEnvironment.childEnvironment(from: parent)
        #expect(child == ["PATH": "/usr/bin", "HOME": "/Users/test"])
        // Spot-check a few keys are absent.
        #expect(child["GITHUB_TOKEN"] == nil)
        #expect(child["AWS_SECRET_ACCESS_KEY"] == nil)
        #expect(child["SOME_NEW_TOKEN"] == nil)
    }

    @Test("Pass-list excludes unknown variables by default")
    func passListIsClosed() {
        // A made-up variable that matches neither exact names nor prefixes is
        // excluded — the list adds nothing implicitly.
        let child = LuaLSEnvironment.childEnvironment(from: ["EDITOR": "vim"])
        #expect(child.isEmpty)
    }
}
