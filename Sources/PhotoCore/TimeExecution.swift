import Foundation
import Darwin
import CryptoKit

extension OperationService {
    func timeVacant(_ path: String) throws {
        var info = stat()
        guard lstat(path, &info) != 0 && errno == ENOENT else { throw PhotoError.message("目标已存在或不可访问，未覆盖：" + path) }
    }
    func timeUnchanged(_ path: String, _ snapshot: FileSnapshot) throws {
        guard try FileSnapshot.read(path) == snapshot else { throw PhotoError.message("文件状态已变化，未继续校时：" + path) }
    }
    private func timeOriginal(_ f: FileStep) throws {
        if let snapshot = f.timeEdit?.original { try timeUnchanged(f.source, snapshot) }
        else { try timeVacant(f.source) }
    }
    private func timeSync(_ path: String, directory: Bool = false) throws {
        let fd = open(path, directory ? O_RDONLY : O_WRONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw PhotoError.message("无法同步：" + path) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw PhotoError.message("同步失败：" + String(cString: strerror(errno))) }
    }
    private func timeHash(_ path: String, cancellation: CancellationFlag, phase: String,
                          report: (String, UInt64) -> Void) throws -> Fingerprint {
        try checkpoint("timeHash:" + phase)
        return try Fingerprint.read(path, cancellation: cancellation) { report(phase, $0) }
    }
    private func timeVerify(_ path: String, _ expected: Fingerprint, cancellation: CancellationFlag,
                            phase: String, report: (String, UInt64) -> Void) throws {
        guard try timeHash(path, cancellation: cancellation, phase: phase, report: report) == expected else {
            throw PhotoError.message("内容校验失败，原片和备份均未主动删除：" + path)
        }
    }
    private func timeCopy(_ source: String, to destination: String, expected: FileSnapshot,
                          cancellation: CancellationFlag, phase: String,
                          created: (FileSnapshot) throws -> Void = { _ in },
                          report: (String, UInt64) -> Void) throws -> Fingerprint {
        try timeUnchanged(source, expected)
        let sourceFD = open(source, O_RDONLY | O_NOFOLLOW)
        guard sourceFD >= 0 else { throw PhotoError.message("无法读取：" + source) }
        let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true); defer { try? input.close() }
        guard try FileSnapshot.read(descriptor: sourceFD) == expected else { throw PhotoError.message("源文件已被替换") }
        let targetFD = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard targetFD >= 0 else { throw PhotoError.message("无法创建副本：" + String(cString: strerror(errno))) }
        let output = FileHandle(fileDescriptor: targetFD, closeOnDealloc: true); defer { try? output.close() }
        try created(FileSnapshot.read(destination))
        var hash = SHA256(), bytes: UInt64 = 0
        try checkpoint("timeCopy:" + phase)
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            try checkpoint("timeCopyChunk:" + phase)
            try output.write(contentsOf: data); hash.update(data: data); bytes += UInt64(data.count); report(phase, bytes)
        }
        try timeUnchanged(source, expected)
        guard try FileSnapshot.read(descriptor: sourceFD) == expected, bytes == UInt64(expected.size) else {
            throw PhotoError.message("复制期间文件发生变化")
        }
        guard fcopyfile(sourceFD, targetFD, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw PhotoError.message("无法保留文件元数据：" + String(cString: strerror(errno)))
        }
        try output.synchronize()
        if cancellation.isCancelled { throw CancellationError() }
        return Fingerprint(size: bytes, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private func checkWorkspace(_ workspace: TimeWorkspace) throws {
        var info = stat()
        guard lstat(workspace.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_dev == workspace.device, info.st_ino == workspace.inode else {
            throw PhotoError.message("临时工作目录身份变化，已保留：" + workspace.path)
        }
    }
    private func cleanupTimeWorkspace(_ f: FileStep) throws {
        guard let area = f.timeEdit?.workspace else { return }
        var info = stat()
        if lstat(area.path, &info) != 0 && errno == ENOENT { return }
        try checkWorkspace(area)
        try fm.removeItem(atPath: area.path)
    }
    private func makeTimeWorkspace(_ f: inout FileStep, save: (FileStep) throws -> Void) throws {
        try cleanupTimeWorkspace(f)
        let directory = URL(fileURLWithPath: f.source).deletingLastPathComponent().appendingPathComponent(".photoarchive-time-" + UUID().uuidString)
        guard mkdir(directory.path, 0o700) == 0 else { throw PhotoError.message("无法创建校时工作目录") }
        var info = stat(); guard lstat(directory.path, &info) == 0 else { throw PhotoError.message("无法检查工作目录") }
        f.timeEdit?.workspace = TimeWorkspace(path: directory.path, device: info.st_dev, inode: info.st_ino)
        f.staged = directory.appendingPathComponent("working").appendingPathExtension(URL(fileURLWithPath: f.source).pathExtension).path
        try save(f)
    }
    private func timeBackup(_ input: FileStep, at target: String, cancellation: CancellationFlag,
                            report: (String, UInt64) -> Void, save: (FileStep) throws -> Void) throws -> FileStep {
        var f = input
        guard f.timeEdit?.role == "existing" else { return f }
        if let backup = f.backup {
            if let before = f.before, let snapshot = f.timeEdit?.backupSnapshot {
                try timeUnchanged(backup, snapshot)
                try timeVerify(backup, before, cancellation: cancellation, phase: "校验备份", report: report)
                try timeUnchanged(backup, snapshot)
                return f
            }
            // Only discard an incomplete copy created by this journal, never an unknown backup.
            if f.state == "backingUp", f.timeEdit?.backupSnapshot == nil {
                try timeVacant(backup)
            } else {
                guard f.state == "backingUp", let snapshot = f.timeEdit?.backupSnapshot,
                      let current = try? FileSnapshot.read(backup), current.device == snapshot.device, current.inode == snapshot.inode else {
                    throw PhotoError.message("备份缺少完整校验记录，已保留")
                }
                try fm.removeItem(atPath: backup)
            }
        }
        try timeOriginal(f)
        try fm.createDirectory(at: URL(fileURLWithPath: target).deletingLastPathComponent(), withIntermediateDirectories: true)
        f.backup = target; f.state = "backingUp"; f.timeEdit?.backupSnapshot = nil; try save(f)
        let hash = try timeCopy(f.source, to: target, expected: f.timeEdit!.original!, cancellation: cancellation, phase: "备份", created: { snapshot in
            f.timeEdit?.backupSnapshot = snapshot; try save(f)
        }, report: report)
        f.before = hash; f.timeEdit?.backupSnapshot = try FileSnapshot.read(target); try save(f)
        try checkpoint("timeBeforeBackupVerify")
        try timeVerify(target, hash, cancellation: cancellation, phase: "校验备份", report: report)
        try timeUnchanged(target, f.timeEdit!.backupSnapshot!); try timeOriginal(f)
        try timeSync(URL(fileURLWithPath: target).deletingLastPathComponent().path, directory: true)
        f.state = "backedUp"; try save(f); return f
    }
    // Returns true when the original has already been replaced by the verified result.
    private func timeCommitted(_ f: FileStep, cancellation: CancellationFlag,
                               report: (String, UInt64) -> Void) throws -> Bool {
        guard ["done", "committing"].contains(f.state), let after = f.after else { return false }
        if let snapshot = f.timeEdit?.result {
            try timeUnchanged(f.source, snapshot)
            try timeVerify(f.source, after, cancellation: cancellation, phase: "检查已提交文件", report: report)
            return true
        }
        if let current = try? FileSnapshot.read(f.source) {
            if current == f.timeEdit?.original { return false }
            try timeVerify(f.source, after, cancellation: cancellation, phase: "恢复提交", report: report)
            try timeUnchanged(f.source, current); return true
        }
        if f.timeEdit?.role == "new" { try timeVacant(f.source); return false }
        throw PhotoError.message("原片缺失，无法恢复校时")
    }
    // exFAT may reject RENAME_EXCL. Reserve the final path with O_EXCL instead;
    // the publication phase records ownership until the copied XMP is verified.
    private func publishNewTimeFile(_ input: FileStep, report: (String, UInt64) -> Void,
                                    save: (FileStep) throws -> Void) throws -> FileStep {
        var f = input
        do {
            try checkpoint("timeExclusiveRename")
            guard renamex_np(f.staged!, f.source, UInt32(RENAME_EXCL)) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            return f
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && [Int(ENOTSUP), Int(ENOSYS)].contains(error.code) {
            try timeVacant(f.source)
            f.state = "publishing"; f.timeEdit?.publicationSnapshot = nil; try save(f)
            let hash = try timeCopy(f.staged!, to: f.source, expected: f.timeEdit!.preparedSnapshot!, cancellation: CancellationFlag(), phase: "提交新建 XMP", created: { snapshot in
                f.timeEdit?.publicationSnapshot = snapshot; try save(f)
                try checkpoint("timePublicationCreated")
            }, report: report)
            guard hash == f.after else { throw PhotoError.message("XMP 工作副本发生变化，未确认提交") }
            let snapshot = try FileSnapshot.read(f.source)
            try timeVerify(f.source, f.after!, cancellation: CancellationFlag(), phase: "校验新建 XMP", report: report)
            try timeUnchanged(f.source, snapshot)
            try checkpoint("timePublicationVerified")
            return f
        }
    }

    private func recoverTimePublication(_ input: FileStep, cancellation: CancellationFlag,
                                        report: (String, UInt64) -> Void) throws -> FileStep {
        var f = input
        guard f.state == "publishing", f.timeEdit?.role == "new" else { return f }
        var info = stat()
        if lstat(f.source, &info) != 0 && errno == ENOENT {
            f.state = "ready"; f.timeEdit?.publicationSnapshot = nil; return f
        }
        let current = try FileSnapshot.read(f.source)
        guard let owned = f.timeEdit?.publicationSnapshot, current.device == owned.device, current.inode == owned.inode,
              let staged = f.staged, let expected = f.timeEdit?.preparedSnapshot, let after = f.after else {
            throw PhotoError.message("新建 XMP 身份无法确认，已保留，请人工检查：" + f.source)
        }
        try checkWorkspace(f.timeEdit!.workspace!)
        try timeUnchanged(staged, expected)
        try timeVerify(staged, after, cancellation: cancellation, phase: "检查待提交 XMP", report: report)
        guard current.size <= expected.size else { throw PhotoError.message("未完成的 XMP 已被外部修改，已保留") }
        // A crash may leave an empty file or a prefix of our prepared XMP. Only
        // reclaim that exact prefix; unrelated content and replaced files survive.
        let source = try FileHandle(forReadingFrom: URL(fileURLWithPath: staged))
        let partial = try FileHandle(forReadingFrom: URL(fileURLWithPath: f.source))
        defer { try? source.close(); try? partial.close() }
        var remaining = current.size
        while remaining > 0 {
            if cancellation.isCancelled { throw CancellationError() }
            let amount = Int(min(remaining, 1024 * 1024))
            let a = try source.read(upToCount: amount), b = try partial.read(upToCount: amount)
            guard let a, let b, a.count == amount, b == a else {
                throw PhotoError.message("未完成的 XMP 内容无法确认，已保留，请人工检查：" + f.source)
            }
            remaining -= Int64(amount)
        }
        try timeUnchanged(staged, expected); try timeUnchanged(f.source, current)
        if current.size == expected.size {
            f.state = "done"; f.timeEdit?.result = current
        } else {
            try fm.removeItem(atPath: f.source)
            try timeSync(URL(fileURLWithPath: f.source).deletingLastPathComponent().path, directory: true)
            f.state = "ready"; f.timeEdit?.publicationSnapshot = nil
        }
        return f
    }

    func executeTime(_ batch: inout OperationBatch, i: Int, backupRoot: URL, cancellation: CancellationFlag,
                     activity: @Sendable (Int, Int, String) -> Void) throws {
        let count = batch.items.count
        var last = Date.distantPast
        let report: (String, UInt64) -> Void = { phase, bytes in
            if Date().timeIntervalSince(last) >= 0.15 {
                activity(i, count, phase + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); last = Date()
            }
        }
        // Recover committed members before preparing any new writes, and preflight the entire group.
        for j in batch.items[i].files.indices {
            var f = batch.items[i].files[j]
            if f.state == "publishing" {
                f = try recoverTimePublication(f, cancellation: cancellation, report: report)
                batch.items[i].files[j] = f; try persist(batch, item: i)
            }
            if f.timeEdit?.role == "readonly" { try timeOriginal(f); continue }
            if try timeCommitted(f, cancellation: cancellation, report: report) {
                f.state = "done"; f.timeEdit?.result = try FileSnapshot.read(f.source)
                try timeSync(URL(fileURLWithPath: f.source).deletingLastPathComponent().path, directory: true)
                batch.items[i].files[j] = f; try persist(batch, item: i)
                try cleanupTimeWorkspace(f)
            } else { try timeOriginal(f) }
        }
        // Verify every existing backup, including backups of members committed on an earlier run.
        for j in batch.items[i].files.indices {
            let f = batch.items[i].files[j]
            if f.timeEdit?.role == "readonly" { continue }
            let target = backupRoot.appendingPathComponent(batch.id).appendingPathComponent(batch.items[i].id).appendingPathComponent("\(j)-" + URL(fileURLWithPath: f.source).lastPathComponent).path
            activity(i, count, "准备备份 · " + URL(fileURLWithPath: f.source).lastPathComponent)
            _ = try timeBackup(f, at: target, cancellation: cancellation, report: report) { updated in
                batch.items[i].files[j] = updated; try persist(batch, item: i)
            }
        }
        guard let capture = batch.items[i].newCapture else { throw PhotoError.message("缺少目标时间") }
        for j in batch.items[i].files.indices {
            var f = batch.items[i].files[j]
            if f.state == "done" || f.timeEdit?.role == "readonly" { continue }
            if cancellation.isCancelled { throw CancellationError() }
            try timeOriginal(f)
            // Recreate incomplete scratch work from a verified backup. No source content reread.
            f.state = "preparing"
            try makeTimeWorkspace(&f) { updated in batch.items[i].files[j] = updated; try persist(batch, item: i) }
            if let backup = f.backup, let before = f.before {
                let copied = try timeCopy(backup, to: f.staged!, expected: f.timeEdit!.backupSnapshot!, cancellation: cancellation, phase: "准备工作副本", report: report)
                guard copied == before else { throw PhotoError.message("备份在读取时发生变化") }
                try timeVerify(f.staged!, before, cancellation: cancellation, phase: "校验工作副本", report: report)
            }
            activity(i, count, "写入临时副本 · " + URL(fileURLWithPath: f.source).lastPathComponent)
            try checkpoint("timeBeforeMetadataWrite")
            try metadata.write(capture, to: f.staged!, xmpOnly: URL(fileURLWithPath: f.source).pathExtension.lowercased() == "xmp", cancellation: cancellation)
            try timeSync(f.staged!)
            f.timeEdit?.preparedSnapshot = try FileSnapshot.read(f.staged!)
            f.after = try timeHash(f.staged!, cancellation: cancellation, phase: "校验修改结果", report: report)
            try timeUnchanged(f.staged!, f.timeEdit!.preparedSnapshot!)
            f.state = "ready"; batch.items[i].files[j] = f; try persist(batch, item: i)
        }
        activity(i, count, "正在提交校时结果")
        if cancellation.isCancelled { throw CancellationError() }
        for f in batch.items[i].files where f.state != "done" { try timeOriginal(f) }
        for j in batch.items[i].files.indices {
            var f = batch.items[i].files[j]
            if f.state == "done" || f.timeEdit?.role == "readonly" { continue }
            try checkWorkspace(f.timeEdit!.workspace!)
            f.state = "committing"; batch.items[i].files[j] = f; try persist(batch, item: i)
            try checkpoint("timeBeforeCommit"); try timeOriginal(f)
            try timeUnchanged(f.staged!, f.timeEdit!.preparedSnapshot!)
            if f.timeEdit?.role == "new" {
                f = try publishNewTimeFile(f, report: report) { updated in
                    batch.items[i].files[j] = updated; try persist(batch, item: i)
                }
            } else {
                guard rename(f.staged!, f.source) == 0 else { throw PhotoError.message("提交校时失败：" + String(cString: strerror(errno))) }
            }
            try checkpoint("timeAfterRename")
            try timeSync(URL(fileURLWithPath: f.source).deletingLastPathComponent().path, directory: true)
            f.timeEdit?.result = try FileSnapshot.read(f.source); f.state = "done"
            batch.items[i].files[j] = f; try persist(batch, item: i)
            try cleanupTimeWorkspace(f)
            try checkpoint("afterTimeMember")
        }
        for f in batch.items[i].files where f.timeEdit?.role == "readonly" { try timeOriginal(f) }
    }

    func undoTime(_ batch: inout OperationBatch, i: Int, cancellation: CancellationFlag,
                  activity: @Sendable (Int, Int, String) -> Void) throws {
        let count = batch.items.count, done = count - i - 1
        var last = Date.distantPast
        let report: (String, UInt64) -> Void = { phase, bytes in
            if Date().timeIntervalSince(last) >= 0.15 {
                activity(done, count, phase + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)); last = Date()
            }
        }
        var restore = Set<Int>(), currentSnapshots: [Int: FileSnapshot] = [:]
        // Validate every changed member and backup before restoring any member.
        for j in batch.items[i].files.indices {
            var f = batch.items[i].files[j]
            if f.state == "publishing" {
                f = try recoverTimePublication(f, cancellation: cancellation, report: report)
                batch.items[i].files[j] = f; try persist(batch, item: i)
            }
            if f.timeEdit?.role == "readonly" { try timeOriginal(f); continue }
            if f.state == "undone" { continue }
            if ["undoCommitting", "undoDeleting"].contains(f.state) {
                if f.timeEdit?.role == "new", !fm.fileExists(atPath: f.source) {
                    try timeVacant(f.source); f.state = "undone"
                } else if let before = f.before, (try timeHash(f.source, cancellation: cancellation, phase: "检查撤销结果", report: report)) == before {
                    f.state = "undone"
                }
                if f.state == "undone" {
                    try cleanupTimeWorkspace(f); batch.items[i].files[j] = f; try persist(batch, item: i); continue
                }
            }
            let possiblyChanged = ["done", "committing", "undoPreparing", "undoCommitting", "undoDeleting"].contains(f.state)
            if !possiblyChanged { try timeOriginal(f); continue }
            if f.state == "committing", let original = f.timeEdit?.original, (try? FileSnapshot.read(f.source)) == original { continue }
            if f.state == "committing", f.timeEdit?.role == "new", !fm.fileExists(atPath: f.source) { try timeVacant(f.source); continue }
            guard let after = f.after else { throw PhotoError.message("缺少写入结果校验记录") }
            let snapshot = try FileSnapshot.read(f.source)
            if let recorded = f.timeEdit?.result { try timeUnchanged(f.source, recorded) }
            try timeVerify(f.source, after, cancellation: cancellation, phase: "检查当前文件", report: report)
            try timeUnchanged(f.source, snapshot); currentSnapshots[j] = snapshot
            if f.timeEdit?.role == "existing" {
                guard let backup = f.backup, let before = f.before, let expected = f.timeEdit?.backupSnapshot else {
                    throw PhotoError.message("完整备份缺失，无法撤销")
                }
                try timeUnchanged(backup, expected)
                try timeVerify(backup, before, cancellation: cancellation, phase: "校验恢复备份", report: report)
                try timeUnchanged(backup, expected)
            }
            restore.insert(j)
        }
        for j in batch.items[i].files.indices {
            var f = batch.items[i].files[j]
            if f.timeEdit?.role == "readonly" || f.state == "undone" { continue }
            if !restore.contains(j) {
                try cleanupTimeWorkspace(f); f.state = "undone"
                batch.items[i].files[j] = f; try persist(batch, item: i); continue
            }
            f.state = "undoPreparing"
            try makeTimeWorkspace(&f) { updated in batch.items[i].files[j] = updated; try persist(batch, item: i) }
            if f.timeEdit?.role == "existing" {
                let copied = try timeCopy(f.backup!, to: f.staged!, expected: f.timeEdit!.backupSnapshot!, cancellation: cancellation, phase: "准备恢复副本", report: report)
                guard copied == f.before else { throw PhotoError.message("恢复备份内容变化") }
                let snapshot = try FileSnapshot.read(f.staged!)
                try timeVerify(f.staged!, f.before!, cancellation: cancellation, phase: "校验恢复副本", report: report)
                try timeUnchanged(f.staged!, snapshot)
                f.timeEdit?.preparedSnapshot = snapshot
                batch.items[i].files[j] = f; try persist(batch, item: i)
            }
        }
        if cancellation.isCancelled { throw CancellationError() }
        for (j, snapshot) in currentSnapshots { try timeUnchanged(batch.items[i].files[j].source, snapshot) }
        for f in batch.items[i].files where f.timeEdit?.role == "readonly" { try timeOriginal(f) }
        for j in batch.items[i].files.indices.reversed() where restore.contains(j) {
            var f = batch.items[i].files[j]
            f.state = f.timeEdit?.role == "new" ? "undoDeleting" : "undoCommitting"
            batch.items[i].files[j] = f; try persist(batch, item: i)
            try checkpoint("timeBeforeUndoCommit"); try timeUnchanged(f.source, currentSnapshots[j]!)
            if f.timeEdit?.role == "new" { try fm.removeItem(atPath: f.source) }
            else {
                try checkWorkspace(f.timeEdit!.workspace!)
                try timeUnchanged(f.staged!, f.timeEdit!.preparedSnapshot!)
                guard rename(f.staged!, f.source) == 0 else { throw PhotoError.message("提交恢复副本失败") }
            }
            try checkpoint("timeAfterUndoRename")
            try timeSync(URL(fileURLWithPath: f.source).deletingLastPathComponent().path, directory: true)
            f.state = "undone"; batch.items[i].files[j] = f; try persist(batch, item: i)
            try cleanupTimeWorkspace(f)
        }
    }

    func saveTimeResult(_ input: Photo, item: OperationItem) throws -> Bool {
        guard input.members != nil, !item.files.isEmpty, item.files.allSatisfy({ $0.timeEdit != nil }),
              let current = try store.photo(id: input.id), Set(current.files.map(\.path)) == Set(item.photo.files.map(\.path)),
              Set(current.allPaths).isSubset(of: Set(item.files.map(\.source))) else { return false }
        var photo = input
        photo.members = try photo.files.map { member in
            var member = member; member.bytes = try FileSnapshot.read(member.path).size; return member
        }
        photo.bytes = photo.files.reduce(0) { $0 + $1.bytes }
        if let sidecar = photo.sidecar {
            photo.sidecarBytes = try FileSnapshot.read(sidecar).size
            let restoring = item.files.filter { $0.timeEdit?.role != "readonly" }.allSatisfy { $0.state == "undone" }
            photo.sidecarCapture = restoring ? item.photo.sidecarCapture : item.newCapture
        } else { photo.sidecarBytes = nil; photo.sidecarCapture = nil }
        photo.capture = photo.sidecarCapture ?? photo.files.compactMap(\.capture).first
        photo.captureSource = photo.sidecarCapture != nil ? "XMP" : photo.files.first { $0.capture != nil }?.format.uppercased()
        try checkpoint("timeIndexFastPath")
        try store.save(photo); return true
    }
}
