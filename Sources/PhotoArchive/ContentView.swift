import SwiftUI
import AppKit
import ImageIO
import PhotoCore

typealias ViewState<Value> = SwiftUI.State<Value>

private let moss = Color(red: 0.25, green: 0.38, blue: 0.30)
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            sidebar.navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 270)
        } content: {
            VStack(spacing: 0) {
                collectionHeader
                Divider()
                if model.photos.isEmpty { emptyState }
                else if model.filtered.isEmpty { ContentUnavailableView("没有匹配的照片", systemImage: "line.3.horizontal.decrease.circle", description: Text("调整左侧筛选条件或搜索关键词。")) }
                else { ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 230), spacing: 18)], spacing: 20) {
                        ForEach(model.filtered) { photo in
                            PhotoTile(photo: photo, selected: model.selection.contains(photo.id))
                                .onTapGesture { select(photo) }
                                .contextMenu { Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: photo.path)]) }; Button("选择这张照片") { model.selection = [photo.id] } }
                        }
                    }.padding(24)
                }.background(Color(nsColor: .controlBackgroundColor)) }
                Divider()
                HStack(spacing: 10) {
                    Circle().fill(model.busy ? Color.orange : moss).frame(width: 6, height: 6)
                    Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    if model.busy { ProgressView(value: model.fraction).frame(width: 90); Button("停止") { model.cancel() }.controlSize(.small) }
                    else { Text("本地管理 · 原片可恢复").font(.caption2).foregroundStyle(.tertiary) }
                }.padding(.horizontal, 20).padding(.vertical, 12)
            }.navigationSplitViewColumnWidth(min: 500, ideal: 760)
        } detail: { inspector.navigationSplitViewColumnWidth(min: 250, ideal: 280, max: 350) }
        .tint(moss)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.chooseSource() } label: { Label("添加文件夹", systemImage: "folder.badge.plus") }.disabled(model.busy)
                Divider()
                Button { model.archive() } label: { Label("归档", systemImage: "tray.and.arrow.down") }.disabled(model.busy || model.selected.isEmpty)
                Button { model.showTime = true } label: { Label("调整时间", systemImage: "clock.arrow.circlepath") }.disabled(model.busy || model.selected.isEmpty)
                Button { model.showPlace = true } label: { Label("设置地点", systemImage: "mappin.and.ellipse") }.disabled(model.busy || model.selected.isEmpty)
                Button { model.showHistory = true } label: { Label("操作历史", systemImage: "clock") }
            }
        }
        .sheet(item: $model.plan) { batch in PlanSheet(batch: batch).environmentObject(model) }
        .sheet(isPresented: $model.showTime) { TimeSheet().environmentObject(model) }
        .sheet(isPresented: $model.showPlace) { PlaceSheet().environmentObject(model) }
        .sheet(isPresented: $model.showHistory) { HistorySheet().environmentObject(model) }
        .alert("无法完成操作", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) { Button("知道了") { model.error = nil } } message: { Text(model.error ?? "") }
        .alert("允许联网识别拍摄地点？", isPresented: $model.showConsent) {
            Button("暂不允许", role: .cancel) {}
            Button("允许并识别") { model.allowLocations() }
        } message: { Text("仅将所选照片的 GPS 坐标发送给 Apple 地理编码服务以获取城市名称，不上传照片。可在设置中撤回许可。") }
    }
    private var sidebar: some View {
        List {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 9) { Image(systemName: "square.stack.3d.up.fill").foregroundStyle(moss); Text("拾光").font(.system(size: 24, weight: .semibold, design: .serif)) }
                Text("PHOTO ARCHIVE").font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(2.8).foregroundStyle(.secondary)
            }.padding(.vertical, 20).listRowSeparator(.hidden)
            Button { model.sourceFilter = nil; model.yearFilter = nil; model.placeFilter = nil } label: { Label("全部照片", systemImage: "square.grid.2x2"); Spacer(); Text("\(model.photos.count)").foregroundStyle(.secondary) }.buttonStyle(.plain).padding(.vertical, 4)
            Section("文件来源") {
                ForEach(model.sources, id: \.self) { source in filterRow(URL(fileURLWithPath: source).lastPathComponent, symbol: "folder", active: model.sourceFilter == source) { model.sourceFilter = model.sourceFilter == source ? nil : source }.help(source) }
                Button { model.chooseSource() } label: { Label("添加文件夹", systemImage: "plus") }.buttonStyle(.plain).foregroundStyle(moss).disabled(model.busy)
            }
            if !model.years.isEmpty { Section("拍摄年份") { ForEach(model.years, id: \.self) { year in filterRow(year, symbol: "calendar", active: model.yearFilter == year) { model.yearFilter = model.yearFilter == year ? nil : year } } } }
            if !model.places.isEmpty { Section("拍摄地点") { ForEach(model.places, id: \.self) { place in filterRow(place, symbol: "mappin", active: model.placeFilter == place) { model.placeFilter = model.placeFilter == place ? nil : place } } } }
        }.listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            VStack(alignment: .leading, spacing: 9) {
                Divider()
                Label("照片留在你的设备", systemImage: "externaldrive.badge.checkmark").font(.caption).foregroundStyle(.secondary)
                Button("重新扫描当前来源") { model.rescan() }.buttonStyle(.link).font(.caption).disabled(model.busy)
            }.padding(16)
        }
    }
    private func filterRow(_ title: String, symbol: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { HStack { Label(title, systemImage: symbol).lineLimit(1); Spacer(); if active { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(moss) } }.padding(.vertical, 3) }.buttonStyle(.plain)
    }
    private var collectionHeader: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) { Text(model.sourceFilter.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "你的照片库").font(.system(size: 28, weight: .semibold)); Text("按时间与地点，让每段记忆各归其位。").font(.subheadline).foregroundStyle(.secondary) }
                Spacer()
                Text("\(model.filtered.count)").font(.system(size: 30, weight: .light, design: .rounded)).foregroundStyle(moss)
            }
            HStack {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("搜索文件名或地点", text: $model.search).textFieldStyle(.plain) }.padding(8).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7)).frame(maxWidth: 300)
                Spacer()
                Text("已选 \(model.selected.count) 张").font(.caption).foregroundStyle(.secondary)
                Button("全选") { model.selection = Set(model.filtered.map(\.id)) }.buttonStyle(.link).font(.caption)
                if !model.selection.isEmpty { Button("清空") { model.selection.removeAll() }.buttonStyle(.link).font(.caption) }
            }
        }.padding(24)
    }
    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            ZStack {
                RoundedRectangle(cornerRadius: 20).fill(moss.opacity(0.07)).frame(width: 154, height: 154).rotationEffect(.degrees(-8))
                RoundedRectangle(cornerRadius: 16).fill(moss.opacity(0.10)).frame(width: 132, height: 144).rotationEffect(.degrees(7))
                Image(systemName: "photo.stack").font(.system(size: 53, weight: .ultraLight)).foregroundStyle(moss)
            }.padding(.bottom, 10)
            Text("把散落的照片，收进时光里").font(.title2.weight(.medium))
            Text("添加一个文件夹，按拍摄年月与城市整理照片。\n支持普通照片和 RAW，所有修改都有迹可循。").font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).lineSpacing(6)
            Button { model.chooseSource() } label: { Label("选择照片文件夹", systemImage: "folder.badge.plus").padding(.horizontal, 14).padding(.vertical, 6) }.buttonStyle(.borderedProminent).disabled(model.busy)
            HStack(spacing: 24) { Label("时间归档", systemImage: "calendar"); Label("城市分类", systemImage: "mappin"); Label("批量校时", systemImage: "clock.arrow.circlepath") }.font(.caption).foregroundStyle(.secondary).padding(.top, 15)
            Spacer(); Spacer()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("照片详情").font(.headline)
                if let photo = model.selected.first {
                    Thumbnail(paths: photo.previewPaths).frame(height: 185).frame(maxWidth: .infinity).background(.quaternary.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: 10))
                    Text(photo.name).font(.headline).textSelection(.enabled)
                    if model.selected.count > 1 { Text("已选择 \(model.selected.count) 张，以下为首张详情").font(.caption).foregroundStyle(.secondary) }
                    detail("拍摄时间", value: photo.capture?.display ?? "未知时间", icon: "calendar")
                    detail("拍摄地点", value: photo.place ?? "未知地点", icon: "mappin.and.ellipse")
                    if let lat = photo.latitude, let lon = photo.longitude { detail("GPS 坐标", value: String(format: "%.5f, %.5f", lat, lon), icon: "location") }
                    detail("文件格式", value: photo.formatLabel + (photo.hasRAW ? " · RAW 原片只读" : ""), icon: "doc")
                    detail("文件大小", value: ByteCountFormatter.string(fromByteCount: photo.bytes, countStyle: .file), icon: "internaldrive")
                    ForEach(photo.files, id: \.path) { member in
                        detail(member.format.uppercased() + " · " + ByteCountFormatter.string(fromByteCount: member.bytes, countStyle: .file), value: member.path, icon: "folder")
                    }
                    if let sidecar = photo.sidecar { detail("XMP · " + ByteCountFormatter.string(fromByteCount: photo.sidecarBytes ?? 0, countStyle: .file), value: sidecar, icon: "doc.badge.gearshape") }
                    if photo.timeDiffers { Text("成员拍摄时间不同，当前采用 " + (photo.captureSource ?? "可用元数据") + " 时间；校时将统一 JPG 与 XMP。").font(.caption).foregroundStyle(.secondary) }
                    if let notice = photo.notice { Text(notice).font(.caption).foregroundStyle(.orange) }
                    if let problem = photo.problem { Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    Divider()
                    Button { model.requestLocations() } label: { Label("通过 GPS 识别城市", systemImage: "location.magnifyingglass") }.disabled(model.busy)
                    Text("手动设置的地点优先，不会被 GPS 识别覆盖。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Image(systemName: "sidebar.right").font(.system(size: 34, weight: .ultraLight)).foregroundStyle(.tertiary).frame(maxWidth: .infinity).padding(.top, 55)
                    Text("选择照片查看拍摄信息").font(.subheadline).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Text("⌘ 点击多选 · ⇧ 点击连续选择\n归档和修改时间前均可预览。").font(.caption).foregroundStyle(.tertiary).lineSpacing(5).padding(.top, 10)
                }
                Spacer()
            }.padding(22)
        }
    }
    private func detail(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) { Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary); Text(value).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
    }
    private func select(_ photo: Photo) {
        if NSEvent.modifierFlags.contains(.shift), let anchor = model.filtered.firstIndex(where: { model.selection.contains($0.id) }), let end = model.filtered.firstIndex(where: { $0.id == photo.id }) { model.selection.formUnion(model.filtered[min(anchor, end)...max(anchor, end)].map(\.id)) }
        else if NSEvent.modifierFlags.contains(.command) { if model.selection.contains(photo.id) { model.selection.remove(photo.id) } else { model.selection.insert(photo.id) } }
        else { model.selection = [photo.id] }
    }
}
struct PhotoTile: View {
    let photo: Photo
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Thumbnail(paths: photo.previewPaths).frame(height: 137).frame(maxWidth: .infinity).background(.quaternary.opacity(0.4)).clipped()
                if selected { Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, moss).font(.title3).padding(8) }
                if photo.hasRAW { Text(photo.isPair ? "JPG + CR2" : "RAW").font(.system(size: 9, weight: .bold, design: .monospaced)).padding(5).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4)).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading).padding(8) }
            }.clipShape(RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? moss : Color.clear, lineWidth: 3))
            Text(photo.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            HStack(spacing: 4) { Image(systemName: photo.problem == nil ? "mappin" : "exclamationmark.triangle"); Text(photo.problem == nil ? photo.place ?? "未知地点" : "需检查") }.font(.system(size: 10)).foregroundStyle(photo.problem == nil ? Color.secondary : .orange).lineLimit(1)
            Text(photo.capture.map { String($0.value.prefix(10)).replacingOccurrences(of: ":", with: ".") } ?? "未知时间").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
        }.padding(6).background(selected ? moss.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 10)).contentShape(Rectangle())
    }
}
actor ThumbnailCache {
    static let shared = ThumbnailCache()
    let cache = NSCache<NSString, NSImage>()
    init() { cache.totalCostLimit = 96 * 1024 * 1024; cache.countLimit = 500 }
    func image(_ path: String) -> NSImage? {
        if Task.isCancelled { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let key = (path + String(describing: attrs?[.modificationDate])) as NSString
        if let image = cache.object(forKey: key) { return image }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 480, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        let result = NSImage(cgImage: image, size: .zero); cache.setObject(result, forKey: key, cost: image.bytesPerRow * image.height); return result
    }
}
struct Thumbnail: View {
    let paths: [String]
    @ViewState private var image: NSImage?
    var body: some View {
        ZStack { if let image { Image(nsImage: image).resizable().scaledToFit() } else { Image(systemName: "photo").font(.system(size: 28, weight: .ultraLight)).foregroundStyle(.tertiary) } }
            .task(id: paths) {
                image = nil
                for path in paths {
                    if Task.isCancelled { return }
                    if let loaded = await ThumbnailCache.shared.image(path) { if !Task.isCancelled { image = loaded }; return }
                }
            }
    }
}
