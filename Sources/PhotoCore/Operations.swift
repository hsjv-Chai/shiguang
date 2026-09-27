import Foundation
import Darwin

public final class OperationService: @unchecked Sendable {
    let store: Store
    let metadata: MetadataService
    let fm = FileManager.default
    let forceCopy: Bool
    let checkpoint: (String) throws -> Void
    public init(store: Store, metadata: MetadataService, forceCopy: Bool = false, checkpoint: @escaping (String) throws -> Void = { _ in }) { self.store = store; self.metadata = metadata; self.forceCopy = forceCopy; self.checkpoint = checkpoint }
    public static func component(_ value: String) -> String {
        let clean = value.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "." || clean == ".." ? "未知地点" : String(clean.prefix(80))
    }
    public func archivePlan(photos: [Photo], root: URL, cancellation: CancellationFlag, progress: @Sendable (Int, Int, String) -> Void = { _, _, _ in }) throws -> OperationBatch {
        var batch = OperationBatch(kind: "archive", items: [])
        var occupiedByDirectory: [String: Set<String>] = [:]
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        var lastReport = Date.distantPast
        progress(0, photos.count, "正在检查文件与目标目录")
        for photo in photos {
            if cancellation.isCancelled { break }
            var item = OperationItem(photo: photo, files: [])
            do {
                if let problem = photo.problem { throw PhotoError.message(problem) }
                let dateParts = photo.capture?.value.split(separator: " ").first?.split(separator: ":")
                var dir = root.appendingPathComponent(photo.year)
                if let dateParts, dateParts.count >= 2 { dir.appendPathComponent(String(dateParts[1])) }
                dir.appendPathComponent(Self.component(photo.place ?? "未知地点"))
                let source = URL(fileURLWithPath: photo.path)
                if source.deletingLastPathComponent().resolvingSymlinksInPath() == dir.resolvingSymlinksInPath() {
                    item.status = "skipped"; item.error = "已在归档目录"
                } else {
                    if occupiedByDirectory[dir.path] == nil {
                        let names = fm.fileExists(atPath: dir.path) ? try fm.contentsOfDirectory(atPath: dir.path) : []
                        occupiedByDirectory[dir.path] = Set(names.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() })
                        try checkpoint("archiveDirectoryListed")
                    }
                    let base = source.deletingPathExtension().lastPathComponent
                    var number = 0, stem = base
                    while occupiedByDirectory[dir.path]!.contains(stem.lowercased()) {
                        if cancellation.isCancelled { throw CancellationError() }
                        number += 1; stem = base + "_\(number)"
                    }
                    for src in photo.allPaths {
                        if cancellation.isCancelled { throw CancellationError() }
                        let dst = dir.appendingPathComponent(stem).appendingPathExtension(URL(fileURLWithPath: src).pathExtension).path
                        var file = FileStep(source: src, destination: dst, before: nil)
                        file.previewSnapshot = try FileSnapshot.read(src)
                        file.transfer = ArchiveTransfer(source: src, destination: dst, original: file.previewSnapshot!)
                        item.files.append(file)
                    }
                    occupiedByDirectory[dir.path]!.insert(stem.lowercased())
                }
            } catch is CancellationError { break }
            catch { item.status = "blocked"; item.error = error.localizedDescription }
            batch.items.append(item)
            if Date().timeIntervalSince(lastReport) >= 0.1 || batch.items.count == photos.count {
                progress(batch.items.count, photos.count, photo.name); lastReport = Date()
            }
        }
        if cancellation.isCancelled { batch.status = "cancelled" }
        return batch
    }
    func check(_ path: String, equals fingerprint: Fingerprint?) throws {
        if let fingerprint {
            guard (try fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular else { throw PhotoError.message("文件类型变化，拒绝操作：\(path)") }
            guard fm.fileExists(atPath: path), try Fingerprint.read(path) == fingerprint else { throw PhotoError.message("文件已变化或不可访问：\(URL(fileURLWithPath: path).lastPathComponent)") } }
        else if fm.fileExists(atPath: path) { throw PhotoError.message("目标已存在，未覆盖：\(path)") }
    }
    private func syncFile(_ path: String) throws { let h = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? h.close() }; try h.synchronize() }
    func persist(_ batch: OperationBatch, item: Int? = nil) throws { try store.save(batch, changedItem: item) }
    public func execute(_ input: OperationBatch, backupRoot: URL, cancellation: CancellationFlag, activity: @Sendable (Int, Int, String) -> Void = { _, _, _ in }, progress: @Sendable (OperationBatch) -> Void) throws -> OperationBatch {
        var batch = input
        guard batch.status != "undone" && batch.status != "undoing" && batch.status != "undoFailed" else { throw PhotoError.message("该批次正在撤销，只能继续撤销") }
        batch.status = "running"; try persist(batch)
        for i in batch.items.indices {
            if cancellation.isCancelled { break }
            guard ["pending", "failed", "running"].contains(batch.items[i].status) else { continue }
            do {
                batch.items[i].status = "running"; batch.items[i].error = nil; try persist(batch, item: i)
                if batch.kind == "archive", batch.items[i].files.allSatisfy({ $0.transfer != nil }) {
                    try executeArchive(&batch, i: i, cancellation: cancellation, activity: activity)
                } else if batch.kind == "time", batch.items[i].files.allSatisfy({ $0.timeEdit != nil }) {
                    try executeTime(&batch, i: i, backupRoot: backupRoot, cancellation: cancellation, activity: activity)
                } else {
                    if batch.kind == "archive" {
                        // Capture all hashes before the first mutation; cancelling here leaves the group untouched.
                        var prepared = batch.items[i].files
                        for j in prepared.indices where prepared[j].before == nil {
                            let file = prepared[j]
                            guard file.state == "pending", let snapshot = file.previewSnapshot,
                                  try FileSnapshot.read(file.source) == snapshot else { throw PhotoError.message("预览后文件已变化，请重新生成预览：" + file.source) }
                            var lastReport = Date.distantPast
                            prepared[j].before = try Fingerprint.read(file.source, cancellation: cancellation) { bytes in
                                if Date().timeIntervalSince(lastReport) >= 0.2 {
                                    let amount = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                                    let total = ByteCountFormatter.string(fromByteCount: snapshot.size, countStyle: .file)
                                    activity(i, batch.items.count, "正在校验 " + URL(fileURLWithPath: file.source).lastPathComponent + " · " + amount + " / " + total)
                                    lastReport = Date()
                                }
                            }
                            guard try FileSnapshot.read(file.source) == snapshot else { throw PhotoError.message("校验期间文件已变化：" + file.source) }
                        }
                        batch.items[i].files = prepared; try persist(batch, item: i)
                        activity(i, batch.items.count, "正在移动 " + batch.items[i].photo.name)
                    }
                    // Check the entire group before the first mutation.
                    for f in batch.items[i].files where f.state == "pending" || f.state == "readonly" { try check(f.source, equals: f.before) }
                    for f in batch.items[i].files where f.state == "done" {
                        try check(batch.kind == "archive" ? f.destination : f.source, equals: batch.kind == "archive" ? f.before : f.after)
                    }
                    if batch.kind == "archive" {
                        for f in batch.items[i].files where f.state == "pending" { try check(f.destination, equals: nil) }
                    }
                    if batch.kind == "time" {
                        // All backups must exist and match before any write in this group.
                        for j in batch.items[i].files.indices where batch.items[i].files[j].state != "readonly" {
                            var f = batch.items[i].files[j]
                            if let before = f.before, f.backup == nil {
                                try check(f.source, equals: before)
                                let dir = backupRoot.appendingPathComponent(batch.id).appendingPathComponent(batch.items[i].id)
                                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                                let target = dir.appendingPathComponent("\(j)-" + URL(fileURLWithPath: f.source).lastPathComponent)
                                if fm.fileExists(atPath: target.path) { try check(target.path, equals: before) }
                                else { try fm.copyItem(atPath: f.source, toPath: target.path); try syncFile(target.path); try check(target.path, equals: before) }
                                f.backup = target.path; batch.items[i].files[j] = f; try persist(batch, item: i)
                            }
                            if let before = f.before, let backup = f.backup { try check(backup, equals: before) }
                        }
                    }
                    for j in batch.items[i].files.indices {
                        if batch.items[i].files[j].state == "readonly" { continue }
                        if batch.kind == "archive" { try moveStep(&batch, i: i, j: j) } else { try editStep(&batch, i: i, j: j); try checkpoint("afterTimeMember") }
                    }
                }
                var photo = batch.items[i].photo
                if batch.kind == "archive" {
                    let destinations = Dictionary(uniqueKeysWithValues: batch.items[i].files.map { ($0.source, $0.destination) })
                    photo.members = photo.files.map { member in var updated = member; updated.path = destinations[member.path] ?? member.path; return updated }
                    photo.path = destinations[photo.path] ?? photo.path
                    photo.sidecar = photo.sidecar.map { destinations[$0] ?? $0 }
                } else {
                    photo.capture = batch.items[i].newCapture
                    photo.members = photo.files.map { member in var updated = member; if !member.isRAW { updated.capture = photo.capture }; return updated }
                    if photo.hasRAW { photo.sidecar = batch.items[i].files.first { URL(fileURLWithPath: $0.destination).pathExtension.lowercased() == "xmp" }?.destination }
                }
                if let latest = try store.photo(id: photo.id) { photo.place = latest.place; photo.manualPlace = latest.manualPlace }
                try saveResult(photo, item: batch.items[i], kind: batch.kind)
                batch.items[i].status = "done"; try persist(batch, item: i)
            } catch is CancellationError { batch.items[i].status = "pending"; try persist(batch, item: i); break }
            catch { batch.items[i].status = "failed"; batch.items[i].error = error.localizedDescription; try persist(batch, item: i) }
            progress(batch)
        }
        batch.status = cancellation.isCancelled ? "cancelled" : batch.items.contains { $0.status == "failed" } ? "partial" : "completed"
        try persist(batch); progress(batch); return batch
    }
    private func saveResult(_ photo: Photo, item: OperationItem, kind: String) throws {
        // A modern archive only changes paths. Avoid decoding the entire library and
        // launching ExifTool for every photo; legacy histories still reconcile bindings.
        if kind == "archive", item.photo.members != nil, let current = try store.photo(id: photo.id) {
            let sources = Set(item.photo.allPaths)
            let destinations = Set(item.files.map(\.destination))
            let indexed = Set(current.allPaths)
            if indexed == sources || indexed == destinations { try store.save(photo); return }
        }
        if kind == "time", try saveTimeResult(photo, item: item) { return }
        try Scanner(metadata: metadata, store: store).reconcile(paths: item.files.flatMap { [$0.source, $0.destination] }, preferred: photo)
    }
    private func moveStep(_ batch: inout OperationBatch, i: Int, j: Int) throws {
        var f = batch.items[i].files[j]
        if f.state == "done" { try check(f.destination, equals: f.before); return }
        let srcExists = fm.fileExists(atPath: f.source), dstExists = fm.fileExists(atPath: f.destination)
        if dstExists && ["committing", "destinationCommitted"].contains(f.state) {
            try check(f.destination, equals: f.before)
            if srcExists { try check(f.source, equals: f.before); try fm.removeItem(atPath: f.source) }
            f.after = f.before; f.state = "done"; batch.items[i].files[j] = f; try persist(batch, item: i); return
        }
        try check(f.source, equals: f.before); try check(f.destination, equals: nil)
        let dest = URL(fileURLWithPath: f.destination), dir = dest.deletingLastPathComponent()
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let sourceDevice = try fm.attributesOfItem(atPath: f.source)[.systemNumber] as? NSNumber
        let destDevice = try fm.attributesOfItem(atPath: dir.path)[.systemNumber] as? NSNumber
        if !forceCopy && sourceDevice == destDevice {
            f.state = "committing"; batch.items[i].files[j] = f; try persist(batch, item: i)
            try fm.moveItem(atPath: f.source, toPath: f.destination)
        } else {
            let staging = f.staged ?? dir.appendingPathComponent(".photoarchive-\(batch.id)-\(batch.items[i].id)-\(j).\(dest.pathExtension)").path
            f.staged = staging; f.state = "staging"; batch.items[i].files[j] = f; try persist(batch, item: i)
            if fm.fileExists(atPath: staging) { if (try? Fingerprint.read(staging)) != f.before { try fm.removeItem(atPath: staging) } }
            if !fm.fileExists(atPath: staging) { try fm.copyItem(atPath: f.source, toPath: staging) }
            try syncFile(staging); try check(staging, equals: f.before); try check(f.source, equals: f.before); try check(f.destination, equals: nil)
            f.state = "committing"; batch.items[i].files[j] = f; try persist(batch, item: i)
            try fm.moveItem(atPath: staging, toPath: f.destination)
            f.state = "destinationCommitted"; batch.items[i].files[j] = f; try persist(batch, item: i)
            try checkpoint("beforeSourceDelete"); try check(f.source, equals: f.before); try fm.removeItem(atPath: f.source)
        }
        f.after = f.before; f.state = "done"; batch.items[i].files[j] = f; try persist(batch, item: i)
    }
    private func editStep(_ batch: inout OperationBatch, i: Int, j: Int) throws {
        var f = batch.items[i].files[j]
        if f.state == "done" { try check(f.source, equals: f.after); return }
        if f.state == "committing", let after = f.after, (try? Fingerprint.read(f.source)) == after {
            f.state = "done"; batch.items[i].files[j] = f; try persist(batch, item: i); return
        }
        try check(f.source, equals: f.before)
        guard let capture = batch.items[i].newCapture else { throw PhotoError.message("缺少目标时间") }
        let url = URL(fileURLWithPath: f.source)
        let staging = f.staged ?? url.deletingLastPathComponent().appendingPathComponent(".photoarchive-\(batch.id)-\(batch.items[i].id)-\(j).\(url.pathExtension)").path
        f.staged = staging; f.state = "staging"; batch.items[i].files[j] = f; try persist(batch, item: i)
        if fm.fileExists(atPath: staging) { try fm.removeItem(atPath: staging) }
        if f.before != nil { try fm.copyItem(atPath: f.source, toPath: staging) }
        try metadata.write(capture, to: staging, xmpOnly: url.pathExtension.lowercased() == "xmp")
        try syncFile(staging); f.after = try Fingerprint.read(staging)
        f.state = "committing"; batch.items[i].files[j] = f; try persist(batch, item: i)
        try check(f.source, equals: f.before)
        if f.before == nil { try fm.moveItem(atPath: staging, toPath: f.source) }
        else { guard rename(staging, f.source) == 0 else { throw PhotoError.message("无法提交元数据修改：\(String(cString: strerror(errno)))") } }
        f.state = "done"; batch.items[i].files[j] = f; try persist(batch, item: i)
    }
    public func recoverInterrupted() throws -> Int {
        var count = 0
        for var batch in try store.batches() where batch.status == "running" || batch.status == "undoing" {
            batch.status = batch.status == "undoing" ? "undoFailed" : "interrupted"
            try persist(batch); count += 1
        }
        return count
    }
    public func undo(_ input: OperationBatch, cancellation: CancellationFlag, activity: @Sendable (Int, Int, String) -> Void = { _, _, _ in }, progress: @Sendable (OperationBatch) -> Void) throws -> OperationBatch {
        var batch = input; batch.status = "undoing"; try persist(batch)
        for i in batch.items.indices.reversed() {
            if cancellation.isCancelled { break }
            if ["undone", "skipped", "blocked"].contains(batch.items[i].status) { continue }
            if batch.items[i].status == "pending", !batch.items[i].files.allSatisfy({ $0.transfer != nil || $0.timeEdit != nil }) { continue }
            do {
                if batch.kind == "archive", batch.items[i].files.allSatisfy({ $0.transfer != nil }) {
                    try undoArchive(&batch, i: i, cancellation: cancellation, activity: activity)
                } else if batch.kind == "time", batch.items[i].files.allSatisfy({ $0.timeEdit != nil }) {
                    try undoTime(&batch, i: i, cancellation: cancellation, activity: activity)
                } else {
                    if batch.kind == "archive", !batch.items[i].files.isEmpty,
                       batch.items[i].files.allSatisfy({ $0.state == "pending" && $0.before == nil && $0.previewSnapshot != nil }) {
                        // A cancelled/failed deferred preflight never touched these files.
                        batch.items[i].status = "undone"; batch.items[i].error = nil
                        try persist(batch, item: i); progress(batch); continue
                    }
                    // Preflight all members: never overwrite changes made by another app.
                    for f in batch.items[i].files where f.state == "readonly" { try check(f.source, equals: f.before) }
                    for f in batch.items[i].files where f.state != "readonly" && f.state != "undone" {
                        if batch.kind == "archive" {
                            if fm.fileExists(atPath: f.destination) { try check(f.destination, equals: f.before); try check(f.source, equals: ["undoing", "destinationCommitted", "committing"].contains(f.state) && fm.fileExists(atPath: f.source) ? f.before : nil) }
                            else { try check(f.source, equals: f.before) }
                        } else {
                            let current = fm.fileExists(atPath: f.source) ? try Fingerprint.read(f.source) : nil
                            guard current == f.after || current == f.before else { throw PhotoError.message("文件被外部修改，无法安全撤销：\(f.source)") }
                            if f.before != nil, current != f.before { guard let backup = f.backup else { throw PhotoError.message("原片备份缺失") }; try check(backup, equals: f.before) }
                        }
                    }
                    for j in batch.items[i].files.indices.reversed() {
                        var f = batch.items[i].files[j]
                        if f.state == "readonly" || f.state == "undone" { continue }
                        f.state = "undoing"; batch.items[i].files[j] = f; try persist(batch, item: i)
                        if batch.kind == "archive" {
                            if fm.fileExists(atPath: f.destination) {
                                if fm.fileExists(atPath: f.source) {
                                    try check(f.source, equals: f.before); try check(f.destination, equals: f.before)
                                    try fm.removeItem(atPath: f.destination)
                                    f.state = "undone"; batch.items[i].files[j] = f; try persist(batch, item: i); continue
                                }
                                try fm.createDirectory(at: URL(fileURLWithPath: f.source).deletingLastPathComponent(), withIntermediateDirectories: true)
                                // copy/verify/delete is restartable across volumes and never overwrites.
                                let temp = f.source + ".photoarchive-undo-" + batch.id
                                if fm.fileExists(atPath: temp), (try? Fingerprint.read(temp)) != f.before { try fm.removeItem(atPath: temp) }
                                if !fm.fileExists(atPath: temp) { try fm.copyItem(atPath: f.destination, toPath: temp) }
                                try syncFile(temp); try check(temp, equals: f.before); try check(f.destination, equals: f.before); try check(f.source, equals: nil)
                                try fm.moveItem(atPath: temp, toPath: f.source); try fm.removeItem(atPath: f.destination)
                            }
                        } else if (fm.fileExists(atPath: f.source) ? try Fingerprint.read(f.source) : nil) != f.before {
                            if let backup = f.backup, f.before != nil {
                                let temp = f.source + ".photoarchive-undo-" + batch.id
                                if fm.fileExists(atPath: temp) { try fm.removeItem(atPath: temp) }
                                try fm.copyItem(atPath: backup, toPath: temp); try syncFile(temp); try check(temp, equals: f.before)
                                try check(f.source, equals: f.after)
                                guard rename(temp, f.source) == 0 else { throw PhotoError.message("恢复备份失败") }
                            } else { try check(f.source, equals: f.after); try fm.removeItem(atPath: f.source) }
                        }
                        if let temp = f.staged, fm.fileExists(atPath: temp) { try fm.removeItem(atPath: temp) }
                        f.state = "undone"; batch.items[i].files[j] = f; try persist(batch, item: i)
                    }
                }
                var restored = batch.items[i].photo
                if let latest = try store.photo(id: restored.id) { restored.place = latest.place; restored.manualPlace = latest.manualPlace }
                try saveResult(restored, item: batch.items[i], kind: batch.kind); batch.items[i].status = "undone"; batch.items[i].error = nil; try persist(batch, item: i)
            } catch { batch.items[i].status = "undoFailed"; batch.items[i].error = error.localizedDescription; try persist(batch, item: i) }
            progress(batch)
        }
        batch.status = batch.items.contains { ["done", "failed", "running", "undoFailed"].contains($0.status) } ? "undoFailed" : "undone"
        try persist(batch); progress(batch); return batch
    }
}
