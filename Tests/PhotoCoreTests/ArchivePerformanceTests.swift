import Foundation
import PhotoCore

private final class ProgressProbe: @unchecked Sendable {
    let lock = NSLock()
    private var values: [Int] = []
    func add(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
    var last: Int? { lock.lock(); defer { lock.unlock() }; return values.last }
}
extension PhotoCoreTests {
    func testLargeArchivePreviewIsMetadataOnly() throws {
        // Sparse 40 MB members simulate 80 GB without reading/writing that payload.
        var photos: [Photo] = []
        for i in 0..<1000 {
            let raw = source.appendingPathComponent("IMG_\(i).CR2").path
            let jpg = source.appendingPathComponent("IMG_\(i).JPG").path
            for path in [raw, jpg] {
                FileManager.default.createFile(atPath: path, contents: nil)
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
                try handle.truncate(atOffset: 40_000_000); try handle.close()
            }
            var p = Photo(path: raw, source: source.path)
            p.members = [PhotoMember(path: raw), PhotoMember(path: jpg)]
            photos.append(p)
        }
        var directoryLists = 0
        let fast = OperationService(store: store, metadata: metadata) { phase in if phase == "archiveDirectoryListed" { directoryLists += 1 } }
        let probe = ProgressProbe(), start = Date()
        let plan = try fast.archivePlan(photos: photos, root: root.appendingPathComponent("archive"), cancellation: CancellationFlag()) { done, _, _ in probe.add(done) }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(plan.items.count, 1000); XCTAssertEqual(directoryLists, 1)
        XCTAssertEqual(probe.last, 1000)
        XCTAssertTrue(plan.items.allSatisfy { $0.status == "pending" && $0.files.count == 2 && $0.files.allSatisfy { $0.before == nil && $0.previewSnapshot?.size == 40_000_000 } })
        print("BENCHMARK: 1000 JPG+CR2 groups / 80 GB sparse archive preview in \(elapsed) seconds; directory listings: \(directoryLists)")
        let flag = CancellationFlag()
        let cancelled = try fast.archivePlan(photos: photos, root: root.appendingPathComponent("archive"), cancellation: flag) { _, _, _ in flag.cancel() }
        XCTAssertEqual(cancelled.status, "cancelled"); XCTAssertTrue(cancelled.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("archive").path))
    }
    func testDeferredArchiveDetectsChangesAndCancels() throws {
        let (jpg, raw) = try pair()
        let p = try XCTUnwrap(scan().first)
        let plan = try service.archivePlan(photos: [p], root: root.appendingPathComponent("archive"), cancellation: CancellationFlag())
        let flag = CancellationFlag()
        let cancelled = try service.execute(plan, backupRoot: root.appendingPathComponent("backup"), cancellation: flag, activity: { _, _, _ in flag.cancel() }) { _ in }
        XCTAssertEqual(cancelled.status, "cancelled"); XCTAssertEqual(cancelled.items[0].status, "pending")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jpg)); XCTAssertTrue(FileManager.default.fileExists(atPath: raw))
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.items[0].files[0].destination))
        let resumed = try execute(cancelled); XCTAssertEqual(resumed.done, 1)
        XCTAssertEqual(try undo(resumed).status, "undone")
        let next = try service.archivePlan(photos: scan(), root: root.appendingPathComponent("archive2"), cancellation: CancellationFlag())
        let attrs = try FileManager.default.attributesOfItem(atPath: jpg)
        var data = try Data(contentsOf: URL(fileURLWithPath: jpg)); data[0] ^= 1; try data.write(to: URL(fileURLWithPath: jpg))
        try FileManager.default.setAttributes([.modificationDate: attrs[.modificationDate]!], ofItemAtPath: jpg)
        let failed = try execute(next); XCTAssertEqual(failed.done, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: raw)); XCTAssertEqual(try undo(failed).status, "undone")
    }
    func testArchiveFastPathAvoidsMetadataReread() throws {
        try pair(); let photos = try scan()
        let plan = try service.archivePlan(photos: photos, root: root.appendingPathComponent("archive"), cancellation: CancellationFlag())
        let unavailable = MetadataService(executable: URL(fileURLWithPath: "/nonexistent/perl"), script: URL(fileURLWithPath: "/nonexistent/exiftool"))
        let fast = OperationService(store: store, metadata: unavailable)
        let result = try execute(plan, using: fast); XCTAssertEqual(result.done, 1)
        XCTAssertNil(try store.photos().first?.problem)
        let undone = try fast.undo(result, cancellation: CancellationFlag()) { _ in }
        XCTAssertEqual(undone.status, "undone"); XCTAssertTrue(try store.photos().first?.isPair == true)
        XCTAssertNil(try store.photos().first?.problem)
    }
}
