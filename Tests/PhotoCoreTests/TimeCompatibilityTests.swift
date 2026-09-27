import Foundation
import Darwin
import PhotoCore

extension PhotoCoreTests {
    func testTimeUnsupportedRenameFallback() throws {
        let (jpg, raw) = try pair(), originals = try [jpg, raw].map { try Fingerprint.read($0) }
        let compatible = OperationService(store: store, metadata: metadata) { phase in
            if phase == "timeExclusiveRename" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)) }
        }
        for failure in ["none", "timePublicationCreated", "partialPrefix", "timeCopyChunk:提交新建 XMP", "timePublicationVerified"] {
            let plan = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
            let injected = OperationService(store: store, metadata: metadata) { phase in
                if phase == "timeExclusiveRename" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)) }
                if failure == "partialPrefix", phase == "timePublicationCreated" {
                    let saved = try XCTUnwrap(self.store.batches().first { $0.id == plan.id })
                    let f = try XCTUnwrap(saved.items[0].files.first { $0.timeEdit?.role == "new" })
                    let bytes = try Data(contentsOf: URL(fileURLWithPath: f.staged!)).prefix(17)
                    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: f.source))
                    try handle.write(contentsOf: bytes); try handle.close()
                    throw PhotoError.message("partial prefix interrupted")
                }
                if phase == failure { throw PhotoError.message("publication interrupted") }
            }
            let result = try execute(plan, using: injected)
            if failure != "none" {
                XCTAssertEqual(result.done, 0)
                XCTAssertEqual(result.items[0].files.first { $0.timeEdit?.role == "new" }?.state, "publishing")
            }
            let saved = try XCTUnwrap(store.batches().first { $0.id == result.id })
            let resumed = failure == "none" ? result : try execute(saved, using: compatible)
            XCTAssertEqual(resumed.done, 1, resumed.items.compactMap(\.error).joined())
            XCTAssertEqual(try store.photos().first?.capture, plan.items[0].newCapture)
            XCTAssertEqual(try undo(resumed).status, "undone")
            for (path, hash) in zip([jpg, raw], originals) { XCTAssertEqual(try Fingerprint.read(path), hash) }
        }
        // The previous release left JPG done and XMP committing, without publication fields.
        let oldPlan = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        var members = 0
        let previousFailure = OperationService(store: store, metadata: metadata) { phase in
            if phase == "timeBeforeCommit" {
                members += 1
                if members == 2 { throw PhotoError.message("提交校时失败：Operation not supported") }
            }
        }
        let failed = try execute(oldPlan, using: previousFailure)
        XCTAssertEqual(failed.items[0].files[0].state, "done")
        XCTAssertEqual(failed.items[0].files[1].state, "committing")
        let resumed = try execute(failed, using: compatible)
        XCTAssertEqual(resumed.done, 1); XCTAssertEqual(try store.photos().first?.capture, oldPlan.items[0].newCapture)
        XCTAssertEqual(try undo(resumed).status, "undone")
    }

    func testTimePublicationUndoAndConflict() throws {
        try pair()
        let stop = OperationService(store: store, metadata: metadata) { phase in
            if phase == "timeExclusiveRename" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTSUP)) }
            if phase == "timePublicationCreated" { throw PhotoError.message("stop") }
        }
        let plan = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        let partial = try execute(plan, using: stop)
        XCTAssertEqual(try undo(partial).status, "undone")
        let next = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        let interrupted = try execute(next, using: stop)
        let xmp = try XCTUnwrap(interrupted.items[0].files.first { $0.timeEdit?.role == "new" }?.source)
        try Data("external content".utf8).write(to: URL(fileURLWithPath: xmp))
        XCTAssertEqual(try execute(interrupted).done, 0)
        XCTAssertEqual(try undo(interrupted).status, "undoFailed")
        XCTAssertEqual(try String(contentsOfFile: xmp), "external content")
    }

    func testTimeExFATIntegration() throws {
        guard let volume = ProcessInfo.processInfo.environment["PHOTOARCHIVE_EXFAT_TEST_ROOT"] else {
            print("SKIP: real exFAT test requires explicitly configured disposable test root")
            return
        }
        let isolated = URL(fileURLWithPath: volume).appendingPathComponent(".photoarchive-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: isolated) }
        source = isolated
        let (jpg, raw) = try pair(), original = try [jpg, raw].map { try Fingerprint.read($0) }
        var usedFallback = 0
        let real = OperationService(store: store, metadata: metadata) { phase in
            if phase == "timePublicationCreated" { usedFallback += 1 }
        }
        let plan = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        let done = try execute(plan, using: real)
        XCTAssertEqual(done.done, 1, done.items.compactMap(\.error).joined())
        XCTAssertEqual(usedFallback, 1)
        XCTAssertEqual(try undo(done).status, "undone")
        for (path, hash) in zip([jpg, raw], original) { XCTAssertEqual(try Fingerprint.read(path), hash) }
        let retryPlan = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        var commits = 0
        let old = OperationService(store: store, metadata: metadata) { phase in
            if phase == "timeBeforeCommit" { commits += 1; if commits == 2 { throw PhotoError.message("old release interruption") } }
        }
        let interrupted = try execute(retryPlan, using: old)
        XCTAssertEqual(interrupted.items[0].files[0].state, "done")
        let resumed = try execute(interrupted, using: real)
        XCTAssertEqual(resumed.done, 1, resumed.items.compactMap(\.error).joined())
        XCTAssertEqual(try store.photos().first?.capture, retryPlan.items[0].newCapture)
        XCTAssertEqual(try undo(resumed).status, "undone")
        for (path, hash) in zip([jpg, raw], original) { XCTAssertEqual(try Fingerprint.read(path), hash) }
        print("EXFAT: isolated fixture edit, old-journal resume and byte-exact undo passed; user photos untouched")
    }
}
