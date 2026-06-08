// swift-tools-version: 6.0
// Package.swift — MoonSwift
//
// Role: SPM manifest. Declares all targets, their dependency graph, and the
//       env-switched shim topology (MOONSWIFT_SHIM_SOURCE toggles between the
//       stub-C-target source build and a binaryTarget release artifact).
//
// Bootstrap note: before the first shim release exists, source mode is the
// documented default (ARCHITECTURE.md §5.4 bootstrap rule). The Makefile sets
// MOONSWIFT_SHIM_SOURCE=1. Once F0.5 produces the first XCFramework release,
// the default flips to binaryTarget and this note is updated in the same
// change-set.
//
// LuaSwift pin note: pinned by revision to the main HEAD commit
// 2fd31bcd4c4dbc1da0cfd41a385c3b8f68e0d331, which carries the
// precompile(_:)/CompiledChunk API in [Unreleased]. This pin moves to a
// version range (.from) once that release is tagged (the P1 minimum per
// ARCHITECTURE.md §5.3).

import Foundation
import PackageDescription

// MARK: - Env-switched shim mode

// MOONSWIFT_SHIM_SOURCE=1 → source-build mode (stub C target + linker flags).
// Unset or any other value → binaryTarget mode (prebuilt XCFramework).
// Every SPM manifest reset is the caller's responsibility when toggling
// (CONTRIBUTING documents the cache footgun; ARCHITECTURE.md §5.4).
let shimSourceMode = ProcessInfo.processInfo.environment["MOONSWIFT_SHIM_SOURCE"] == "1"

// MARK: - CRatatuiFFI target declaration

// In source mode the target is a C target containing a compile-time stub
// (one .c file with empty bodies matching the shim ABI). The real implementation
// is the Rust static library linked via the unsafeFlags linker settings.
// In binaryTarget mode (steady state after F0.5) the target wraps the
// XCFramework produced by release.yml.
//
// unsafeFlags consequence: makes MoonSwift unconsuable as a library dependency
// of other packages. Harmless for an executable — documented in ARCHITECTURE.md §5.4.
// Context.packageDirectory is the canonical SPM way to obtain the package
// root at manifest-evaluation time (available from swift-tools-version 5.5+).
// #file cannot be used here: SPM evaluates the manifest from an internal
// working directory (verified: produces `.../MoonSwift/main/Package.swift`,
// not the actual package root), so URL(fileURLWithPath: #file).deletingLastPathComponent()
// produces the wrong path and the -L linker flag points nowhere.
let shimPackageRoot = Context.packageDirectory

let cRatatuiFFITarget: Target =
    shimSourceMode
    ? .target(
        name: "CRatatuiFFI",
        path: "Sources/CRatatuiFFI",
        sources: ["shim_stub.c"],
        publicHeadersPath: "include",
        cSettings: [
            .headerSearchPath("include")
        ],
        linkerSettings: [
            // Link the Rust shim as a DYLIB, not a static lib.
            //
            // Background: cargo produces both libratatui_ffi.dylib (cdylib) and
            // libratatui_ffi.a (staticlib).  When the .a is linked into the Swift
            // test binary — which is compiled for arm64e-apple-macos14.0 — the
            // Rust std precompiled object (std-cgu.0.rcgu.o) is merged into the
            // arm64e binary.  That object contains __thread_vars TLS descriptors
            // with tlv_bootstrap function pointers that are not PAC-signed for
            // arm64e.  dyld's arm64e TLS initialiser rejects these unsigned
            // pointers at binary load time → SIGBUS (signal 10).
            //
            // Using the dylib sidesteps the ABI mismatch: dyld loads
            // libratatui_ffi.dylib as a separate arm64 image and initialises
            // its TLS sections in the arm64 context, where the tlv_bootstrap
            // pointers are valid.  The arm64e test binary never owns the Rust
            // TLS descriptors; it only holds an LC_LOAD_DYLIB reference.
            //
            // The rpath entry tells the runtime loader where to find the dylib
            // at test execution time (same absolute path used at link time).
            // (ARCHITECTURE.md §5.4 arm64-TLS dylib strategy)
            .unsafeFlags([
                // Add the Rust release dir to the linker search path.
                "-Xlinker", "-L\(shimPackageRoot)/rust/ratatui-ffi/target/release",
                // Link against the dylib (ld prefers dylib over .a when both exist).
                "-Xlinker", "-lratatui_ffi",
                // Embed rpath so the runtime loader finds the dylib.
                "-Xlinker", "-rpath", "-Xlinker", "\(shimPackageRoot)/rust/ratatui-ffi/target/release",
            ])
        ]
    )
    : .binaryTarget(
        name: "CRatatuiFFI",
        // URL and checksum are updated by release.yml in the same change-set
        // that tags a release (two-phase release ordering protocol,
        // ARCHITECTURE.md §5.4). During bootstrap these fields are placeholders.
        url: "https://github.com/ChrisGVE/moonswift/releases/download/placeholder/CRatatuiFFI.xcframework.zip",
        checksum: "0000000000000000000000000000000000000000000000000000000000000000"
    )

