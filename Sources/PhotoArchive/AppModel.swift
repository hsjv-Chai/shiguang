import SwiftUI
import AppKit
import CoreLocation
import PhotoCore

@MainActor final class AppModel: ObservableObject {
    @Published var photos: [Photo] = []
    @Published var selection = Set<String>()
    @Published var sourceFilter: String? = nil
    @Published var yearFilter: String? = nil
    @Published var placeFilter: String? = nil
    @Published var search = ""
    @Published var busy = false
    @Published var status = "选择照片文件夹，开始整理你的影像。"
    @Published var fraction: Double = 0
    @Published var error: String?
    @Published var plan: OperationBatch?
    @Published var history: [OperationBatch] = []
    @Published var showHistory = false
    @Published var showTime = false
    @Published var showPlace = false
    @Published var showConsent = false
    @Published var backupPath: String
    private var flag = CancellationFlag()
    private var store: Store?
    private var metadata: MetadataService?
    private var operations: OperationService?
    private let geocoder = CLGeocoder()
    private var lastGeocode = Date.distantPast
    var filtered: [Photo] {
        photos.filter { p in (sourceFilter == nil || p.source == sourceFilter) && (yearFilter == nil || p.year == yearFilter) && (placeFilter == nil || (p.place ?? "未知地点") == placeFilter) && (search.isEmpty || p.files.contains { URL(fileURLWithPath: $0.path).lastPathComponent.localizedCaseInsensitiveContains(search) } || (p.place ?? "").localizedCaseInsensitiveContains(search)) }
    }
    var selected: [Photo] { filtered.filter { selection.contains($0.id) } }
    var sources: [String] { Array(Set(photos.map(\.source))).sorted() }
    var years: [String] { Array(Set(photos.map(\.year))).sorted(by: >) }
    var places: [String] { Array(Set(photos.map { $0.place ?? "未知地点" })).sorted() }
    init() {
        let directory = ProcessInfo.processInfo.environment["PHOTOARCHIVE_DATA_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PhotoArchive")
        backupPath = UserDefaults.standard.string(forKey: "backupDirectory") ?? directory.appendingPathComponent("Backups").path
        do {
            let s = try Store(directory: directory), m = try MetadataService.locate()
            store = s; metadata = m; operations = OperationService(store: s, metadata: m)
            let count = try operations!.recoverInterrupted()
            if count > 0 { status = "发现 \(count) 个中断批次，请在操作历史中继续执行或撤销。" }
            Task { await reload() }
        } catch { self.error = error.localizedDescription }
    }
    func reload() async {
        guard let store else { return }
        do {
            let result = try await Task.detached { (try store.photos(), try store.batches()) }.value
            photos = result.0.sorted { ($0.capture?.value ?? "") > ($1.capture?.value ?? "") }; history = result.1
            selection.formIntersection(Set(photos.map(\.id)))
        } catch { self.error = error.localizedDescription }
    }
    func start(_ text: String) { flag = CancellationFlag(); busy = true; status = text; fraction = 0 }
    func cancel() { flag.cancel(); status = "正在安全停止，等待当前文件完成…" }
    func folderPanel(message: String) -> URL? {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false; panel.message = message; panel.prompt = "选择文件夹"
        return panel.runModal() == .OK ? panel.url : nil
    }
    func chooseSource() {
        guard !busy, let root = folderPanel(message: "扫描本地或移动硬盘文件夹，不会修改任何照片。") else { return }; scan(root)
    }
    func rescan() { guard !busy else { return }; if let source = sourceFilter ?? sources.first { scan(URL(fileURLWithPath: source)) } else { chooseSource() } }
    private func scan(_ root: URL) {
        guard let store, let metadata else { return }
        start("正在发现照片…"); let flag = flag
        Task {
            do {
                try await Task.detached {
                    try Scanner(metadata: metadata, store: store).scan(root: root, cancellation: flag) { done, total, additions in
                        Task { @MainActor in
                            self.status = done == 0 ? "发现 \(total) 张照片…" : "正在读取 \(done) / \(total) 张照片"
                            self.fraction = total > 0 ? Double(done) / Double(total) : 0
                            if !additions.isEmpty {
                                let ids = Set(additions.map(\.id)); let paths = Set(additions.flatMap { $0.files.map(\.path) }); self.photos.removeAll { ids.contains($0.id) || !$0.files.allSatisfy { !paths.contains($0.path) } }; self.photos.append(contentsOf: additions)
                            }
                        }
                    }
                }.value
                await reload(); sourceFilter = root.resolvingSymlinksInPath().path
                status = flag.isCancelled ? "扫描已停止，已读取的照片保留在索引中。" : "扫描完成 · 共 \(photos.count) 张照片"
            } catch { self.error = error.localizedDescription; await reload() }
            busy = false
        }
    }
    func chooseBackup() {
        guard let root = folderPanel(message: "选择原片备份位置。已有备份会保留在原位置。") else { return }
        backupPath = root.path; UserDefaults.standard.set(root.path, forKey: "backupDirectory")
    }
    func archive() {
        guard let operations, !selected.isEmpty, let root = folderPanel(message: "选择归档根目录。预览确认后将移动原文件，按 年/月/地点 整理。") else { return }
        let photos = selected; start("正在生成归档预览…"); let flag = flag
        Task {
            do {
                let result = try await Task.detached {
                    try operations.archivePlan(photos: photos, root: root, cancellation: flag) { done, total, name in
                        Task { @MainActor in
                            guard self.busy, !flag.isCancelled else { return }
                            self.fraction = Double(done) / Double(max(1, total))
                            self.status = "生成归档预览 · \(done) / \(total) 张 · \(name)"
                        }
                    }
                }.value
                if !flag.isCancelled { plan = result; fraction = 1 }
                status = flag.isCancelled ? "已停止生成预览，照片未移动。" : "归档预览已准备好"
            }
            catch { self.error = error.localizedDescription }; busy = false
        }
    }
    func previewTime(_ edit: TimeEdit) {
        guard let operations else { return }; let photos = selected
        showTime = false; start("正在生成时间修改预览…"); let flag = flag
        Task {
            do { let result = try await Task.detached { try operations.timePlan(photos: photos, edit: edit, cancellation: flag) }.value; if !flag.isCancelled { plan = result }; status = "时间修改预览已准备好" }
            catch { self.error = error.localizedDescription }; busy = false
        }
    }
    func execute(_ batch: OperationBatch, undo: Bool = false) {
        guard let operations, !busy else { return }; plan = nil
        start(undo ? "正在撤销操作…" : "正在执行\(batch.title)…"); let flag = flag; let backup = URL(fileURLWithPath: backupPath)
        Task {
            do {
                let result = try await Task.detached {
                    let report: @Sendable (OperationBatch) -> Void = { b in
                        let fraction = Double(b.items.filter { ["done", "undone", "failed", "blocked", "skipped", "undoFailed"].contains($0.status) }.count) / Double(max(1, b.items.count))
                        let status = "\(b.title) · \(b.done) / \(b.items.count) 已完成"
                        Task { @MainActor in
                            guard self.busy, !flag.isCancelled else { return }
                            self.fraction = fraction; self.status = status
                        }
                    }
                    return try undo ? operations.undo(batch, cancellation: flag, progress: report) : operations.execute(batch, backupRoot: backup, cancellation: flag, activity: { done, total, detail in
                        Task { @MainActor in
                            guard self.busy, !flag.isCancelled else { return }
                            self.fraction = Double(done) / Double(max(1, total)); self.status = "归档 · \(done) / \(total) 张 · \(detail)"
                        }
                    }, progress: report)
                }.value
                status = "\(result.title) · \(localizedStatus(result.status))"
                if result.items.contains(where: { $0.status == "failed" || $0.status == "undoFailed" }) { showHistory = true }
            } catch { self.error = error.localizedDescription }
            await reload(); busy = false
        }
    }
    func setPlace(_ place: String) {
        guard let store else { return }; let value = place.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return }
        var updates = selected
        for i in updates.indices { updates[i].place = value; updates[i].manualPlace = true }
        showPlace = false; start("正在保存地点…")
        Task {
            do { let values = updates; try await Task.detached { try store.save(values) }.value; await reload(); status = "已为 \(updates.count) 张照片设置地点" }
            catch { self.error = error.localizedDescription }; busy = false
        }
    }
    func requestLocations() {
        if UserDefaults.standard.bool(forKey: "geocodeConsent") { resolveLocations() } else { showConsent = true }
    }
    func allowLocations() { UserDefaults.standard.set(true, forKey: "geocodeConsent"); showConsent = false; resolveLocations() }
    func resolveLocations() {
        guard let store, !busy else { return }
        let candidates = selected.filter { !$0.manualPlace && $0.latitude != nil && $0.longitude != nil }
        guard !candidates.isEmpty else { error = "所选照片没有可识别的 GPS，或已设置手动地点。"; return }
        start("正在根据 GPS 识别城市…"); let flag = flag
        Task {
            var failures = 0, completed = 0
            for var photo in candidates {
                if flag.isCancelled { break }
                let lat = photo.latitude!, lon = photo.longitude!
                let key = String(format: "%.4f,%.4f", lat, lon)
                do {
                    var name = try await Task.detached { try store.place(key) }.value
                    if name == nil {
                        for attempt in 0..<3 {
                            if flag.isCancelled { break }
                            let wait = max(0, 1.5 - Date().timeIntervalSince(lastGeocode))
                            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                            if flag.isCancelled { break }
                            do {
                                lastGeocode = Date()
                                let marks = try await geocoder.reverseGeocodeLocation(CLLocation(latitude: lat, longitude: lon), preferredLocale: Locale(identifier: "zh_CN"))
                                if let p = marks.first, let city = p.locality ?? p.subAdministrativeArea ?? p.administrativeArea {
                                    var parts = [city]
                                    if let province = p.administrativeArea, province != city { parts.append(province) }
                                    if let country = p.country { parts.append(country) }
                                    name = parts.joined(separator: " · ")
                                }
                                break
                            } catch { if attempt == 2 { throw error }; try await Task.sleep(nanoseconds: UInt64(2 << attempt) * 1_000_000_000) }
                        }
                        if let name { let result = name; try await Task.detached { try store.savePlace(key: key, name: result) }.value }
                    }
                    if let name { photo.place = name; let update = photo; try await Task.detached { try store.save(update) }.value } else { failures += 1 }
                } catch { failures += 1 }
                completed += 1; fraction = Double(completed) / Double(candidates.count); status = "识别城市 \(completed) / \(candidates.count) · \(failures) 张未识别"
            }
            await reload(); busy = false; status = "地点识别\(flag.isCancelled ? "已停止" : "完成") · \(failures) 张未识别，可重试或手动补充"
        }
    }
    func cleanBackups(_ batch: OperationBatch) {
        guard let store, batch.status == "undone", !busy else { return }
        start("正在清理已撤销批次的备份…")
        Task {
            do {
                try await Task.detached {
                    var updated = batch
                    for i in updated.items.indices { for j in updated.items[i].files.indices {
                        if let path = updated.items[i].files[j].backup, FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
                        updated.items[i].files[j].backup = nil
                    } }
                    try store.save(updated)
                }.value
                status = "已清理该批次备份"; await reload()
            } catch { self.error = error.localizedDescription }; busy = false
        }
    }
}
func localizedStatus(_ value: String) -> String {
    ["preview": "待确认", "pending": "待执行", "running": "执行中", "done": "成功", "completed": "完成", "partial": "部分失败", "failed": "失败，可重试", "cancelled": "已停止", "interrupted": "意外中断", "undone": "已撤销", "undoing": "正在撤销", "undoFailed": "撤销未完成", "skipped": "跳过", "blocked": "无法执行"][value] ?? value
}
