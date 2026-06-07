// File: Sources/MoonSwiftCore/Vendor/VendorBundle.swift
// Location: Sources/MoonSwiftCore/Vendor/
// Role: Exposes the MoonSwiftCore resource bundle to consumers of this target,
//       including the test target. In SPM, Bundle.module is generated per-target
//       and resolves the correct bundle for the module that declares the resource.
//       Tests calling Bundle.module directly resolve their own test bundle; they
//       must use moonSwiftCoreBundle to reach the vendored luacheck resources.
//
// Context: Consumed by LintService (F4.2) and the F4.0 spike test.

import Foundation

/// The resource bundle for MoonSwiftCore.
///
/// Use this instead of `Bundle.module` when accessing vendored resources from
/// outside the `MoonSwiftCore` module (e.g. from test targets). `Bundle.module`
/// resolves the *calling target's* bundle; this accessor always resolves
/// `MoonSwiftCore`'s bundle, which contains the vendored luacheck sources.
internal let moonSwiftCoreBundle: Bundle = Bundle.module
