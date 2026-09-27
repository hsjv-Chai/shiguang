import Foundation

extension OperationService {
    public func timePlan(photos: [Photo], edit: TimeEdit, cancellation: CancellationFlag,
                         progress: @Sendable (Int, Int, String) -> Void = { _, _, _ in }) throws -> OperationBatch {
        var batch = OperationBatch(kind: "time", items: [])
        var reserved = Set<String>()
        progress(0, photos.count, "正在检查文件状态")
        for photo in photos {
            if cancellation.isCancelled { return OperationBatch(kind: "time", items: [], status: "cancelled") }
            var item = OperationItem(photo: photo, files: [])
            do {
                if let problem = photo.problem { throw PhotoError.message(problem) }
                item.newCapture = try edit.apply(to: photo.capture)
                let xmp = photo.sidecar ?? (photo.hasRAW ? URL(fileURLWithPath: photo.path).deletingPathExtension().appendingPathExtension("xmp").path : nil)
                var paths = photo.files.filter { !$0.isRAW }.map(\.path)
                if let xmp { paths.append(xmp) }
                var groupReserved = Set<String>()
                for path in paths {
                    guard !reserved.contains(path.lowercased()), groupReserved.insert(path.lowercased()).inserted else {
                        throw PhotoError.message("多张照片共享同一元数据文件")
                    }
                    let isNew = path == xmp && photo.sidecar == nil
                    if isNew { try timeVacant(path) }
                    let snapshot = isNew ? nil : try FileSnapshot.read(path)
                    var f = FileStep(source: path, destination: path, before: nil)
                    f.timeEdit = TimeEditJournal(role: isNew ? "new" : "existing", original: snapshot)
                    f.previewSnapshot = snapshot; item.files.append(f)
                }
                for raw in photo.files where raw.isRAW {
                    let snapshot = try FileSnapshot.read(raw.path)
                    var f = FileStep(source: raw.path, destination: raw.path, before: nil)
                    f.timeEdit = TimeEditJournal(role: "readonly", original: snapshot)
                    f.previewSnapshot = snapshot; f.state = "readonly"; item.files.append(f)
                }
                reserved.formUnion(groupReserved)
            } catch { item.status = "blocked"; item.error = error.localizedDescription }
            batch.items.append(item)
            if batch.items.count % 100 == 0 { progress(0, photos.count, "正在检查文件状态 · \(batch.items.count) / \(photos.count) 张") }
        }
        let paths = batch.items.filter { $0.status == "pending" }.flatMap { $0.files.filter { $0.timeEdit?.role == "existing" }.map(\.source) }
        var rows: [String: [String: Any]] = [:], errors: [String: String] = [:]
        var checked = Set<String>(), reported = 0
        for start in stride(from: 0, to: paths.count, by: 128) {
            if cancellation.isCancelled { return OperationBatch(kind: "time", items: [], status: "cancelled") }
            let chunk = Array(paths[start..<min(start + 128, paths.count)])
            progress(reported, photos.count, "正在读取拍摄时间 · \(start) / \(paths.count) 个文件")
            do {
                try checkpoint("timePreviewMetadataBatch")
                let read = try metadata.read(chunk, cancellation: cancellation, tolerateFileErrors: true)
                rows.merge(read) { _, new in new }
            } catch is CancellationError { return OperationBatch(kind: "time", items: [], status: "cancelled") }
            catch { for path in chunk { errors[path] = error.localizedDescription } }
            checked.formUnion(chunk)
            // Advance once per photo, even when its files straddle two chunks.
            while reported < batch.items.count {
                let item = batch.items[reported]
                if item.status == "pending" && item.files.contains(where: { $0.timeEdit?.role == "existing" && !checked.contains($0.source) }) { break }
                reported += 1
            }
            progress(reported, photos.count, "已读取拍摄时间")
        }
        try checkpoint("timePreviewMetadataFinished")
        for i in batch.items.indices where batch.items[i].status == "pending" {
            if cancellation.isCancelled { return OperationBatch(kind: "time", items: [], status: "cancelled") }
            do {
                for f in batch.items[i].files {
                    if let snapshot = f.timeEdit?.original { try timeUnchanged(f.source, snapshot) }
                    else { try timeVacant(f.source) }
                    if f.timeEdit?.role == "existing" {
                        if let error = errors[f.source] { throw PhotoError.message(error) }
                        guard let row = rows[f.source],
                              let type = row["File:FileType"] as? String,
                              ["JPEG", "PNG", "TIFF", "HEIC", "HEIF", "XMP"].contains(type),
                              !row.keys.contains(where: { $0 == "Error" || $0.hasSuffix(":Error") }) else {
                            throw PhotoError.message("无法读取元数据：" + f.source)
                        }
                    }
                }
                // Retain the actual pre-edit metadata for the fast undo index update.
                var originalPhoto = batch.items[i].photo
                originalPhoto.members = originalPhoto.files.map { member in
                    var member = member
                    if !member.isRAW, let row = rows[member.path] { member.capture = metadata.capture(row) }
                    if let snapshot = batch.items[i].files.first(where: { $0.source == member.path })?.timeEdit?.original { member.bytes = snapshot.size }
                    return member
                }
                if let sidecar = originalPhoto.sidecar { originalPhoto.sidecarCapture = rows[sidecar].flatMap { metadata.capture($0) } }
                originalPhoto.capture = originalPhoto.sidecarCapture ?? originalPhoto.files.compactMap(\.capture).first
                originalPhoto.captureSource = originalPhoto.sidecarCapture != nil ? "XMP" : originalPhoto.files.first { $0.capture != nil }?.format.uppercased()
                batch.items[i].photo = originalPhoto
                let writable = batch.items[i].files.filter { $0.timeEdit?.role != "readonly" }
                if !writable.isEmpty && writable.allSatisfy({ $0.timeEdit?.role == "existing" && rows[$0.source].flatMap { metadata.capture($0) } == batch.items[i].newCapture }) {
                    batch.items[i].status = "skipped"; batch.items[i].error = "所有配套文件时间均未变化"
                }
            } catch { batch.items[i].status = "blocked"; batch.items[i].error = error.localizedDescription }
        }
        if cancellation.isCancelled { return OperationBatch(kind: "time", items: [], status: "cancelled") }
        progress(photos.count, photos.count, "校时预览已准备好")
        return batch
    }
}