// MARK: - Swift settings applied to every Swift target

// Swift 6 language mode and strict concurrency checking are non-negotiable
// (PRD F0.1, ARCHITECTURE.md §1). Applied to every Swift target uniformly.
let swiftTargetSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("StrictConcurrency"),
]

// MARK: - Package

let package = Package(
    name: "MoonSwift",

    // macOS 13 minimum per PRD F0.1 / ARCHITECTURE.md §1.
    platforms: [
        .macOS(.v13)
    ],

    products: [
        .executable(
            name: "moonswift",
            targets: ["moonswift"]
        )
    ],

    // MARK: Dependencies
    //
    // All dependencies are pinned in Package.resolved (committed).
    // Upgrade policy: deliberate, dedicated tasks only — no floating ranges
    // except where a floor from() is the established idiom for a mature dep.
    dependencies: [

        // LuaSwift: pinned by revision to main HEAD (2fd31bcd) carrying the
        // precompile/CompiledChunk API in [Unreleased]. Moves to .from("2.0.0")
        // (or whatever tag ships the API) when that release lands.
        // See ARCHITECTURE.md §5.3 for the consumed surface and P1 gate.
        .package(
            url: "https://github.com/ChrisGVE/LuaSwift.git",
            revision: "2fd31bcd4c4dbc1da0cfd41a385c3b8f68e0d331"
        ),

        // swift-collections: OrderedDictionary for TreeValue.map, preserving
        // key insertion order across JSON/YAML/TOML decode (PRD F0.1, F1.2).
        // Apple-maintained, pure Swift, no transitive deps.
        .package(
            url: "https://github.com/apple/swift-collections.git",
            from: "1.5.1"
        ),

        // SwiftTreeSitter: highlighting, picker tree view, span location for
        // provenance and F8 (ARCHITECTURE.md §6). ChimeHQ is the active
        // maintainer; version 0.10.0 is the current release.
        .package(
            url: "https://github.com/ChimeHQ/SwiftTreeSitter.git",
            from: "0.10.0"
        ),

        // tree-sitter-lua: Lua grammar for highlighting and span location.
        // Azganoth's fork carries a Package.swift; pinned to tagged release.
        .package(
            url: "https://github.com/Azganoth/tree-sitter-lua.git",
            revision: "84fcbca1b4e377010c5d55aa37fec52ce6a295a0"  // tag v2.1.3
        ),

        // tree-sitter-json: JSON grammar. The upstream tree-sitter org repo
        // ships a Package.swift as of v0.24.x; pinned to that release tag.
        .package(
            url: "https://github.com/tree-sitter/tree-sitter-json.git",
            revision: "ee35a6ebefcef0c5c416c0d1ccec7370cfca5a24"  // tag v0.24.8
        ),

        // tree-sitter-toml: TOML grammar is provided as a LOCAL target
        // (Sources/CTreeSitterTOML) rather than an external dependency.
        // Reason: the upstream SPM-supporting branch (mattmassicotte/tree-sitter-toml
        // feature/spm, commit bf4ceeb) omits scanner.c from its Package.swift,
        // producing undefined-symbol link errors. Sources vendored from that commit;
        // see Sources/CTreeSitterTOML/NOTICE for provenance and upgrade path.

        // tree-sitter-yaml: YAML grammar. Same pattern as TOML above.
        .package(
            url: "https://github.com/mattmassicotte/tree-sitter-yaml.git",
            revision: "bd633dc67bd71934961610ca8bd832bf2153883e"  // feature/spm HEAD 2026-06-07
        ),

        // Yams: YAML decode into TreeValue (ARCHITECTURE.md §6).
        // Lower bound matches LuaSwift's own constraint (from: "5.0.0") so
        // SPM can resolve a single shared version across the dependency graph.
        .package(
            url: "https://github.com/jpsim/Yams.git",
            from: "5.0.0"
        ),

        // TOMLKit: TOML decode and moonswift.toml project-file encode-modify-encode
        // (ARCHITECTURE.md §4.1, §6).
        .package(
            url: "https://github.com/LebJe/TOMLKit.git",
            from: "0.6.0"
        ),
    ],

    targets: [

        // MARK: - CTreeSitterTOML (local; vendored grammar sources)
        //
        // The upstream mattmassicotte/tree-sitter-toml feature/spm Package.swift
        // omits scanner.c, causing undefined-symbol link errors. The grammar
        // sources are vendored locally (parser.c + scanner.c) with provenance
        // documented in Sources/CTreeSitterTOML/NOTICE.

        .target(
            name: "CTreeSitterTOML",
            path: "Sources/CTreeSitterTOML",
            exclude: ["NOTICE"],
            sources: [
                "src/parser.c",
                "src/scanner.c",
            ],
            resources: [
                .copy("queries")
            ],
            publicHeadersPath: "bindings/swift/TreeSitterTOML",
            cSettings: [.headerSearchPath("src")]
        ),

        // MARK: - CRatatuiFFI (env-switched; see declaration above)

        cRatatuiFFITarget,

        // MARK: - RatatuiKit
        //
        // Safe Swift overlay over CRatatuiFFI: status-code → thrown error
        // translation, event decoding, widget/cell-buffer wrappers, terminal
        // lifecycle including suspend/resume for $EDITOR.
        // The only Swift target that contains FFI calls (ARCHITECTURE.md §2).

        .target(
            name: "RatatuiKit",
            dependencies: [
                "CRatatuiFFI"
            ],
            path: "Sources/RatatuiKit",
            swiftSettings: swiftTargetSettings
        ),

        // MARK: - MoonSwiftCore
        //
        // Terminal-free domain logic: project file, source loading with
        // provenance, JSONPath subset, run/lint services, module catalog,
        // diagnostics, logging. Zero terminal I/O — fully unit-testable.
        // Coverage gate: ≥ 85% (PRD §10 / ARCHITECTURE.md §1).

        .target(
            name: "MoonSwiftCore",
            dependencies: [
                .product(name: "LuaSwift", package: "LuaSwift"),
                .product(name: "Collections", package: "swift-collections"),
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterLua", package: "tree-sitter-lua"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                "CTreeSitterTOML",
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "Yams", package: "Yams"),
                .product(name: "TOMLKit", package: "TOMLKit"),
            ],
            path: "Sources/MoonSwiftCore",
            resources: [
                // Vendored luacheck pure-Lua subset (F4.0 spike; F4.2 production).
                // Loaded at runtime by LintService via Bundle.module.
                // See Sources/MoonSwiftCore/Vendor/luacheck/NOTICE for provenance.
                .copy("Vendor/luacheck")
            ],
            swiftSettings: swiftTargetSettings
        ),

        // MARK: - MoonSwiftTUI
        //
        // Elm-style TUI core: AppState, AppEvent, Effect, Reducer, Renderer,
        // AppDriver, EventPump, EventChannel, Highlighter, ThemeEngine.
        // The single-writer state loop; depends on MoonSwiftCore and RatatuiKit.
        // MoonSwiftCore is imported here; RatatuiKit is its FFI bridge.

        .target(
            name: "MoonSwiftTUI",
            dependencies: [
                "MoonSwiftCore",
                "RatatuiKit",
                // Tree-sitter grammars and Swift overlay for the Highlighter component.
                // Lua is loaded eagerly at startup; JSON/YAML/TOML are lazy on first access.
                // (ARCHITECTURE.md §2 Highlighter row, §3a cold-start budget)
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterLua", package: "tree-sitter-lua"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                "CTreeSitterTOML",
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
            ],
            path: "Sources/MoonSwiftTUI",
            swiftSettings: swiftTargetSettings
        ),

        // MARK: - moonswift (executable)
        //
        // Entry point: arg parsing, signal handlers, terminal init,
        // AppDriver bootstrap, exit codes. Contains no domain or UI logic.

        .executableTarget(
            name: "moonswift",
            dependencies: [
                "MoonSwiftTUI"
            ],
            path: "Sources/moonswift",
            swiftSettings: swiftTargetSettings
        ),

        // MARK: - Test targets

        // MoonSwiftCore unit tests.
        // Uses Swift Testing (@Test / #expect). Coverage gate: ≥ 85%.
        // FFI is never linked in this target (ARCHITECTURE.md §5.1).
        .testTarget(
            name: "MoonSwiftCoreTests",
            dependencies: [
                "MoonSwiftCore"
            ],
            path: "Tests/MoonSwiftCoreTests",
            resources: [
                // Fixture TOML files for ProjectStore / ProjectFileCodec tests.
                .copy("Fixtures")
            ],
            swiftSettings: swiftTargetSettings
        ),

        // MoonSwiftTUI unit tests.
        // EventSource protocol lets tests drive the loop with scripted events;
        // no FFI link in this target (ARCHITECTURE.md §5.1).
        .testTarget(
            name: "MoonSwiftTUITests",
            dependencies: [
                "MoonSwiftTUI"
            ],
            path: "Tests/MoonSwiftTUITests",
            resources: [
                // Lua fixtures for HighlighterTests.
                .copy("Fixtures")
            ],
            swiftSettings: swiftTargetSettings
        ),

        // MoonSwiftPerfTests: performance benchmarks.
        // Six measurements (render pipeline, cancellation, pre-pass, luacheck,
        // source load, cold-start proxy) with 2× PRD thresholds to absorb CI
        // runner variance. NOT wired into ci.yml — see Tests/MoonSwiftPerfTests/
        // PerfTests.swift file header for rationale and local run instructions.
        .testTarget(
            name: "MoonSwiftPerfTests",
            dependencies: [
                "MoonSwiftTUI"
            ],
            path: "Tests/MoonSwiftPerfTests",
            swiftSettings: swiftTargetSettings
        ),

        // RatatuiKit unit tests.
        .testTarget(
            name: "RatatuiKitTests",
            dependencies: [
                "RatatuiKit"
            ],
            path: "Tests/RatatuiKitTests",
            swiftSettings: swiftTargetSettings
        ),
    ]
)
