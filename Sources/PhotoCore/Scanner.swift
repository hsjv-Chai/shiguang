import Foundation

public final class Scanner: @unchecked Sendable {
    let metadata: MetadataService
    let store: Store
    public init(metadata: MetadataService, store: Store) { self.metadata = metadata; self.store = store }
    private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent).path
    }
    private static func stem(_ path: String) -> String { URL(fileURLWithPath: canonical(path)).deletingPathExtension().path }
    private static func normalized(_ photo: Photo) -> Photo {
        var p = photo
        p.members = photo.files.map { var f = $0; f.path = canonical(f.path); return f }
        p.path = canonical(photo.path); p.sidecar = photo.sidecar.map(canonical)
        p.source = URL(fileURLWithPath: photo.source).resolvingSymlinksInPath().path
        return p
    }

    public func scan(root: URL, cancellation: CancellationFlag, progress: @Sendable (Int, Int, [Photo]) -> Void) throws {
        let fm = FileManager.default
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        guard !root.pathComponents.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) else { throw PhotoError.message("不直接扫描 Apple 照片图库，请先从照片 App 导出到普通文件夹") }
        var errors: [String] = [], paths: [String] = []
        guard let iterator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { url, error in errors.append(url.lastPathComponent + ": " + error.localizedDescription); return true }) else { throw PhotoError.message("无法读取文件夹") }
        let excluded = [store.directory.path, UserDefaults.standard.string(forKey: "backupDirectory")].compactMap { $0 }
        for case let url as URL in iterator {
            if cancellation.isCancelled { return }
            if excluded.contains(where: { url.path == $0 || url.path.hasPrefix($0 + "/") }) { iterator.skipDescendants(); continue }
            let props = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if props?.isSymbolicLink == true { iterator.skipDescendants(); continue }
            guard props?.isRegularFile == true else { continue }
            let ext = url.pathExtension.lowercased()
            if Photo.supported.contains(ext) || ext == "xmp" { paths.append(url.path) }
        }
        let existing = try store.photos().map(Self.normalized)
        // Keep known pairs together when a member (or the entire pair) is temporarily missing.
        for photo in existing where photo.isPair && photo.files.allSatisfy({ $0.path.hasPrefix(root.path + "/") }) {
            paths += photo.allPaths
        }
        try readGroups(paths: Array(Set(paths)), existing: existing, source: root.path, preserveBindings: true, cancellation: cancellation, progress: progress)
        if !errors.isEmpty { throw PhotoError.message("部分目录无法扫描：" + errors.prefix(5).joined(separator: "；")) }
    }

    /// Old history operates on its original files. Reconcile every affected stem afterwards,
    /// including surviving members of an old group, without rescanning unrelated folders.
    public func reconcile(paths: [String], preferred: Photo) throws {
        let current = try store.photos().map(Self.normalized)
        let preferred = Self.normalized(preferred)
        var stems = Set((paths + preferred.allPaths).map(Self.stem))
        var affected: [Photo] = []
        for photo in current where !stems.isDisjoint(with: Set(photo.allPaths.map(Self.stem))) {
            affected.append(photo); stems.formUnion(photo.allPaths.map(Self.stem))
        }
        var found: [String] = []
        let dirs = Set(stems.map { URL(fileURLWithPath: $0).deletingLastPathComponent() })
        for dir in dirs {
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                let props = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                if props.isRegularFile == true && props.isSymbolicLink != true && stems.contains(Self.stem(url.path)) { found.append(url.path) }
            }
        }
        let seeds = [preferred] + affected
        try readGroups(paths: found, existing: seeds, source: preferred.source, preserveBindings: false, cancellation: CancellationFlag(), removing: Set(affected.map(\.id)), progress: { _, _, _ in })
    }

    private func readGroups(paths: [String], existing: [Photo], source: String, preserveBindings: Bool, cancellation: CancellationFlag, removing: Set<String> = [], progress: @Sendable (Int, Int, [Photo]) -> Void) throws {
        let byStem = Dictionary(grouping: Array(Set(paths.map(Self.canonical))), by: Self.stem)
        var oldByPath: [String: [Photo]] = [:]
        for photo in existing { for file in photo.files { oldByPath[file.path, default: []].append(photo) } }
        struct Group { var paths: [String]; var sidecars: [String]; var problem: String? }
        var groups: [Group] = []
        for stem in byStem.keys.sorted() {
            let siblings = byStem[stem]!.sorted()
            let photos = siblings.filter { Photo.supported.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            let sidecars = siblings.filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == "xmp" }
            guard !photos.isEmpty else { continue }
            let raw = photos.filter { URL(fileURLWithPath: $0).pathExtension.lowercased() == "cr2" }
            let jpeg = photos.filter { ["jpg", "jpeg"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
            let pair = photos.count == 2 && raw.count == 1 && jpeg.count == 1
            let problem: String? = sidecars.count > 1 ? "存在多个同名 XMP，无法确定配套文件" : (photos.count > 1 && !pair ? "同名照片包含多个候选格式，无法唯一配对 JPG + CR2" : nil)
            if pair { groups.append(Group(paths: raw + jpeg, sidecars: sidecars, problem: problem)) }
            else { for path in photos { groups.append(Group(paths: [path], sidecars: sidecars, problem: problem)) } }
        }
        if !preserveBindings, let preferred = existing.first {
            groups.sort { $0.paths.contains(preferred.path) && !$1.paths.contains(preferred.path) }
        }
        progress(0, groups.count, [])
        var usedIDs = Set<String>(), allResults: [Photo] = []
        // During reconciliation publish all affected groups in one transaction.
        for start in stride(from: 0, to: groups.count, by: 80) {
            if cancellation.isCancelled { return }
            let chunk = Array(groups[start..<min(start + 80, groups.count)])
            let readPaths = Array(Set(chunk.flatMap { $0.paths + $0.sidecars })).filter { FileManager.default.fileExists(atPath: $0) }
            var rows: [String: [String: Any]] = [:]
            do { rows = try metadata.read(readPaths) } catch {
                for path in readPaths {
                    if cancellation.isCancelled { return }
                    if let result = try? metadata.read([path]) { rows.merge(result) { a, _ in a } }
                }
            }
            var result: [Photo] = [], absorbed = Set<String>()
            for group in chunk {
                let candidates = group.paths.flatMap { oldByPath[$0] ?? [] }
                let old = candidates.first { !usedIDs.contains($0.id) }
                var photo = old ?? Photo(path: group.paths[0], source: source)
                photo.path = group.paths[0]
                if usedIDs.contains(photo.id) { photo.id = UUID().uuidString }
                usedIDs.insert(photo.id)
                photo.problem = group.problem
                photo.notice = candidates.compactMap(\.notice).first
                let manual = candidates.filter { $0.manualPlace && $0.place != nil }
                if let chosen = manual.first { photo.place = chosen.place; photo.manualPlace = true }
                if Set(manual.compactMap(\.place)).count > 1 { photo.notice = "原 JPG 与 CR2 的手动地点不同，已采用 CR2 的地点：" + (photo.place ?? "") }
                photo.sidecar = group.sidecars.count == 1 ? group.sidecars[0] : nil
                photo.sidecarCapture = photo.sidecar.flatMap { rows[$0] }.flatMap { metadata.capture($0) }
                photo.sidecarBytes = photo.sidecar.map { fileSize($0) }
                photo.members = group.paths.map { path in
                    PhotoMember(path: path, bytes: fileSize(path), capture: rows[path].flatMap { metadata.capture($0) })
                }
                let missing = group.paths.filter { !FileManager.default.fileExists(atPath: $0) }
                if !missing.isEmpty { photo.problem = "配套照片缺失：" + missing.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: "、") }
                else if group.paths.contains(where: { rows[$0] == nil || rows[$0]?["ExifTool:Error"] != nil }) { photo.problem = "无法读取配套照片元数据，文件可能损坏或不可访问" }
                if let sidecar = photo.sidecar, rows[sidecar] == nil || rows[sidecar]?["ExifTool:Error"] != nil { photo.problem = "XMP 配套文件缺失或无法读取" }
                photo.capture = photo.sidecarCapture ?? photo.files.compactMap(\.capture).first
                photo.captureSource = photo.sidecarCapture != nil ? "XMP" : photo.files.first(where: { $0.capture != nil })?.format.uppercased()
                photo.latitude = nil; photo.longitude = nil
                for path in group.paths {
                    if let row = rows[path], let gps = coordinates(row) { photo.latitude = gps.0; photo.longitude = gps.1; break }
                }
                photo.bytes = photo.files.reduce(0) { $0 + $1.bytes }
                if preserveBindings { absorbed.formUnion(candidates.map(\.id)) }
                result.append(photo)
            }
            if cancellation.isCancelled { return }
            if preserveBindings { try store.replace(result, removing: absorbed); progress(start + result.count, groups.count, result) }
            else { allResults += result }
        }
        if !preserveBindings { try store.replace(allResults, removing: removing); progress(groups.count, groups.count, allResults) }
    }
    private func fileSize(_ path: String) -> Int64 { Int64((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    private func coordinates(_ row: [String: Any]) -> (Double, Double)? {
        guard var lat = row["Composite:GPSLatitude"] as? Double ?? row["GPS:GPSLatitude"] as? Double ?? row["XMP-exif:GPSLatitude"] as? Double,
              var lon = row["Composite:GPSLongitude"] as? Double ?? row["GPS:GPSLongitude"] as? Double ?? row["XMP-exif:GPSLongitude"] as? Double else { return nil }
        if row["Composite:GPSLatitude"] == nil, row["GPS:GPSLatitudeRef"] as? String == "S" { lat = -abs(lat) }
        if row["Composite:GPSLongitude"] == nil, row["GPS:GPSLongitudeRef"] as? String == "W" { lon = -abs(lon) }
        return abs(lat) <= 90 && abs(lon) <= 180 ? (lat, lon) : nil
    }
}
