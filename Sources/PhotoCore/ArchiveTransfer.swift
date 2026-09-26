import Foundation
import Darwin
import CryptoKit

extension OperationService {
    private func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
    private func unchanged(_ path: String, _ expected: FileSnapshot) throws {
        guard try FileSnapshot.read(path) == expected else {
            throw PhotoError.message("文件已变化，未继续操作：" + path)
        }
    }
    private func sameIdentity(_ a: FileSnapshot, _ b: FileSnapshot) -> Bool {
        a.device == b.device && a.inode == b.inode
    }
    // Used only for the crash window between exclusive rename and journal update.
    private func renamed(_ path: String, _ expected: FileSnapshot) throws -> FileSnapshot {
        let actual = try FileSnapshot.read(path)
        guard sameIdentity(actual, expected), actual.size == expected.size,
              actual.modifiedSeconds == expected.modifiedSeconds,
              actual.modifiedNanoseconds == expected.modifiedNanoseconds else {
            throw PhotoError.message("无法确认中断后的文件身份，请人工检查：" + path)
        }
        return actual
    }
    private func vacant(_ path: String) throws {
        guard !exists(path) else { throw PhotoError.message("目标已存在，未覆盖：" + path) }
    }
    private func syncDirectory(containing path: String) throws {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let fd = open(directory, O_RDONLY)
        guard fd >= 0 else { throw PhotoError.message("无法打开目录进行同步：" + directory) }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw PhotoError.message("无法同步目录：" + directory) }
    }
    private func exclusiveRename(_ source: String, _ destination: String) throws {
        guard renamex_np(source, destination, UInt32(RENAME_EXCL)) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "移动失败：" + String(cString: strerror(errno))])
        }
    }
    private func device(_ directory: String) throws -> Int32 {
        var info = stat()
        guard stat(directory, &info) == 0 else { throw PhotoError.message("无法读取目标目录：" + directory) }
        return info.st_dev
    }
    private func verify(_ path: String, _ fingerprint: Fingerprint, cancellation: CancellationFlag,
                        report: (UInt64) -> Void = { _ in }) throws {
        try checkpoint("archiveVerifyRead")
        guard try Fingerprint.read(path, cancellation: cancellation, progress: report) == fingerprint else {
            throw PhotoError.message("复制内容校验失败，源文件保留：" + path)
        }
    }
    private func checkTransfer(_ t: ArchiveTransfer, cancellation: CancellationFlag) throws {
        if ["committing", "destinationCommitted", "done"].contains(t.phase), exists(t.destination) {
            if let result = t.result { try unchanged(t.destination, result) }
            else {
                guard let expected = t.strategy == "rename" ? t.original : t.stagedSnapshot else {
                    throw PhotoError.message("缺少恢复凭据，请人工检查：" + t.destination)
                }
                _ = try renamed(t.destination, expected)
            }
            if t.strategy == "copy", let hash = t.fingerprint {
                try verify(t.destination, hash, cancellation: cancellation)
            }
            if exists(t.source) {
                guard t.strategy == "copy", t.phase != "done" else {
                    throw PhotoError.message("源路径已被占用：" + t.source)
                }
                try unchanged(t.source, t.original)
            }
        } else {
            guard t.phase != "done" && t.phase != "destinationCommitted" else {
                throw PhotoError.message("归档目标缺失：" + t.destination)
            }
            try unchanged(t.source, t.original)
            try vacant(t.destination)
        }
    }
    private func discardStaging(_ t: ArchiveTransfer) throws {
        guard let path = t.staged, exists(path) else { return }
        guard let expected = t.stagedSnapshot, sameIdentity(try FileSnapshot.read(path), expected) else {
            throw PhotoError.message("临时文件身份不明，已保留：" + path)
        }
        try fm.removeItem(atPath: path)
    }
    private func prepareTransfer(_ input: ArchiveTransfer, cancellation: CancellationFlag,
                                 report: (String, UInt64) -> Void,
                                 save: (ArchiveTransfer) throws -> Void) throws -> ArchiveTransfer {
        var t = input
        if ["done", "destinationCommitted", "committing"].contains(t.phase), exists(t.destination) { return t }
        if cancellation.isCancelled { throw CancellationError() }
        try unchanged(t.source, t.original); try vacant(t.destination)
        let directory = URL(fileURLWithPath: t.destination).deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if t.strategy == "automatic" {
            let targetDevice = try device(directory.path)
            t.strategy = !forceCopy && targetDevice == t.original.device ? "rename" : "copy"
            try save(t)
        }
        if t.strategy == "rename" { return t }
        if t.phase == "ready" || t.phase == "committing", let path = t.staged,
           let expected = t.stagedSnapshot, let hash = t.fingerprint, exists(path) {
            try unchanged(path, expected)
            // A new invocation cannot inherit the previous process's verification.
            try verify(t.source, hash, cancellation: cancellation)
            try verify(path, hash, cancellation: cancellation)
            try unchanged(t.source, t.original)
            t.phase = "ready"; try save(t); return t
        }
        try discardStaging(t)
        t.staged = directory.appendingPathComponent(".photoarchive-" + UUID().uuidString).path
        t.stagedSnapshot = nil; t.phase = "staging"; t.fingerprint = nil; try save(t)
        let path = t.staged!
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw PhotoError.message("无法创建临时文件：" + String(cString: strerror(errno))) }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? output.close() }
        t.stagedSnapshot = try FileSnapshot.read(path); try save(t)
        let sourceFD = open(t.source, O_RDONLY | O_NOFOLLOW)
        guard sourceFD >= 0 else { throw PhotoError.message("无法读取源文件：" + t.source) }
        let inputHandle = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? inputHandle.close() }
        try unchanged(t.source, t.original)
        guard try FileSnapshot.read(descriptor: sourceFD) == t.original else {
            throw PhotoError.message("源文件句柄身份变化：" + t.source)
        }
        var hash = SHA256(), bytes: UInt64 = 0
        try checkpoint("archiveSourceRead")
        while true {
            if cancellation.isCancelled { throw CancellationError() }
            guard let data = try inputHandle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            try checkpoint("archiveCopyChunk")
            try output.write(contentsOf: data); hash.update(data: data); bytes += UInt64(data.count)
            report("正在复制", bytes)
        }
        try unchanged(t.source, t.original)
        guard try FileSnapshot.read(descriptor: sourceFD) == t.original else {
            throw PhotoError.message("复制期间源文件发生变化：" + t.source)
        }
        guard bytes == UInt64(t.original.size) else { throw PhotoError.message("复制长度不一致，源文件保留") }
        // Copy only metadata: this includes resource forks stored as extended attributes.
        guard fcopyfile(sourceFD, fd, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw PhotoError.message("无法保留文件元数据：" + String(cString: strerror(errno)))
        }
        try output.synchronize()
        t.fingerprint = Fingerprint(size: bytes, digest: hash.finalize().map { String(format: "%02x", $0) }.joined())
        t.stagedSnapshot = try FileSnapshot.read(path); try save(t)
        try checkpoint("archiveBeforeVerify")
        try verify(path, t.fingerprint!, cancellation: cancellation) { report("正在校验", $0) }
        try unchanged(path, t.stagedSnapshot!); try unchanged(t.source, t.original)
        t.phase = "ready"; try save(t)
        return t
    }
    private func commitTransfer(_ input: ArchiveTransfer, save: (ArchiveTransfer) throws -> Void) throws -> ArchiveTransfer {
        var t = input
        if t.phase == "done" { return t }
        if ["committing", "destinationCommitted"].contains(t.phase), exists(t.destination) {
            if let result = t.result { try unchanged(t.destination, result) }
            else { t.result = try renamed(t.destination, t.strategy == "rename" ? t.original : t.stagedSnapshot!) }
        } else {
            try unchanged(t.source, t.original); try vacant(t.destination)
            if t.strategy == "copy" {
                guard let path = t.staged, let snapshot = t.stagedSnapshot, t.fingerprint != nil else {
                    throw PhotoError.message("临时副本尚未校验")
                }
                try unchanged(path, snapshot)
            }
            t.phase = "committing"; try save(t)
            try checkpoint("archiveBeforeCommit")
            // Recheck after fault injection and immediately before mutation.
            try unchanged(t.source, t.original)
            do {
                try checkpoint("archiveRenameAttempt")
                try exclusiveRename(t.strategy == "rename" ? t.source : t.staged!, t.destination)
            }
            catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(EXDEV) && t.strategy == "rename" {
                // Unexpected mount change: stage and verify the copy before committing it.
                t.strategy = "copy"; t.phase = "pending"; try save(t)
                t = try prepareTransfer(t, cancellation: CancellationFlag(), report: { _, _ in }, save: save)
                return try commitTransfer(t, save: save)
            }
            try checkpoint("archiveAfterRename")
            t.result = try renamed(t.destination, t.strategy == "rename" ? t.original : t.stagedSnapshot!)
        }
        try syncDirectory(containing: t.destination)
        try syncDirectory(containing: t.strategy == "rename" ? t.source : t.staged!)
        t.phase = "destinationCommitted"; try save(t)
        try checkpoint("archiveAfterCommit")
        if t.strategy == "copy", exists(t.source) {
            try checkpoint("beforeSourceDelete")
            try unchanged(t.destination, t.result!); try unchanged(t.source, t.original)
            try fm.removeItem(atPath: t.source)
            try syncDirectory(containing: t.source)
            try checkpoint("archiveAfterSourceDelete")
        }
        t.phase = "done"; try save(t); return t
    }
    func executeArchive(_ batch: inout OperationBatch, i: Int, cancellation: CancellationFlag,
                        activity: @Sendable (Int, Int, String) -> Void) throws {
        for f in batch.items[i].files { try checkTransfer(f.transfer!, cancellation: cancellation) }
        for j in batch.items[i].files.indices {
            let transfer = batch.items[i].files[j].transfer!, count = batch.items.count
            let name = URL(fileURLWithPath: transfer.source).lastPathComponent
            var last = Date.distantPast
            _ = try prepareTransfer(transfer, cancellation: cancellation, report: { phase, bytes in
                if Date().timeIntervalSince(last) >= 0.2 {
                    activity(i, count, phase + " " + name + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: transfer.original.size, countStyle: .file))
                    last = Date()
                }
            }) { updated in
                batch.items[i].files[j].transfer = updated
                batch.items[i].files[j].before = updated.fingerprint
                batch.items[i].files[j].state = updated.phase
                try persist(batch, item: i)
            }
        }
        activity(i, batch.items.count, "正在移动 " + batch.items[i].photo.name)
        if cancellation.isCancelled { throw CancellationError() }
        // All copies are ready before the first group member is committed.
        for f in batch.items[i].files where !["done", "destinationCommitted"].contains(f.transfer!.phase) {
            let t = f.transfer!
            if t.phase != "committing" || !exists(t.destination) { try unchanged(t.source, t.original); try vacant(t.destination) }
        }
        for j in batch.items[i].files.indices {
            let transfer = batch.items[i].files[j].transfer!
            _ = try commitTransfer(transfer) { updated in
                batch.items[i].files[j].transfer = updated
                batch.items[i].files[j].before = updated.fingerprint
                batch.items[i].files[j].after = updated.fingerprint
                batch.items[i].files[j].state = updated.phase
                try persist(batch, item: i)
            }
        }
    }

    func undoArchive(_ batch: inout OperationBatch, i: Int, cancellation: CancellationFlag, activity: @Sendable (Int, Int, String) -> Void) throws {
        // Preflight the whole group, including interrupted reverse transfers.
        for f in batch.items[i].files where f.state != "undone" {
            if f.state == "undoDiscarding", !exists(f.destination) {
                try unchanged(f.source, f.transfer!.original)
            } else if let reverse = f.undoTransfer { try checkTransfer(reverse, cancellation: cancellation) }
            else {
                let t = f.transfer!
                if ["pending", "staging", "ready"].contains(t.phase) { continue }
                try checkTransfer(t, cancellation: cancellation)
            }
        }
        for j in batch.items[i].files.indices.reversed() {
            let f = batch.items[i].files[j]
            if f.state == "undone" { continue }
            let t = f.transfer!
            if f.state == "undoDiscarding", !exists(f.destination) {
                try unchanged(f.source, t.original)
                batch.items[i].files[j].state = "undone"; try persist(batch, item: i); continue
            }
            if f.undoTransfer == nil {
                if ["pending", "staging", "ready"].contains(t.phase) || (t.phase == "committing" && !exists(t.destination)) {
                    try discardStaging(t)
                    batch.items[i].files[j].state = "undone"; try persist(batch, item: i); continue
                }
                if exists(t.source) {
                    // A verified forward copy was committed but the original was not removed.
                    guard t.strategy == "copy", let hash = t.fingerprint else { throw PhotoError.message("原路径已被占用") }
                    try unchanged(t.source, t.original)
                    try verify(t.source, hash, cancellation: cancellation)
                    try verify(t.destination, hash, cancellation: cancellation)
                    try unchanged(t.source, t.original)
                    if let result = t.result { try unchanged(t.destination, result) }
                    else { _ = try renamed(t.destination, t.stagedSnapshot!) }
                    // Journal the deletion so a crash after it remains safely undoable.
                    batch.items[i].files[j].state = "undoDiscarding"; try persist(batch, item: i)
                    try fm.removeItem(atPath: t.destination)
                    try syncDirectory(containing: t.destination)
                    try checkpoint("archiveUndoAfterDiscard")
                    batch.items[i].files[j].state = "undone"; try persist(batch, item: i); continue
                }
                let snapshot = try t.result ?? renamed(t.destination, t.strategy == "rename" ? t.original : t.stagedSnapshot!)
                try unchanged(t.destination, snapshot)
                batch.items[i].files[j].undoTransfer = ArchiveTransfer(source: t.destination, destination: t.source, original: snapshot)
                try persist(batch, item: i)
            }
            let reverse = batch.items[i].files[j].undoTransfer!
            let count = batch.items.count, done = count - i - 1
            var last = Date.distantPast
            _ = try prepareTransfer(reverse, cancellation: cancellation, report: { phase, bytes in
                if Date().timeIntervalSince(last) >= 0.2 {
                    activity(done, count, phase + " " + URL(fileURLWithPath: reverse.source).lastPathComponent + " · " + ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) + " / " + ByteCountFormatter.string(fromByteCount: reverse.original.size, countStyle: .file))
                    last = Date()
                }
            }) { updated in
                batch.items[i].files[j].undoTransfer = updated; batch.items[i].files[j].state = "undoing"
                try persist(batch, item: i)
            }
        }
        activity(batch.items.count - i - 1, batch.items.count, "正在恢复 " + batch.items[i].photo.name)
        if cancellation.isCancelled { throw CancellationError() }
        for f in batch.items[i].files where f.state != "undone" {
            let reverse = f.undoTransfer!
            if ["pending", "ready"].contains(reverse.phase) {
                try unchanged(reverse.source, reverse.original); try vacant(reverse.destination)
            }
        }
        for j in batch.items[i].files.indices.reversed() where batch.items[i].files[j].state != "undone" {
            let reverse = batch.items[i].files[j].undoTransfer!
            _ = try commitTransfer(reverse) { updated in
                batch.items[i].files[j].undoTransfer = updated
                batch.items[i].files[j].state = updated.phase == "done" ? "undone" : "undoing"
                try persist(batch, item: i)
            }
        }
    }
}
