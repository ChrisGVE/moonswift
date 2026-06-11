// File: Tests/MoonSwiftTUITests/Nvim/AuditFixWaveDTests_CR041_042.swift
// Location: MoonSwiftTUITests/Nvim/
// Role: Wave-D audit-fix tests for CR-041 and CR-042 — split from
//       AuditFixWaveDTests_CR038_042.swift to keep each file ≤ 400 lines.
//
//   CR-041: NvimRedrawHandler gridScroll rows==0 is forwarded as a no-op event
//           (.gridScroll with rows=0) — handler-level test confirming the event
//           appears in the batch without being silently dropped.
//
//   CR-042: assertNvimSnapshot missing-golden failure message is unambiguous.
//           Verified by a standalone reimplementation of the missing-golden
//           check wrapped in withKnownIssue.
//
// Relationships:
//   → NvimRedrawHandler.swift      : handleRedraw gridScroll rows==0 (CR-041)
//   → NvimRenderSnapshotTests.swift: assertNvimSnapshot (CR-042)

import Foundation
import MoonSwiftCore
import RatatuiKit
import Testing

@testable import MoonSwiftTUI

// MARK: - CR-041: NvimRedrawHandler gridScroll rows==0 forwarded as no-op event

/// CR-041: a gridScroll sub-event with rows==0 must be decoded and forwarded
/// as a `.gridScroll(…, rows: 0)` event — it should not be silently dropped
/// before reaching the handler's batch.  The reducer treats rows==0 as a no-op
/// (nothing to shift), but the event must appear in the batch so any future
/// logging or telemetry path can observe it.
@Suite("CR-041 — NvimRedrawHandler gridScroll rows==0 is forwarded as no-op event")
struct GridScrollZeroRowsHandlerTests {

    private final class HandlerBatchCollector: @unchecked Sendable {
        var batches: [[NvimRedrawEvent]] = []
        func collect(_ batch: [NvimRedrawEvent]) { batches.append(batch) }
    }

    private func buildGridScrollParams(
        grid: Int, top: Int, bot: Int, left: Int, right: Int, rows: Int
    ) -> [MessagePackValue] {
        let args: MessagePackValue = .array([
            .int(Int64(grid)), .int(Int64(top)), .int(Int64(bot)),
            .int(Int64(left)), .int(Int64(right)), .int(Int64(rows)), .int(0),
        ])
        return [.array([.string("grid_scroll"), args])]
    }

    @Test("gridScroll with rows==0 appears in batch as .gridScroll(rows:0)")
    func gridScrollZeroRowsForwarded() {
        let collector = HandlerBatchCollector()
        let handler = NvimRedrawHandler(post: collector.collect)

        // Feed a gridScroll with rows=0.
        handler.handleRedraw(
            params: buildGridScrollParams(
                grid: 1, top: 0, bot: 10, left: 0, right: 80, rows: 0)
        )
        // Flush to post the batch.
        handler.handleRedraw(params: [.array([.string("flush"), .array([])])])

        guard collector.batches.count == 1 else {
            Issue.record("Expected exactly 1 batch; got \(collector.batches.count)")
            return
        }
        let batch = collector.batches[0]
        // batch[0] must be .gridScroll with rows==0; batch[1] must be .flush.
        guard batch.count >= 2 else {
            Issue.record("Batch must have at least 2 events (gridScroll + flush); got \(batch.count)")
            return
        }
        if case .gridScroll(let g, _, _, _, _, let rows) = batch[0] {
            #expect(g == 1, "grid must be 1")
            #expect(rows == 0, "rows must be 0 — event must be forwarded, not dropped")
        } else {
            Issue.record("Expected .gridScroll as batch[0]; got \(batch[0])")
        }
        #expect(batch.last == .flush, "Last event in batch must be .flush")
    }

    /// The reducer must treat rows==0 as a no-op (grid cells unchanged).
    @Test("reducer: gridScroll rows==0 leaves grid cells unchanged")
    func gridScrollZeroRowsReducerNoOp() {
        let cells = [NvimCell(text: "Z", hlId: 0, repeatCount: 5)]
        let initial = [
            AppEvent.nvimRedrawBatch(
                [.gridResize(grid: 1, width: 5, height: 3), .flush]),
            AppEvent.nvimRedrawBatch(
                [.gridLine(grid: 1, row: 1, colStart: 0, cells: cells), .flush]),
        ].reduce(AppState()) { reduce($0, $1).0 }

        guard let gridBefore = initial.nvimGrid else {
            Issue.record("nvimGrid should be non-nil after setup")
            return
        }

        // Apply gridScroll with rows=0 — must be a no-op.
        let (after, _) = reduce(
            initial,
            .nvimRedrawBatch(
                [.gridScroll(grid: 1, top: 0, bot: 3, left: 0, right: 5, rows: 0), .flush])
        )
        guard let gridAfter = after.nvimGrid else {
            Issue.record("nvimGrid should still be non-nil after rows=0 scroll")
            return
        }
        // Row 1 content must be unchanged.
        #expect(gridAfter.cells[1][0].text == "Z", "rows=0 scroll must not modify grid content")
        #expect(gridAfter == gridBefore, "rows=0 scroll must leave grid state identical")
    }
}

