# RELEASING.md — MoonSwift release pipeline

This document describes the end-to-end release process for MoonSwift.
The pipeline is implemented in `.github/workflows/release.yml`; this file
explains **why** each step is ordered as it is, what one-time setup is
required, and how to recover from failures.

---

## 1. Background — the two-phase release protocol

MoonSwift distributes its Rust FFI shim as an XCFramework wrapped in a
`binaryTarget` in `Package.swift`.  This creates a chicken-and-egg ordering
constraint documented in `ARCHITECTURE.md §5.4`:

> The binaryTarget entry in `Package.swift` must reference both the artifact's
> **URL** (a GitHub release download URL) and its **sha256 checksum**.  Both
> are known only after the XCFramework is built and the release URL is
> determined.  A tag-triggered workflow fires on the wrong commit (the one
> before the checksum commit exists), so `release.yml` is **`workflow_dispatch`
> only**.

A single `workflow_dispatch` run performs every step in the correct order:

1. **Build** — compile the Rust shim for both architectures (arm64, x86_64),
   lipo a universal static lib, wrap in an XCFramework, zip, compute sha256.
2. **Commit** — a bot commit updates `Package.swift`'s `binaryTarget` with
   the predictable download URL and the computed checksum.  This commit is
   pushed directly to protected `main` (see §3 for bypass setup).
3. **Tag** — the release tag (e.g. `v0.5.0`) points at **that commit**, not
   at the pre-checksum HEAD.
4. **Release** — GitHub release is created; the XCFramework zip and a
   notarization-ready universal `moonswift` binary are uploaded as assets.
5. **Attest** — build-provenance attestations are generated for both artifacts
   via `actions/attest-build-provenance`.
6. **Verify** — a clean x86_64 runner checks out the tag and runs a plain
   `swift build` (no Rust toolchain, no `MOONSWIFT_SHIM_SOURCE`).  This
   confirms that the binaryTarget URL and checksum are correct and that
   end-users can build without a Rust toolchain.

---

## 2. What gets released

| Artifact | Description |
|----------|-------------|
| `CRatatuiFFI.xcframework.zip` | Universal XCFramework wrapping the Rust FFI static lib + regenerated cbindgen header.  Referenced by `Package.swift`'s `binaryTarget`. |
| `moonswift_universal.zip` | Universal `moonswift` CLI binary (arm64 + x86_64), shim statically linked and `otool`-verified self-contained (notarization-ready, runs via Homebrew). |
| Provenance attestations | SLSA-style attestations for both zips, signed by GitHub's OIDC infrastructure.  Verified with `gh attestation verify`. |
| Homebrew formula PR | A formula-bump PR opened in `ChrisGVE/homebrew-tap` (`Formula/moonswift.rb`); merge it to publish `brew install ChrisGVE/tap/moonswift`. |

---

## 3. One-time setup — branch-protection bypass allowance

The release workflow pushes a bot commit directly to protected `main` (the
checksum commit described in §1).  This requires an explicit bypass allowance
in the repository's branch-protection ruleset.

**Steps (requires repository admin access):**

1. Open the repository on GitHub → **Settings** → **Rules** → **Rulesets**.
2. Select the ruleset protecting `main` (create one if it does not exist;
   at minimum enable "Require a pull request before merging").
3. Under **Bypass list**, click **Add bypass**.
4. Choose **GitHub Actions** (or search for `github-actions[bot]`).
5. Set the bypass mode to **Always** (the release workflow is the only bot
   that ever pushes directly to `main`).
6. Save the ruleset.

After this change, `github-actions[bot]` can push to `main` without a pull
request.  No other identity gains bypass access.

**Why not a PAT?**  A PAT would require a separate secret, a dedicated account
or fine-grained token, and would bypass signed-commit requirements.  The
`GITHUB_TOKEN` approach (bot identity bypass) keeps the surface minimal and
auditable.

### Homebrew tap dispatch token

The release also publishes to `ChrisGVE/homebrew-tap` (formula `moonswift`).
The build job's final step sends a cross-repo `repository_dispatch`, which
`GITHUB_TOKEN` cannot do — it needs a PAT with write access to the tap repo:

- Secret name: **`TAP_DISPATCH_TOKEN`** (repository secret on
  `ChrisGVE/moonswift`).
- Scope: a fine-grained PAT with **Contents: write** on `ChrisGVE/homebrew-tap`
  **and `homebrew-tap` selected in the token's *repository access* list**
  (fine-grained PATs are deny-by-default per repo — Contents:write alone is not
  enough if the target repo is not in scope), or a classic PAT with `repo`.
- This is the same token convention used by the `codesize` release pipeline.

> **If the dispatch fails with `Resource not accessible by personal access
> token`:** the PAT does not cover `homebrew-tap` (wrong repository scope or
> insufficient permission). The dispatch step is **non-blocking**
> (`continue-on-error`) so this does not fail the release — the tag, artifacts,
> attestation, and verify job still complete. Publish the formula manually:
>
> ```sh
> SHA=$(gh release download vX.Y.Z -R ChrisGVE/moonswift \
>   --pattern moonswift_universal.zip -O - | shasum -a 256 | cut -d' ' -f1)
> gh workflow run update-moonswift.yml -R ChrisGVE/homebrew-tap \
>   -f version=X.Y.Z -f darwin_universal_sha256="$SHA"
> ```
>
> Then merge the formula-bump PR the workflow opens on the tap.

