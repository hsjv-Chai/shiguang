import Foundation
import PhotoCore

final class PhotoCoreTests: XCTestCase {
    var root: URL!
    var source: URL!
    var store: Store!
    var metadata: MetadataService!
    var service: OperationService!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("PhotoArchiveTests-" + UUID().uuidString)
        source = root.appendingPathComponent("原始照片")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        store = try Store(directory: root.appendingPathComponent("database"))
        metadata = try MetadataService.locate(); service = OperationService(store: store, metadata: metadata)
    }
    override func tearDownWithError() throws { service = nil; store = nil; try FileManager.default.removeItem(at: root) }
    @discardableResult func fixture(_ name: String = "Canon.jpg", as output: String? = nil) throws -> String {
        let src = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")!
        let dst = source.appendingPathComponent(output ?? name)
        try FileManager.default.copyItem(at: src, to: dst); return dst.path
    }
    func scan() throws -> [Photo] { try Scanner(metadata: metadata, store: store).scan(root: source, cancellation: CancellationFlag()) { _, _, _ in }; return try store.photos() }
    func execute(_ batch: OperationBatch, using service: OperationService? = nil) throws -> OperationBatch {
        try (service ?? self.service!).execute(batch, backupRoot: root.appendingPathComponent("backups"), cancellation: CancellationFlag()) { _ in }
    }
    func undo(_ batch: OperationBatch) throws -> OperationBatch { try service.undo(batch, cancellation: CancellationFlag()) { _ in } }
    func testDateBoundariesAndTimezone() throws {
        let t = CaptureTime("2023:12:31 23:30:00", offset: "+08:00", subseconds: "123")
        let result = try t.shifted(seconds: 3600)
        XCTAssertEqual(result.value, "2024:01:01 00:30:00"); XCTAssertEqual(result.offset, "+08:00"); XCTAssertEqual(result.subseconds, "123")
        XCTAssertEqual(try CaptureTime("2024:03:01 00:00:00").shifted(seconds: -1).value, "2024:02:29 23:59:59")
        XCTAssertEqual(try TimeEdit.dateOnly("2025:07:08").apply(to: t).value, "2025:07:08 23:30:00")
        XCTAssertNil(try TimeEdit.set("2026:01:01 00:00:00").apply(to: nil).offset)
        XCTAssertThrowsError(try TimeEdit.shift(5).apply(to: nil))
        XCTAssertNil(CaptureTime.parse("2025:02:30 00:00:00"))
    }
    func testAllRegularFormatsWriteAndByteExactUndo() throws {
        for name in ["Canon.jpg", "QuickTime.heic", "PNG.png", "ExifTool.tif"] { try fixture(name) }
        let photos = try scan(); XCTAssertEqual(photos.count, 4)
        let originals = try Dictionary(uniqueKeysWithValues: photos.map { ($0.path, try Fingerprint.read($0.path)) })
        let plan = try service.timePlan(photos: photos, edit: .set("2026:09:25 12:34:56"), cancellation: CancellationFlag())
        let result = try execute(plan)
        XCTAssertEqual(result.done, 4, result.items.compactMap(\.error).joined(separator: "\n"))
        for p in try store.photos() { XCTAssertEqual(metadata.capture(try metadata.read([p.path])[p.path] ?? [:])?.value, "2026:09:25 12:34:56") }
        let undone = try undo(result); XCTAssertEqual(undone.status, "undone", undone.items.compactMap(\.error).joined())
        for (path, hash) in originals { XCTAssertEqual(try Fingerprint.read(path), hash) }
    }
    func testRAWStaysUnchangedAndNewSidecarUndoDeletesIt() throws {
        for name in ["CanonRaw.cr2", "Nikon.nef", "FujiFilm.raf", "DNG.dng"] { try fixture(name) }
        let photos = try scan(); let originals = try Dictionary(uniqueKeysWithValues: photos.map { ($0.path, try Fingerprint.read($0.path)) })
        let result = try execute(service.timePlan(photos: photos, edit: .set("2024:02:29 10:20:30"), cancellation: CancellationFlag()))
        XCTAssertEqual(result.done, 4, result.items.compactMap(\.error).joined())
        for p in try scan() { XCTAssertEqual(p.capture?.value, "2024:02:29 10:20:30"); XCTAssertEqual(try Fingerprint.read(p.path), originals[p.path]); XCTAssertNotNil(p.sidecar) }
        XCTAssertEqual(try undo(result).status, "undone")
        for p in photos { XCTAssertFalse(FileManager.default.fileExists(atPath: URL(fileURLWithPath: p.path).deletingPathExtension().appendingPathExtension("xmp").path)) }
    }
    func testExistingXMPPreservesRatingAndRestoresBytes() throws {
        let raw = try fixture("CanonRaw.cr2"), xmp = source.appendingPathComponent("CanonRaw.xmp").path
        try metadata.run(["-XMP:Rating=4", "-XMP-exif:DateTimeOriginal=2020:01:02 03:04:05+08:00", xmp])
        let original = try Fingerprint.read(xmp), photo = try XCTUnwrap(scan().first)
        XCTAssertEqual(photo.capture?.value, "2020:01:02 03:04:05"); XCTAssertEqual(photo.capture?.offset, "+08:00")
        let result = try execute(service.timePlan(photos: [photo], edit: .shift(-8 * 3600), cancellation: CancellationFlag()))
        XCTAssertEqual(result.done, 1, result.items.compactMap(\.error).joined())
        let rating = String(decoding: try metadata.run(["-s3", "-XMP:Rating", xmp]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(rating, "4"); XCTAssertTrue(FileManager.default.fileExists(atPath: raw))
        XCTAssertEqual(try undo(result).status, "undone"); XCTAssertEqual(try Fingerprint.read(xmp), original)
    }
    func testArchiveCollisionSidecarAndUndo() throws {
        try fixture("CanonRaw.cr2", as: "风景.cr2")
        let xmp = source.appendingPathComponent("风景.xmp").path
        try metadata.run(["-XMP-exif:DateTimeOriginal=2026:09:25 01:00:00", xmp])
        var photo = try XCTUnwrap(scan().first); photo.place = "上海"; try store.save(photo)
        let target = root.appendingPathComponent("archive"), existing = target.appendingPathComponent("2026/09/上海/风景.cr2")
        try FileManager.default.createDirectory(at: existing.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unrelated".utf8).write(to: existing)
        let plan = try service.archivePlan(photos: [photo], root: target, cancellation: CancellationFlag())
        XCTAssertTrue(plan.items[0].files[0].destination.hasSuffix("风景_1.cr2")); XCTAssertTrue(plan.items[0].files[1].destination.hasSuffix("风景_1.xmp"))
        let result = try execute(plan); XCTAssertEqual(result.done, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: photo.path))
        XCTAssertEqual(try undo(result).status, "undone"); XCTAssertTrue(FileManager.default.fileExists(atPath: photo.path)); XCTAssertTrue(FileManager.default.fileExists(atPath: xmp)); XCTAssertEqual(try String(contentsOf: existing), "unrelated")
    }
    func testSourceChangedAfterPreviewCannotWrite() throws {
        let path = try fixture(); let plan = try service.timePlan(photos: scan(), edit: .set("2026:01:01 00:00:00"), cancellation: CancellationFlag())
        try Data("changed".utf8).write(to: URL(fileURLWithPath: path))
        let result = try execute(plan); XCTAssertEqual(result.done, 0); XCTAssertEqual(result.items[0].status, "failed"); XCTAssertEqual(try String(contentsOfFile: path), "changed")
    }
    func testDestinationAppearedAfterPreviewCannotOverwrite() throws {
        try fixture(); let plan = try service.archivePlan(photos: scan(), root: root.appendingPathComponent("archive"), cancellation: CancellationFlag())
        let dest = URL(fileURLWithPath: plan.items[0].files[0].destination)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true); try Data("keep".utf8).write(to: dest)
        XCTAssertEqual(try execute(plan).done, 0); XCTAssertEqual(try String(contentsOf: dest), "keep")
    }
    func testUndoRejectsExternalChanges() throws {
        let path = try fixture(); let result = try execute(service.timePlan(photos: scan(), edit: .set("2026:01:01 00:00:00"), cancellation: CancellationFlag()))
        try Data("external edit".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(try undo(result).status, "undoFailed"); XCTAssertEqual(try String(contentsOfFile: path), "external edit")
    }
    func testBackupFailureLeavesOriginalUntouched() throws {
        let path = try fixture(), before = try Fingerprint.read(path)
        let plan = try service.timePlan(photos: scan(), edit: .set("2026:01:01 00:00:00"), cancellation: CancellationFlag())
        let invalid = root.appendingPathComponent("not-a-directory"); try Data().write(to: invalid)
        let result = try service.execute(plan, backupRoot: invalid, cancellation: CancellationFlag()) { _ in }
        XCTAssertEqual(result.done, 0); XCTAssertEqual(try Fingerprint.read(path), before)
    }
    func testCopyMoveFailureBeforeDeleteKeepsSourceAndCanResume() throws {
        let path = try fixture(), before = try Fingerprint.read(path)
        let plan = try service.archivePlan(photos: scan(), root: root.appendingPathComponent("archive"), cancellation: CancellationFlag())
        let failing = OperationService(store: store, metadata: metadata, forceCopy: true) { phase in if phase == "beforeSourceDelete" { throw PhotoError.message("模拟设备断开") } }
        let interrupted = try execute(plan, using: failing)
        XCTAssertEqual(interrupted.items[0].status, "failed"); XCTAssertEqual(try Fingerprint.read(path), before)
        XCTAssertEqual(try Fingerprint.read(plan.items[0].files[0].destination), before)
        let resumed = try execute(interrupted); XCTAssertEqual(resumed.done, 1); XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(try undo(resumed).status, "undone"); XCTAssertEqual(try Fingerprint.read(path), before)
    }
    func testCancelAndResumeDoesNotDoubleShift() throws {
        try fixture("Canon.jpg", as: "one.jpg"); try fixture("Canon.jpg", as: "two.jpg")
        let photos = try scan(); let plan = try service.timePlan(photos: photos, edit: .shift(3600), cancellation: CancellationFlag())
        let flag = CancellationFlag()
        let paused = try service.execute(plan, backupRoot: root.appendingPathComponent("backup"), cancellation: flag) { _ in flag.cancel() }
        XCTAssertEqual(paused.done, 1); XCTAssertEqual(paused.status, "cancelled")
        let resumed = try execute(paused); XCTAssertEqual(resumed.done, 2)
        for p in try scan() { XCTAssertEqual(p.capture?.value, try photos.first(where: { $0.id == p.id })?.capture?.shifted(seconds: 3600).value) }
    }
    func testCrashAfterTimeCommitDoesNotShiftAgain() throws {
        try fixture(); let plan = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        var done = try execute(plan); let expected = done.items[0].newCapture
        done.status = "running"; done.items[0].status = "running"; done.items[0].files[0].state = "committing"; try store.save(done)
        XCTAssertEqual(try service.recoverInterrupted(), 1)
        let recovered = try XCTUnwrap(store.batches().first); XCTAssertEqual(recovered.status, "interrupted")
        XCTAssertEqual(try execute(recovered).done, 1); XCTAssertEqual(try scan().first?.capture, expected)
    }
    func testMissingTimeUsesUnknownAndNeverFileModificationDate() throws {
        let path = try fixture(); try metadata.run(["-all=", "-overwrite_original", path])
        let photos = try scan(); XCTAssertNil(photos[0].capture)
        let archive = try service.archivePlan(photos: photos, root: root.appendingPathComponent("archive"), cancellation: CancellationFlag())
        XCTAssertTrue(archive.items[0].files[0].destination.contains("未知时间/未知地点/"))
        let shift = try service.timePlan(photos: photos, edit: .shift(1), cancellation: CancellationFlag()); XCTAssertEqual(shift.items[0].status, "blocked")
        XCTAssertEqual(try execute(service.timePlan(photos: photos, edit: .set("2026:09:25 01:02:03"), cancellation: CancellationFlag())).done, 1)
    }
    func testSouthernWesternGPSAndManualPlacePersistence() throws {
        let path = try fixture(); try metadata.run(["-overwrite_original", "-GPSLatitude=33.8", "-GPSLatitudeRef=S", "-GPSLongitude=70.6", "-GPSLongitudeRef=W", path])
        var photo = try XCTUnwrap(scan().first); XCTAssertEqual(photo.latitude!, -33.8, accuracy: 0.001); XCTAssertEqual(photo.longitude!, -70.6, accuracy: 0.001)
        photo.place = "手动城市"; photo.manualPlace = true; try store.save(photo)
        XCTAssertEqual(try scan().first?.place, "手动城市")
    }
    func testTenThousandScanAndCancellation() throws {
        let template = try fixture(); let data = try Data(contentsOf: URL(fileURLWithPath: template))
        for i in 1..<10000 { try data.write(to: source.appendingPathComponent("照片-\(i).jpg")) }
        let start = Date(); let flag = CancellationFlag()
        try Scanner(metadata: metadata, store: store).scan(root: source, cancellation: flag) { done, _, _ in if done >= 80 { flag.cancel() } }
        XCTAssertEqual(try store.photos().count, 80)
        try Scanner(metadata: metadata, store: store).scan(root: source, cancellation: CancellationFlag()) { _, _, _ in }
        XCTAssertEqual(try store.photos().count, 10000)
        print("BENCHMARK: 10000 files scanned with cancellation/resume in \(Date().timeIntervalSince(start)) seconds")
    }
    func testUndoCopyMoveWithBothFilesAfterFailure() throws {
        let path = try fixture(), before = try Fingerprint.read(path)
        let plan = try service.archivePlan(photos: scan(), root: root.appendingPathComponent("archive"), cancellation: CancellationFlag())
        let failing = OperationService(store: store, metadata: metadata, forceCopy: true) { _ in throw PhotoError.message("模拟删除前断开") }
        let result = try execute(plan, using: failing)
        XCTAssertEqual(try undo(result).status, "undone")
        XCTAssertEqual(try Fingerprint.read(path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].files[0].destination))
    }
    func testUndoRestartAfterRestoredCopyBeforeDestinationDeletion() throws {
        let path = try fixture(), before = try Fingerprint.read(path)
        let plan = try service.archivePlan(photos: scan(), root: root.appendingPathComponent("archive"), cancellation: CancellationFlag())
        var result = try execute(plan)
        try FileManager.default.copyItem(atPath: result.items[0].files[0].destination, toPath: path)
        result.items[0].files[0].state = "undoing"; result.status = "undoing"; try store.save(result)
        XCTAssertEqual(try service.recoverInterrupted(), 1)
        XCTAssertEqual(try undo(XCTUnwrap(store.batches().first)).status, "undone")
        XCTAssertEqual(try Fingerprint.read(path), before)
    }
    func testPhotosLibraryIsNotTraversed() throws {
        let library = source.appendingPathComponent("Private.photoslibrary")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        XCTAssertThrowsError(try Scanner(metadata: metadata, store: store).scan(root: library, cancellation: CancellationFlag()) { _, _, _ in })
    }

    func testCorruptBackupPreventsRetryMutation() throws {
        let path = try fixture(), before = try Fingerprint.read(path)
        var plan = try service.timePlan(photos: scan(), edit: .shift(60), cancellation: CancellationFlag())
        let backup = root.appendingPathComponent("broken-backup")
        try Data("broken".utf8).write(to: backup)
        plan.items[0].files[0].backup = backup.path
        XCTAssertEqual(try execute(plan).done, 0)
        XCTAssertEqual(try Fingerprint.read(path), before)
    }

}
