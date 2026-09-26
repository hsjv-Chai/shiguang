import Foundation
import Darwin
import PhotoCore

extension PhotoCoreTests {
    private func transferPlan(_ name: String = UUID().uuidString) throws -> OperationBatch {
        try service.archivePlan(photos: scan(), root: root.appendingPathComponent(name), cancellation: CancellationFlag())
    }
    func testArchiveReadCountsAndMetadata() throws {
        let path = try fixture()
        let attr = "com.photoarchive.test", value = Array("metadata preserved".utf8)
        let result = value.withUnsafeBytes { setxattr(path, attr, $0.baseAddress, value.count, 0, 0) }
        XCTAssertEqual(result, 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: path)
        let original = try FileSnapshot.read(path)
        for copy in [false, true] {
            var sourceReads = 0, verifies = 0
            let fast = OperationService(store: store, metadata: metadata, forceCopy: copy) { phase in
                if phase == "archiveSourceRead" { sourceReads += 1 }
                if phase == "archiveVerifyRead" { verifies += 1 }
            }
            let archived = try execute(transferPlan(), using: fast)
            XCTAssertEqual(archived.done, 1, archived.items.compactMap(\.error).joined())
            XCTAssertEqual(sourceReads, copy ? 1 : 0); XCTAssertEqual(verifies, copy ? 1 : 0)
            let destination = archived.items[0].files[0].destination
            let snapshot = try FileSnapshot.read(destination)
            XCTAssertEqual(snapshot.modifiedSeconds, original.modifiedSeconds)
            XCTAssertEqual(snapshot.modifiedNanoseconds, original.modifiedNanoseconds)
            XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: destination)[.posixPermissions] as? NSNumber)?.intValue, 0o640)
            var buffer = [UInt8](repeating: 0, count: value.count)
            let count = buffer.withUnsafeMutableBytes { getxattr(destination, attr, $0.baseAddress, value.count, 0, 0) }
            XCTAssertEqual(count, value.count); XCTAssertEqual(buffer, value)
            sourceReads = 0; verifies = 0
            let restored = try fast.undo(archived, cancellation: CancellationFlag()) { _ in }
            XCTAssertEqual(restored.status, "undone", restored.items.compactMap(\.error).joined())
            if !copy { XCTAssertEqual(sourceReads, 0); XCTAssertEqual(verifies, 0) }
        }
    }
    func testArchiveFaultWindows() throws {
        let path = try fixture(), original = try Fingerprint.read(path)
        for copy in [false, true] {
            let phases = ["archiveBeforeCommit", "archiveAfterRename", "archiveAfterCommit"] + (copy ? ["beforeSourceDelete", "archiveAfterSourceDelete"] : [])
            for phase in phases {
                let plan = try transferPlan()
                let failing = OperationService(store: store, metadata: metadata, forceCopy: copy) { at in
                    if at == phase { throw PhotoError.message("injected " + phase) }
                }
                let failed = try execute(plan, using: failing)
                XCTAssertEqual(failed.items[0].status, "failed")
                // Reload the durable journal rather than reuse the in-memory object.
                let saved = try XCTUnwrap(store.batches().first { $0.id == failed.id })
                let resumed = try execute(saved)
                XCTAssertEqual(resumed.done, 1, phase + ": " + resumed.items.compactMap(\.error).joined())
                XCTAssertEqual(try Fingerprint.read(plan.items[0].files[0].destination), original)
                XCTAssertEqual(try undo(resumed).status, "undone")
                XCTAssertEqual(try Fingerprint.read(path), original)
            }
        }
    }
    func testArchiveCopyCorruptionAndGroupPreparation() throws {
        let (jpg, raw) = try pair()
        let originals = try [jpg, raw].map { try Fingerprint.read($0) }
        let plan = try transferPlan()
        var count = 0
        let corrupting = OperationService(store: store, metadata: metadata, forceCopy: true) { phase in
            guard phase == "archiveBeforeVerify" else { return }
            count += 1
            if count == 2 {
                let saved = try XCTUnwrap(self.store.batches().first { $0.id == plan.id })
                let staged = try XCTUnwrap(saved.items[0].files.first { $0.transfer?.phase == "staging" }?.transfer?.staged)
                let h = try FileHandle(forWritingTo: URL(fileURLWithPath: staged)); try h.write(contentsOf: Data([0, 1, 2, 3])); try h.close()
            }
        }
        let failed = try execute(plan, using: corrupting)
        XCTAssertEqual(failed.done, 0)
        for (path, hash) in zip([jpg, raw], originals) { XCTAssertEqual(try Fingerprint.read(path), hash) }
        for f in plan.items[0].files { XCTAssertFalse(FileManager.default.fileExists(atPath: f.destination)) }
        let resumed = try execute(failed); XCTAssertEqual(resumed.done, 1, resumed.items.compactMap(\.error).joined())
        XCTAssertEqual(try undo(resumed).status, "undone")
    }
    func testArchiveWriteFailureCancellationAndCleanup() throws {
        let path = try fixture(), hash = try Fingerprint.read(path)
        let plan = try transferPlan()
        let noSpace = OperationService(store: store, metadata: metadata, forceCopy: true) { phase in
            if phase == "archiveCopyChunk" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        }
        let failed = try execute(plan, using: noSpace)
        XCTAssertEqual(failed.done, 0); XCTAssertEqual(try Fingerprint.read(path), hash)
        XCTAssertEqual(try undo(failed).status, "undone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.items[0].files[0].transfer!.staged!))
        let next = try transferPlan(), flag = CancellationFlag()
        let copying = OperationService(store: store, metadata: metadata, forceCopy: true) { phase in
            if phase == "archiveCopyChunk" { flag.cancel() }
        }
        let cancelled = try copying.execute(next, backupRoot: root.appendingPathComponent("backup"), cancellation: flag) { _ in }
        XCTAssertEqual(cancelled.status, "cancelled"); XCTAssertEqual(try Fingerprint.read(path), hash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: next.items[0].files[0].destination))
        XCTAssertEqual(try undo(cancelled).status, "undone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cancelled.items[0].files[0].transfer!.staged!))
    }
    func testArchiveExternalChangesAndCommitCollision() throws {
        let path = try fixture()
        let plan = try transferPlan(), destination = plan.items[0].files[0].destination
        let colliding = OperationService(store: store, metadata: metadata) { phase in
            if phase == "archiveBeforeCommit" { try Data("occupied".utf8).write(to: URL(fileURLWithPath: destination)) }
        }
        XCTAssertEqual(try execute(plan, using: colliding).done, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path)); XCTAssertEqual(try String(contentsOfFile: destination), "occupied")
        let replacementPlan = try transferPlan()
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        try FileManager.default.removeItem(atPath: path); try data.write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(try execute(replacementPlan).done, 0)
        let done = try execute(transferPlan())
        let moved = done.items[0].files[0].destination
        let attrs = try FileManager.default.attributesOfItem(atPath: moved)
        var changed = data; changed[0] ^= 1
        try changed.write(to: URL(fileURLWithPath: moved))
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: moved)
        XCTAssertEqual(try undo(done).status, "undoFailed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }
    func testArchiveUndoFaultWindows() throws {
        let path = try fixture(), original = try Fingerprint.read(path)
        for copy in [false, true] {
            for phase in ["archiveBeforeCommit", "archiveAfterRename", "archiveAfterCommit"] + (copy ? ["beforeSourceDelete", "archiveAfterSourceDelete"] : []) {
                let done = try execute(transferPlan())
                let failing = OperationService(store: store, metadata: metadata, forceCopy: copy) { at in
                    if at == phase { throw PhotoError.message("undo injected") }
                }
                let interrupted = try failing.undo(done, cancellation: CancellationFlag()) { _ in }
                XCTAssertEqual(interrupted.status, "undoFailed")
                let saved = try XCTUnwrap(store.batches().first { $0.id == done.id })
                let resumed = try undo(saved)
                XCTAssertEqual(resumed.status, "undone", phase + ": " + resumed.items.compactMap(\.error).joined())
                XCTAssertEqual(try Fingerprint.read(path), original)
            }
        }
    }
    func testArchiveDeleteGuardsFallbackAndUndoDiscard() throws {
        let path = try fixture(), original = try Fingerprint.read(path)
        var renameAttempts = 0
        let fallback = OperationService(store: store, metadata: metadata) { phase in
            if phase == "archiveRenameAttempt" {
                renameAttempts += 1
                if renameAttempts == 1 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV)) }
            }
        }
        let fallbackResult = try execute(transferPlan(), using: fallback)
        XCTAssertEqual(fallbackResult.done, 1)
        XCTAssertEqual(fallbackResult.items[0].files[0].transfer?.strategy, "copy")
        XCTAssertEqual(try undo(fallbackResult).status, "undone")
        let plan = try transferPlan()
        let stopping = OperationService(store: store, metadata: metadata, forceCopy: true) { phase in
            if phase == "beforeSourceDelete" { throw PhotoError.message("stop before deletion") }
        }
        let both = try execute(plan, using: stopping)
        let failingUndo = OperationService(store: store, metadata: metadata) { phase in
            if phase == "archiveUndoAfterDiscard" { throw PhotoError.message("stop after discarding duplicate") }
        }
        let interrupted = try failingUndo.undo(both, cancellation: CancellationFlag()) { _ in }
        XCTAssertEqual(interrupted.status, "undoFailed")
        XCTAssertEqual(try undo(XCTUnwrap(store.batches().first { $0.id == plan.id })).status, "undone")
        XCTAssertEqual(try Fingerprint.read(path), original)
        let finalPlan = try transferPlan()
        let modifying = OperationService(store: store, metadata: metadata, forceCopy: true) { phase in
            if phase == "beforeSourceDelete" {
                let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try h.write(contentsOf: Data([0, 1, 2, 3])); try h.close()
            }
        }
        let failed = try execute(finalPlan, using: modifying)
        XCTAssertEqual(failed.done, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try Fingerprint.read(finalPlan.items[0].files[0].destination), original)
        XCTAssertEqual(try execute(failed).done, 0)
        XCTAssertEqual(try undo(failed).status, "undoFailed")
    }
    func testArchiveRecoveryRejectsReplacedTargetAndLegacyJSON() throws {
        let path = try fixture()
        let plan = try transferPlan()
        let failing = OperationService(store: store, metadata: metadata) { phase in
            if phase == "archiveAfterRename" { throw PhotoError.message("rename journal gap") }
        }
        let failed = try execute(plan, using: failing)
        let destination = plan.items[0].files[0].destination
        let bytes = try Data(contentsOf: URL(fileURLWithPath: destination))
        let saved = destination + ".saved"
        try FileManager.default.moveItem(atPath: destination, toPath: saved)
        try bytes.write(to: URL(fileURLWithPath: destination))
        XCTAssertEqual(try execute(failed).done, 0)
        XCTAssertEqual(try undo(failed).status, "undoFailed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        // Legacy journals have no transfer fields. Decode and execute their original path.
        try FileManager.default.copyItem(atPath: saved, toPath: path)
        var legacy = try transferPlan()
        for j in legacy.items[0].files.indices { legacy.items[0].files[j].transfer = nil }
        let encoded = try JSONEncoder().encode(legacy)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("\"transfer\""))
        let decoded = try JSONDecoder().decode(OperationBatch.self, from: encoded)
        let done = try execute(decoded)
        XCTAssertEqual(done.done, 1); XCTAssertNotNil(done.items[0].files[0].before)
        XCTAssertEqual(try undo(done).status, "undone")
    }
    func testArchiveRealDataBenchmark() throws {
        let path = source.appendingPathComponent("payload.jpg")
        // Allocate and write actual bytes. This is not a sparse-file preview benchmark.
        let block = Data((0..<(1024 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 37) })
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let h = try FileHandle(forWritingTo: path)
        for _ in 0..<64 { try h.write(contentsOf: block) }
        try h.synchronize(); try h.close()
        var p = Photo(path: path.path); p.members = [PhotoMember(path: path.path)]; try store.save(p)
        for copy in [false, true] {
            let plan = try service.archivePlan(photos: [p], root: root.appendingPathComponent(UUID().uuidString), cancellation: CancellationFlag())
            let fast = OperationService(store: store, metadata: metadata, forceCopy: copy)
            let start = Date(); let result = try execute(plan, using: fast)
            XCTAssertEqual(result.done, 1, result.items.compactMap(\.error).joined())
            print("BENCHMARK: 64 MiB real data \(copy ? "forced copy + verify" : "same-volume rename"): \(Date().timeIntervalSince(start)) seconds (local filesystem; cache may be warm)")
            XCTAssertEqual(try undo(result).status, "undone")
        }
    }
}