The tap side (`Formula/moonswift.rb` + `.github/workflows/update-moonswift.yml`)
must exist on the tap's `main` before the first release dispatch, or the
update PR has nothing to bump.

---

## 4. Running a release

Prerequisites:

- The `main` branch is in a releasable state.  All CI checks are green.
- The Rust shim ABI has not changed since the last release, OR a new release
  is being produced specifically to ship the ABI change (per the
  main-branch shim-surface rule in `ARCHITECTURE.md §5.4`).
- You have repository write access to trigger `workflow_dispatch`.

Steps:

1. Open the repository on GitHub → **Actions** → **Release**.
2. Click **Run workflow** (the `workflow_dispatch` form).
3. Enter the version (SemVer without the `v` prefix, e.g. `0.5.0`).
4. Click **Run workflow**.
5. Monitor the **build** job.  It will:
   - Cross-compile the Rust shim for arm64 and x86_64.
   - Lipo a universal static lib.
   - Regenerate the cbindgen header.
   - Wrap in an XCFramework and zip it.
   - Build the universal `moonswift` binary with the shim **statically**
     linked (the dylib is removed first; an `otool -L` gate fails the release
     if any `libratatui_ffi` load command survives), so the artifact runs on
     any machine and via Homebrew.
   - Update `Package.swift`, commit, tag, push.
   - Create the GitHub release and upload artifacts.
   - Generate provenance attestations.
   - Dispatch `moonswift-release-published` to `ChrisGVE/homebrew-tap`, which
     bumps `Formula/moonswift.rb` (version + checksum) and opens a PR there.
6. The **verify** job runs after **build** succeeds.  It checks out the tag
   on a clean x86_64 runner and runs `swift build` in binaryTarget mode.
7. Once both jobs are green, merge the formula-bump PR in `ChrisGVE/homebrew-tap`
   (`brew install ChrisGVE/tap/moonswift` works once merged).  The release is
   then complete.

> **Before bumping the version:** the `--version` string is hard-coded at
> `Sources/moonswift/CLIArguments.swift` (`versionString = "moonswift X.Y.Z"`).
> It MUST match the release version, or the Homebrew formula's `test do`
> (`assert_match version`) fails.  Bump it in the same change-set that prepares
> the release.

---

## 5. Verifying a release artifact

Anyone can verify the build provenance of a released XCFramework:

```sh
# Download the artifact (or already have it locally):
gh release download v0.5.0 --repo ChrisGVE/moonswift \
  --pattern CRatatuiFFI.xcframework.zip

# Verify the attestation:
gh attestation verify CRatatuiFFI.xcframework.zip \
  --repo ChrisGVE/moonswift
```

---

## 6. Recovery procedures

### Build job fails before the bot commit

The release is safe to retry: no commit or tag has been pushed yet.  Fix the
root cause (Cargo compilation error, cbindgen failure, etc.) and re-run the
workflow with the same version string.

### Build job fails after the bot commit but before the tag

A commit has been pushed to `main` with a partial or incorrect Package.swift.
Steps:

1. Revert the bot commit: `git revert HEAD` (or use the GitHub UI).
2. Push the revert to `main`.
3. Fix the root cause and re-run the workflow.

### Build job fails after the tag

A tag and possibly a partial release exist.  Steps:

1. Delete the release (GitHub UI or `gh release delete vX.Y.Z`).
2. Delete the tag (`git push origin --delete vX.Y.Z`).
3. Revert the bot commit and push.
4. Fix the root cause and re-run the workflow.

### Verify job fails

The XCFramework was built and uploaded, but the binaryTarget URL or checksum
in `Package.swift` is wrong.  This should not happen if the workflow ran
correctly, but if it does:

1. Delete the release and tag (same steps as above).
2. Revert the bot commit.
3. Investigate `steps.checksum.outputs.checksum` vs the actual zip sha256.
4. Re-run the workflow.

---

## 7. Notarization (post-release, optional)

The `moonswift_universal.zip` artifact contains the universal `moonswift`
binary in a state ready for Apple notarization.  Notarization is optional for
a CLI tool distributed via GitHub but may be desired for Gatekeeper
compatibility on end-user machines.

To notarize after a release:

```sh
# Download the binary from the release:
gh release download vX.Y.Z --repo ChrisGVE/moonswift \
  --pattern moonswift_universal.zip
unzip moonswift_universal.zip

# Sign with your Developer ID (requires a signing certificate):
codesign --sign "Developer ID Application: <Name> (<TeamID>)" \
  --options runtime moonswift_universal

# Notarize (requires App Store Connect API key):
xcrun notarytool submit moonswift_universal \
  --apple-id <APPLE_ID> \
  --team-id <TEAM_ID> \
  --password <APP_SPECIFIC_PASSWORD> \
  --wait
```

---

## 8. Environment variables

| Variable | Where set | Purpose |
|----------|-----------|---------|
| `LUASWIFT_INCLUDE_TOMLKIT=1` | Every swift build step in `release.yml` | LuaSwift's manifest reads this at evaluation time; the release binary must always include `luaswift.toml` (ARCHITECTURE.md §5.4). |
| `MOONSWIFT_SHIM_SOURCE` | **Not set** in binaryTarget build steps; set to `1` only for the source-mode shim build that produces the universal `moonswift` binary | Controls whether `Package.swift` declares `CRatatuiFFI` as a stub C target or a binaryTarget (ARCHITECTURE.md §5.4). |