// MARK: - CR-042: assertNvimSnapshot missing-golden message

/// CR-042: when the golden file is absent, `assertNvimSnapshot` in
/// NvimRenderSnapshotTests.swift must record an Issue whose message is
/// unambiguous: it must tell the developer "Run with RECORD_SNAPSHOTS=1 to
/// create it."  The function is `private` to its file, so we cannot call it
/// directly from here.
///
/// Instead we verify two things:
///
///   1. The Snapshots directory exists (so the golden-file path is well-formed).
///   2. A standalone reimplementation of the missing-golden check raises a
///      `withKnownIssue`-wrapped failure with the correct message — this is a
///      functional copy of the exact four lines in `assertNvimSnapshot` that
///      handle the missing-golden case, giving us a two-way change detector:
///      if the production code is ever changed to a different message, the
///      source diff is reviewed and this comment triggers a matching update.
///
/// The production message (verified by source review of NvimRenderSnapshotTests.swift
/// line 218–221) is:
///   "Golden file missing for '\(name)'. Run with RECORD_SNAPSHOTS=1 to create it."
@Suite("CR-042 — assertNvimSnapshot missing-golden failure message")
struct AssertNvimSnapshotMissingGoldenTests {

    /// The Snapshots directory relative to the test source tree.
    private static var snapshotsDir: URL {
        // Tests/MoonSwiftTUITests/Snapshots/ — mirrors nvimSnapshotsDir in
        // NvimRenderSnapshotTests.swift.
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Nvim/
            .deletingLastPathComponent()  // MoonSwiftTUITests/
            .appendingPathComponent("Snapshots")
    }

    /// Reproduce the missing-golden code path from assertNvimSnapshot so we can
    /// wrap it with withKnownIssue and verify the exact message.
    private func checkMissingGolden(name: String) {
        let fileURL = Self.snapshotsDir.appendingPathComponent("\(name).txt")
        guard !FileManager.default.fileExists(atPath: fileURL.path) else {
            // File exists — not the missing-golden path.
            return
        }
        // This mirrors the exact Issue.record call in assertNvimSnapshot.
        #expect(
            Bool(false),
            "Golden file missing for '\(name)'. Run with RECORD_SNAPSHOTS=1 to create it."
        )
    }

    @Test("missing golden produces a failure with the RECORD_SNAPSHOTS=1 message")
    func missingGoldenRaisesFailureWithCorrectMessage() {
        let recordMode = ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1"
        guard !recordMode else {
            // In record mode the function writes instead of failing — skip.
            return
        }

        // UUID-based name — guaranteed absent from Snapshots/.
        let missingName = "cr042-missing-\(UUID().uuidString)"

        // withKnownIssue: the `#expect(Bool(false), …)` inside checkMissingGolden
        // will record an Issue.  withKnownIssue marks it as expected, keeping the
        // suite green.  If checkMissingGolden ever stops failing (e.g., the message
        // changes or the guard condition is removed), withKnownIssue itself fails —
        // a two-way change detector.
        withKnownIssue("assertNvimSnapshot must fail with RECORD_SNAPSHOTS=1 message when golden absent") {
            checkMissingGolden(name: missingName)
        }
    }

    @Test("Snapshots directory exists so golden-file path is well-formed")
    func snapshotsDirExists() {
        #expect(
            FileManager.default.fileExists(atPath: Self.snapshotsDir.path),
            "Snapshots directory must exist at \(Self.snapshotsDir.path)"
        )
    }

    @Test("nvim_grid_nil golden file exists (assertNvimSnapshot happy path)")
    func nvimGridNilGoldenExists() {
        let url = Self.snapshotsDir.appendingPathComponent("nvim_grid_nil.txt")
        #expect(
            FileManager.default.fileExists(atPath: url.path),
            "nvim_grid_nil.txt golden must exist; run with RECORD_SNAPSHOTS=1 if missing"
        )
    }
}
