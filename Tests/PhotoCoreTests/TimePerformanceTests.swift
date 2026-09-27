import Foundation
import Darwin
import PhotoCore

extension PhotoCoreTests {
    func testTimePreviewBatchesAndLargeRAW() throws {
        let seed = try fixture(), row = try XCTUnwrap(metadata.read([seed])[seed])
        let capture = try XCTUnwrap(metadata.capture(row)), bytes = try Data(contentsOf: URL(fileURLWithPath: seed))
        var photos: [Photo] = []
        for i in 0..<384 {
            let jpg = source.appendingPathComponent("IMG_\(i).JPG").path, raw = source.appendingPathComponent("IMG_\(i).CR2").path
            try bytes.write(to: URL(fileURLWithPath: jpg))
            FileManager.default.createFile(atPath: raw, contents: nil)
            let h = try FileHandle(forWritingTo: URL(fileURLWithPath: raw)); try h.truncate(atOffset: 40_000_000); try h.close()
            var p = Photo(path: raw); p.capture = capture
            p.members = [PhotoMember(path: raw, bytes: 40_000_000, capture: capture), PhotoMember(path: jpg, bytes: Int64(bytes.count), capture: capture)]
            photos.append(p)
        }
        var metadataCalls = 0, contentReads = 0
        let fast = OperationService(store: store, metadata: metadata) { phase in
            if phase == "timePreviewMetadataBatch" { metadataCalls += 1 }
            if phase.hasPrefix("timeHash:") || phase.hasPrefix("timeCopy:") { contentReads += 1 }
        }
        let start = Date(), probe = TimeProgressProbe()
        let plan = try fast.timePlan(photos: photos, edit: .shift(60), cancellation: CancellationFlag()) { done, _, _ in probe.add(done) }
        XCTAssertEqual(metadataCalls, 3); XCTAssertEqual(contentReads, 0)
        XCTAssertEqual(plan.items.filter { $0.status == "pending" }.count, 384)
        XCTAssertTrue(plan.items.allSatisfy { $0.files.allSatisfy { $0.before == nil && $0.timeEdit != nil } })
        XCTAssertEqual(probe.last, 384); XCTAssertTrue(probe.count >= 5)
        print("BENCHMARK: 384 real JPG + 15.36 GB sparse RAW preview, 3 ExifTool batches, \(Date().timeIntervalSince(start)) seconds; local filesystem, warm cache possible; not an execution benchmark")
        let flag = CancellationFlag()
        let stopped = try fast.timePlan(photos: photos, edit: .shift(60), cancellation: flag) { _, _, _ in flag.cancel() }
        XCTAssertEqual(stopped.status, "cancelled"); XCTAssertTrue(stopped.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("IMG_0.xmp").path))
    }
    func testTimePreviewCancelsRunningMetadataProcess() throws {
        let path = try fixture(), photos = try scan(), flag = CancellationFlag()
        let script = root.appendingPathComponent("slow.pl"), pidFile = root.appendingPathComponent("process.pid")
        try "open(my $f, '>', '\(pidFile.path)') or die; print $f $$; close $f; sleep 30; print '[]';".write(to: script, atomically: true, encoding: .utf8)
        let slow = OperationService(store: store, metadata: MetadataService(executable: metadata.executable, script: script))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { flag.cancel() }
        let start = Date()
        let plan = try slow.timePlan(photos: photos, edit: .shift(1), cancellation: flag)
        XCTAssertEqual(plan.status, "cancelled"); XCTAssertTrue(plan.items.isEmpty)
        XCTAssertTrue(Date().timeIntervalSince(start) < 3)
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile)))
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }
    func testTimePreviewIsolationAndChanges() throws {
        let good = try fixture("Canon.jpg", as: "good.jpg"), bad = try fixture("Canon.jpg", as: "bad.jpg")
        let photos = try scan()
        try Data("corrupt".utf8).write(to: URL(fileURLWithPath: bad))
        let plan = try service.timePlan(photos: photos, edit: .shift(1), cancellation: CancellationFlag())
        XCTAssertEqual(plan.items.first { $0.photo.path == good }?.status, "pending")
        XCTAssertEqual(plan.items.first { $0.photo.path == bad }?.status, "blocked")
        let changing = OperationService(store: store, metadata: metadata) { phase in
            if phase == "timePreviewMetadataFinished" {
                let attrs = try FileManager.default.attributesOfItem(atPath: good)
                let h = try FileHandle(forWritingTo: URL(fileURLWithPath: good)); try h.write(contentsOf: Data([0, 1])); try h.close()
                try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: good)
            }
        }
        XCTAssertEqual(try changing.timePlan(photos: [photos.first { $0.path == good }!], edit: .shift(1), cancellation: CancellationFlag()).items[0].status, "blocked")
    }
    func testTimeExecutionReadsAndFractions() throws {
        let (jpg, raw) = try pair()
        try metadata.run(["-overwrite_original", "-DateTimeOriginal=2026:01:02 03:04:05", "-SubSecTimeOriginal=007", "-OffsetTimeOriginal=+08:00", raw, jpg])
        let photos = try scan(), original = try [jpg, raw].map { try Fingerprint.read($0) }
        var phases: [String: Int] = [:]
        let fast = OperationService(store: store, metadata: metadata) { phase in phases[phase, default: 0] += 1 }
        let plan = try fast.timePlan(photos: photos, edit: .shift(1), cancellation: CancellationFlag())
        let start = Date(), done = try execute(plan, using: fast)
        XCTAssertEqual(done.done, 1, done.items.compactMap(\.error).joined())
        print("BENCHMARK: real JPG+CR2 fixtures time edit including backup, validation and XMP creation: \(Date().timeIntervalSince(start)) seconds; local filesystem, warm cache possible")
        XCTAssertEqual(phases["timeCopy:备份"], 1); XCTAssertEqual(phases["timeHash:校验备份"], 1)
        XCTAssertEqual(phases["timeIndexFastPath"], 1)
        let readonly = try XCTUnwrap(done.items[0].files.first { $0.source == raw })
        XCTAssertNil(readonly.before); XCTAssertNil(readonly.backup); XCTAssertEqual(readonly.timeEdit?.role, "readonly")
        let capture = try XCTUnwrap(metadata.read([jpg])[jpg].flatMap { metadata.capture($0) })
        XCTAssertEqual(capture.subseconds, "007"); XCTAssertEqual(capture.offset, "+08:00")
        XCTAssertEqual(try store.photos().first?.sidecarCapture, done.items[0].newCapture)
        XCTAssertEqual(try undo(done).status, "undone")
        for (path, hash) in zip([jpg, raw], original) { XCTAssertEqual(try Fingerprint.read(path), hash) }
    }
    func testTimeFaultWindowsAndRecovery() throws {
        let (jpg, raw) = try pair(), hashes = try [jpg, raw].map { try Fingerprint.read($0) }
        for phase in ["timeBeforeBackupVerify", "timeBeforeMetadataWrite", "timeBeforeCommit", "timeAfterRename", "afterTimeMember"] {
            let plan = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
            let failing = OperationService(store: store, metadata: metadata) { at in if at == phase { throw PhotoError.message("injected " + phase) } }
            let failed = try execute(plan, using: failing)
            XCTAssertEqual(failed.done, 0)
            let saved = try XCTUnwrap(store.batches().first { $0.id == failed.id })
            let resumed = try execute(saved)
            XCTAssertEqual(resumed.done, 1, phase + ": " + resumed.items.compactMap(\.error).joined())
            XCTAssertEqual(try store.photos().first?.capture, plan.items[0].newCapture)
            XCTAssertEqual(try undo(resumed).status, "undone")
            for (path, hash) in zip([jpg, raw], hashes) { XCTAssertEqual(try Fingerprint.read(path), hash) }
        }
        for phase in ["timeBeforeUndoCommit", "timeAfterUndoRename"] {
            let done = try execute(service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag()))
            let failing = OperationService(store: store, metadata: metadata) { at in if at == phase { throw PhotoError.message("undo interruption") } }
            let failed = try failing.undo(done, cancellation: CancellationFlag()) { _ in }
            XCTAssertEqual(failed.status, "undoFailed")
            let saved = try XCTUnwrap(store.batches().first { $0.id == done.id })
            XCTAssertEqual(try undo(saved).status, "undone")
            for (path, hash) in zip([jpg, raw], hashes) { XCTAssertEqual(try Fingerprint.read(path), hash) }
        }
    }
    func testTimeFailuresCancelAndNewXMPConflict() throws {
        let (jpg, raw) = try pair(), hashes = try [jpg, raw].map { try Fingerprint.read($0) }
        let plan = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        let noSpace = OperationService(store: store, metadata: metadata) { phase in
            if phase == "timeCopyChunk:备份" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
        }
        let failed = try execute(plan, using: noSpace)
        XCTAssertEqual(failed.done, 0)
        let resumed = try execute(failed); XCTAssertEqual(resumed.done, 1, resumed.items.compactMap(\.error).joined())
        XCTAssertEqual(try undo(resumed).status, "undone")
        let next = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag()), flag = CancellationFlag()
        let cancelling = OperationService(store: store, metadata: metadata) { phase in if phase == "timeCopyChunk:备份" { flag.cancel() } }
        let cancelled = try cancelling.execute(next, backupRoot: root.appendingPathComponent("backups"), cancellation: flag) { _ in }
        XCTAssertEqual(cancelled.status, "cancelled")
        XCTAssertEqual(try undo(cancelled).status, "undone")
        for (path, hash) in zip([jpg, raw], hashes) { XCTAssertEqual(try Fingerprint.read(path), hash) }
        let conflict = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        let xmp = source.appendingPathComponent("pair.xmp")
        try Data("keep".utf8).write(to: xmp)
        XCTAssertEqual(try execute(conflict).done, 0)
        XCTAssertEqual(try String(contentsOf: xmp), "keep")
        XCTAssertEqual(try Fingerprint.read(jpg), hashes[0])
    }
    func testTimePreparationFailureAndWriteCancellation() throws {
        let (jpg, raw) = try pair(), hashes = try [jpg, raw].map { try Fingerprint.read($0) }
        let plan = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        var writes = 0
        let failing = OperationService(store: store, metadata: metadata) { phase in
            if phase == "timeBeforeMetadataWrite" {
                writes += 1
                if writes == 2 { throw PhotoError.message("second scratch failed") }
            }
        }
        let failed = try execute(plan, using: failing)
        XCTAssertEqual(failed.done, 0)
        for (path, hash) in zip([jpg, raw], hashes) { XCTAssertEqual(try Fingerprint.read(path), hash) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("pair.xmp").path))
        let script = root.appendingPathComponent("slow-write.pl"), pidFile = root.appendingPathComponent("write.pid")
        try "open(my $f, '>', '\(pidFile.path)') or die; print $f $$; close $f; sleep 30;".write(to: script, atomically: true, encoding: .utf8)
        let flag = CancellationFlag()
        let slow = OperationService(store: store, metadata: MetadataService(executable: metadata.executable, script: script))
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { flag.cancel() }
        let cancelled = try slow.execute(failed, backupRoot: root.appendingPathComponent("backups"), cancellation: flag) { _ in }
        XCTAssertEqual(cancelled.status, "cancelled")
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile)))
        XCTAssertEqual(kill(pid, 0), -1)
        for (path, hash) in zip([jpg, raw], hashes) { XCTAssertEqual(try Fingerprint.read(path), hash) }
        let resumed = try execute(cancelled)
        XCTAssertEqual(resumed.done, 1, resumed.items.compactMap(\.error).joined())
        XCTAssertEqual(try undo(resumed).status, "undone")
        let remaining = try FileManager.default.contentsOfDirectory(atPath: source.path).filter { $0.hasPrefix(".photoarchive-time-") }
        XCTAssertTrue(remaining.isEmpty)
    }
    func testTimeEqualLengthModificationAndReplacement() throws {
        let path = try fixture(), bytes = try Data(contentsOf: URL(fileURLWithPath: path)), photos = try scan()
        let plan = try service.timePlan(photos: photos, edit: .shift(60), cancellation: CancellationFlag())
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        var changed = bytes; changed[0] ^= 1
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); try handle.write(contentsOf: changed); try handle.close()
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: path)
        XCTAssertEqual(try execute(plan).done, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), changed)
        try bytes.write(to: URL(fileURLWithPath: path))
        let replacement = try service.timePlan(photos: photos, edit: .shift(60), cancellation: CancellationFlag())
        try bytes.write(to: URL(fileURLWithPath: path), options: .atomic)
        XCTAssertEqual(try execute(replacement).done, 0)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), bytes)
    }
    func testTimeLegacyJournalAndCorruptDurableBackup() throws {
        let path = try fixture(), original = try Fingerprint.read(path)
        var legacy = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        for j in legacy.items[0].files.indices {
            legacy.items[0].files[j].timeEdit = nil; legacy.items[0].files[j].before = try Fingerprint.read(legacy.items[0].files[j].source)
        }
        let data = try JSONEncoder().encode(legacy), decoded = try JSONDecoder().decode(OperationBatch.self, from: data)
        let done = try execute(decoded); XCTAssertEqual(done.done, 1)
        XCTAssertEqual(try undo(done).status, "undone"); XCTAssertEqual(try Fingerprint.read(path), original)
        let next = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        let failing = OperationService(store: store, metadata: metadata) { phase in if phase == "timeBeforeMetadataWrite" { throw PhotoError.message("pause") } }
        let failed = try execute(next, using: failing)
        let backup = try XCTUnwrap(failed.items[0].files[0].backup)
        try Data("broken".utf8).write(to: URL(fileURLWithPath: backup))
        XCTAssertEqual(try execute(failed).done, 0)
        XCTAssertEqual(try Fingerprint.read(path), original)
    }
}

private final class TimeProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func add(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
    var last: Int? { lock.lock(); defer { lock.unlock() }; return values.last }
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
}
