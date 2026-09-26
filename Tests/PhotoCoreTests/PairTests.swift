import Foundation
import PhotoCore

extension PhotoCoreTests {
    @discardableResult func pair(_ name: String = "pair", jpeg: String = "JPG", raw: String = "CR2") throws -> (String, String) {
        (try fixture("Canon.jpg", as: name + "." + jpeg), try fixture("CanonRaw.cr2", as: name + "." + raw))
    }
    func testPairScanAndMigration() throws {
        let (jpg, raw) = try pair()
        var a = Photo(path: jpg, source: source.path), b = Photo(path: raw, source: source.path)
        a.place = "北京"; a.manualPlace = true; b.place = "上海"; b.manualPlace = true
        try store.save([a, b])
        let p = try XCTUnwrap(scan().first)
        XCTAssertEqual(try store.photos().count, 1); XCTAssertEqual(p.id, b.id)
        XCTAssertEqual(p.files.map(\.path), [raw, jpg]); XCTAssertEqual(p.previewPaths, [jpg, raw])
        XCTAssertEqual(p.place, "上海"); XCTAssertNotNil(p.notice); XCTAssertNil(p.problem)
        XCTAssertEqual(p.bytes, p.files.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(try scan().first?.id, b.id); XCTAssertEqual(try store.photos().count, 1)
        // Decode a real old payload, including one embedded in history.
        let data = try JSONEncoder().encode(a)
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        for key in ["members", "sidecarCapture", "sidecarBytes", "captureSource", "notice"] { json.removeValue(forKey: key) }
        let legacy = try JSONDecoder().decode(Photo.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy.files.count, 1); XCTAssertEqual(legacy.files[0].path, jpg)
    }
    func testPairLateArrivalMissingAndRecovery() throws {
        let raw = try fixture("CanonRaw.cr2", as: "late.cr2")
        let old = try XCTUnwrap(scan().first)
        let jpg = try fixture("Canon.jpg", as: "late.jpeg")
        var p = try XCTUnwrap(scan().first)
        XCTAssertTrue(p.isPair); XCTAssertEqual(p.id, old.id)
        let parked = root.appendingPathComponent("parked.jpeg").path
        try FileManager.default.moveItem(atPath: jpg, toPath: parked)
        p = try XCTUnwrap(scan().first); XCTAssertTrue(p.isPair); XCTAssertNotNil(p.problem)
        XCTAssertEqual(try service.archivePlan(photos: [p], root: root.appendingPathComponent("archive"), cancellation: CancellationFlag()).items.first?.status, "blocked")
        try FileManager.default.moveItem(atPath: parked, toPath: jpg)
        p = try XCTUnwrap(scan().first); XCTAssertNil(p.problem); XCTAssertEqual(p.id, old.id)
        try FileManager.default.moveItem(atPath: jpg, toPath: parked)
        let parkedRaw = root.appendingPathComponent("parked.cr2").path
        try FileManager.default.moveItem(atPath: raw, toPath: parkedRaw)
        p = try XCTUnwrap(scan().first); XCTAssertTrue(p.isPair); XCTAssertNotNil(p.problem)
    }
    func testPairScopesAndChunkBoundaries() throws {
        for i in 0..<41 { try pair(String(format: "pair%03d", i)) }
        let sub = source.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: source.appendingPathComponent("pair000.JPG").path, toPath: sub.appendingPathComponent("pair000.JPG").path)
        let photos = try scan()
        XCTAssertEqual(photos.count, 42); XCTAssertEqual(photos.filter(\.isPair).count, 41)
        XCTAssertEqual(photos.filter { !$0.isPair }.first?.path, sub.appendingPathComponent("pair000.JPG").path)
        XCTAssertEqual(try scan().count, 42)
    }
    func testPairAmbiguity() throws {
        try pair()
        try fixture("Canon.jpg", as: "pair.jpeg")
        XCTAssertEqual(try scan().count, 3); XCTAssertTrue(try scan().allSatisfy { $0.problem != nil })
        try FileManager.default.removeItem(at: source.appendingPathComponent("pair.jpeg"))
        // Use a new stem for portable multiple-XMP tests on case-insensitive disks.
        // The unsupported same-name RAW remains a genuine ambiguity everywhere.
        try fixture("Nikon.nef", as: "pair.nef")
        XCTAssertTrue(try scan().allSatisfy { $0.problem != nil })
    }
    func testPairCapturePriorityAndGPS() throws {
        let (jpg, raw) = try pair()
        try metadata.write(CaptureTime("2022:01:02 03:04:05", offset: "+08:00"), to: jpg, xmpOnly: false)
        var p = try XCTUnwrap(scan().first)
        let rawCapture = metadata.capture(try metadata.read([raw])[raw]!)
        XCTAssertEqual(p.capture, rawCapture); XCTAssertEqual(p.captureSource, "CR2"); XCTAssertTrue(p.timeDiffers)
        try metadata.run(["-overwrite_original", "-GPSLatitude=31.2", "-GPSLatitudeRef=N", "-GPSLongitude=121.4", "-GPSLongitudeRef=E", jpg])
        p = try XCTUnwrap(scan().first)
        XCTAssertEqual(p.latitude ?? 0, 31.2, accuracy: 0.001); XCTAssertEqual(p.longitude ?? 0, 121.4, accuracy: 0.001)
        let xmp = source.appendingPathComponent("pair.xmp").path
        try metadata.write(CaptureTime("2023:01:02 03:04:05", offset: "+08:00"), to: xmp, xmpOnly: true)
        p = try XCTUnwrap(scan().first)
        XCTAssertEqual(p.capture?.value, "2023:01:02 03:04:05"); XCTAssertEqual(p.captureSource, "XMP")
        // Invalid/missing RAW time falls back to JPEG. Only test fixture bytes are edited.
        try metadata.run(["-overwrite_original", "-EXIF:DateTimeOriginal=", "-EXIF:CreateDate=", raw])
        try FileManager.default.removeItem(atPath: xmp)
        // Existing binding intentionally retains a missing sidecar; create a fresh index for fallback.
        let fresh = try Store(directory: root.appendingPathComponent("fresh"))
        try Scanner(metadata: metadata, store: fresh).scan(root: source, cancellation: CancellationFlag()) { _, _, _ in }
        XCTAssertEqual(try fresh.photos().first?.capture?.value, "2022:01:02 03:04:05")
    }
    func testPairTimeAndExactUndo() throws {
        let (jpg, raw) = try pair()
        let jpgBefore = try Fingerprint.read(jpg), rawBefore = try Fingerprint.read(raw)
        for edit: TimeEdit in [.shift(3600), .set("2026:01:02 03:04:05"), .dateOnly("2025:02:03")] {
            let p = try XCTUnwrap(scan().first), expected = try edit.apply(to: p.capture)
            let result = try execute(service.timePlan(photos: [p], edit: edit, cancellation: CancellationFlag()))
            XCTAssertEqual(result.done, 1, result.items.compactMap(\.error).joined())
            let updated = try XCTUnwrap(scan().first)
            XCTAssertEqual(updated.files.first(where: { !$0.isRAW })?.capture, expected)
            XCTAssertEqual(updated.sidecarCapture, expected); XCTAssertEqual(try Fingerprint.read(raw), rawBefore)
            XCTAssertEqual(try undo(result).status, "undone")
            XCTAssertEqual(try Fingerprint.read(jpg), jpgBefore); XCTAssertEqual(try Fingerprint.read(raw), rawBefore)
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("pair.xmp").path))
        }
    }
    func testPairExistingXMPAndNoOpSynchronization() throws {
        let (jpg, raw) = try pair()
        let xmp = source.appendingPathComponent("pair.xmp").path
        try metadata.run(["-XMP:Rating=5", "-XMP-exif:DateTimeOriginal=2026:02:03 04:05:06+08:00", xmp])
        let before = try Fingerprint.read(xmp), jpgBefore = try Fingerprint.read(jpg), rawBefore = try Fingerprint.read(raw)
        let p = try XCTUnwrap(scan().first)
        let plan = try service.timePlan(photos: [p], edit: .shift(0), cancellation: CancellationFlag())
        XCTAssertEqual(plan.items[0].status, "pending")
        let result = try execute(plan); XCTAssertEqual(result.done, 1)
        XCTAssertEqual(String(decoding: try metadata.run(["-s3", "-XMP:Rating", xmp]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "5")
        let updated = try XCTUnwrap(scan().first)
        XCTAssertEqual(try service.timePlan(photos: [updated], edit: .shift(0), cancellation: CancellationFlag()).items[0].status, "skipped")
        XCTAssertEqual(try Fingerprint.read(raw), rawBefore)
        XCTAssertEqual(try undo(result).status, "undone")
        XCTAssertEqual(try Fingerprint.read(xmp), before); XCTAssertEqual(try Fingerprint.read(jpg), jpgBefore)
    }
    func testPairArchiveCollisionRetryAndUndo() throws {
        let (jpg, raw) = try pair()
        let xmp = source.appendingPathComponent("pair.xmp").path
        try metadata.write(CaptureTime("2026:01:02 03:04:05"), to: xmp, xmpOnly: true)
        let originals = try [jpg, raw, xmp].map { try Fingerprint.read($0) }
        var p = try XCTUnwrap(scan().first); p.place = "上海"; p.manualPlace = true; try store.save(p)
        let target = root.appendingPathComponent("archive"), dir = target.appendingPathComponent("2026/01/上海")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let occupied = dir.appendingPathComponent("pair.JPG"); try Data("keep".utf8).write(to: occupied)
        let plan = try service.archivePlan(photos: [p], root: target, cancellation: CancellationFlag())
        XCTAssertEqual(plan.items.count, 1); XCTAssertEqual(plan.items[0].files.count, 3)
        XCTAssertTrue(plan.items[0].files.allSatisfy { URL(fileURLWithPath: $0.destination).deletingPathExtension().lastPathComponent == "pair_1" })
        let failing = OperationService(store: store, metadata: metadata, forceCopy: true) { phase in if phase == "beforeSourceDelete" { throw PhotoError.message("模拟中断") } }
        let failed = try execute(plan, using: failing); XCTAssertEqual(failed.done, 0)
        let result = try execute(failed); XCTAssertEqual(result.done, 1, result.items.compactMap(\.error).joined())
        XCTAssertEqual(try store.photos().count, 1); XCTAssertEqual(try store.photos().first?.id, p.id)
        XCTAssertTrue(try store.photos().first?.isPair == true)
        XCTAssertEqual(try undo(result).status, "undone")
        for (path, fingerprint) in zip([jpg, raw, xmp], originals) { XCTAssertEqual(try Fingerprint.read(path), fingerprint) }
        XCTAssertEqual(try String(contentsOf: occupied), "keep"); XCTAssertEqual(try scan().count, 1)
    }
    func testPairPreflightAndPartialTimeResume() throws {
        let (jpg, raw) = try pair()
        let p = try XCTUnwrap(scan().first)
        let plan = try service.timePlan(photos: [p], edit: .shift(60), cancellation: CancellationFlag())
        let expected = plan.items[0].newCapture
        let done = try execute(plan); XCTAssertEqual(done.done, 1)
        var interrupted = done; interrupted.status = "running"; interrupted.items[0].status = "running"
        interrupted.items[0].files[0].state = "committing"; try store.save(interrupted)
        XCTAssertEqual(try execute(interrupted).done, 1); XCTAssertEqual(try scan().first?.capture, expected)
        try Data("external".utf8).write(to: URL(fileURLWithPath: raw))
        let after = try Fingerprint.read(jpg)
        XCTAssertEqual(try undo(done).status, "undoFailed"); XCTAssertEqual(try Fingerprint.read(jpg), after)
    }
    func testPairLegacyHistoryReconciliation() throws {
        let (jpg, raw) = try pair()
        var oldRaw = Photo(path: raw, source: source.path)
        oldRaw.capture = metadata.capture(try metadata.read([raw])[raw]!)
        let oldPlan = try service.archivePlan(photos: [oldRaw], root: root.appendingPathComponent("archive"), cancellation: CancellationFlag())
        try store.save(oldRaw)
        XCTAssertTrue(try scan().first?.isPair == true)
        let result = try execute(oldPlan); XCTAssertEqual(result.done, 1)
        XCTAssertEqual(try store.photos().count, 2)
        XCTAssertTrue(try store.photos().contains { $0.path == jpg })
        XCTAssertEqual(try undo(result).status, "undone")
        XCTAssertEqual(try store.photos().count, 1); XCTAssertEqual(try store.photos().first?.id, oldRaw.id)
        XCTAssertTrue(try store.photos().first?.isPair == true)
    }
}

extension PhotoCoreTests {
    func testPairPartialWriteResumeAndCancel() throws {
        let (jpg, raw) = try pair()
        let originals = try [jpg, raw].map { try Fingerprint.read($0) }
        let p = try XCTUnwrap(scan().first)
        let plan = try service.timePlan(photos: [p], edit: .shift(3600), cancellation: CancellationFlag())
        let failing = OperationService(store: store, metadata: metadata) { phase in
            if phase == "afterTimeMember" { throw PhotoError.message("JPG 已写入，模拟中断") }
        }
        let partial = try execute(plan, using: failing)
        XCTAssertEqual(partial.done, 0); XCTAssertEqual(partial.items[0].files[0].state, "done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.appendingPathComponent("pair.xmp").path))
        let flag = CancellationFlag()
        let resumed = try service.execute(partial, backupRoot: root.appendingPathComponent("backups"), cancellation: flag) { _ in flag.cancel() }
        XCTAssertEqual(resumed.done, 1); XCTAssertEqual(try scan().first?.capture, plan.items[0].newCapture)
        XCTAssertEqual(try undo(resumed).status, "undone")
        for (path, fingerprint) in zip([jpg, raw], originals) { XCTAssertEqual(try Fingerprint.read(path), fingerprint) }
    }
    func testPairWholeGroupPreflight() throws {
        let (jpg, raw) = try pair()
        let p = try XCTUnwrap(scan().first)
        let plan = try service.archivePlan(photos: [p], root: root.appendingPathComponent("archive"), cancellation: CancellationFlag())
        let occupied = URL(fileURLWithPath: plan.items[0].files[1].destination)
        try FileManager.default.createDirectory(at: occupied.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: occupied)
        XCTAssertEqual(try execute(plan).done, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw)); XCTAssertTrue(FileManager.default.fileExists(atPath: jpg))
        let time = try service.timePlan(photos: [p], edit: .shift(3600), cancellation: CancellationFlag())
        let before = try Fingerprint.read(jpg)
        try Data("changed raw".utf8).write(to: URL(fileURLWithPath: raw))
        XCTAssertEqual(try execute(time).done, 0); XCTAssertEqual(try Fingerprint.read(jpg), before)
        try FileManager.default.removeItem(atPath: raw)
        XCTAssertEqual(try service.timePlan(photos: [p], edit: .shift(0), cancellation: CancellationFlag()).items[0].status, "blocked")
    }
    func testPairLegacyJPGUndo() throws {
        let jpg = try fixture("Canon.jpg", as: "legacy.jpg")
        let original = try Fingerprint.read(jpg)
        let legacy = try XCTUnwrap(scan().first)
        let result = try execute(service.timePlan(photos: [legacy], edit: .shift(3600), cancellation: CancellationFlag()))
        try fixture("CanonRaw.cr2", as: "legacy.cr2")
        let pair = try XCTUnwrap(scan().first); XCTAssertTrue(pair.isPair)
        XCTAssertEqual(try undo(result).status, "undone")
        XCTAssertEqual(try store.photos().count, 1); XCTAssertTrue(try store.photos().first?.isPair == true)
        XCTAssertEqual(try Fingerprint.read(jpg), original)
    }
}
