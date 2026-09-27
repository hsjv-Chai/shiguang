import SwiftUI
import PhotoCore

struct PlanSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let batch: OperationBatch
    var eligible: Int { batch.items.filter { $0.status == "pending" }.count }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("\(batch.title)预览").font(.title2.bold())
            Text(batch.kind == "archive" ? "将按照片组移动 JPG、CR2 及配套 XMP，按 年 / 月 / 城市 归档。重名时整组统一编号；同盘快速移动；跨盘复制校验通过后删除源文件。" : "成组照片同步校正 JPG 和 XMP；RAW 原片仅检查状态、不改写。确认后为待修改文件保存完整备份并校验。").foregroundStyle(.secondary)
            HStack { Label("\(eligible) 张可执行", systemImage: "checkmark.circle"); Text("\(batch.items.count - eligible) 张跳过或有异常").foregroundStyle(.secondary); Spacer() }.font(.caption)
            List(batch.items) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(item.photo.name).bold(); Spacer(); Text(localizedStatus(item.status)).foregroundStyle(item.status == "blocked" ? .orange : .secondary) }
                    Text(item.photo.formatLabel).font(.caption).foregroundStyle(.secondary)
                    if let error = item.error { Text(error).font(.caption).foregroundStyle(.orange) }
                    else if batch.kind == "archive" { ForEach(item.files.indices, id: \.self) { j in Text("→ " + item.files[j].destination).font(.caption).textSelection(.enabled) } }
                    else { Text("\(item.photo.capture?.display ?? "未知时间") → \(item.newCapture?.display ?? "")").font(.caption).textSelection(.enabled) }
                    ForEach(item.files.indices, id: \.self) { j in
                        let file = item.files[j]
                        Text((file.state == "readonly" ? "只读校验：" : batch.kind == "archive" ? "移动：" : (file.timeEdit.map { $0.role == "new" } ?? (file.before == nil)) ? "创建：" : "写入：") + file.source).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }.padding(.vertical, 6)
            }.listStyle(.inset).frame(minHeight: 280)
            if batch.kind == "time" { HStack { Text("备份：\(model.backupPath)").font(.caption).foregroundStyle(.secondary).lineLimit(2); Button("更改…") { model.chooseBackup() } } }
            HStack { Button("取消", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction); Spacer(); Button("确认\(batch.title) · \(eligible) 张") { dismiss(); model.execute(batch) }.buttonStyle(.borderedProminent).disabled(eligible == 0).keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 840, height: 580)
    }
}
struct TimeSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ViewState var mode = 0
    @ViewState var hours = "0"
    @ViewState var minutes = "0"
    @ViewState var seconds = "0"
    @ViewState var direction = 1
    @ViewState var timestamp = "2026:01:01 12:00:00"
    @ViewState var day = "2026:01:01"
    var edit: TimeEdit? {
        if mode == 0 {
            guard let h = Int(hours), let m = Int(minutes), let s = Int(seconds), (0...876000).contains(h), (0...59).contains(m), (0...59).contains(s) else { return nil }
            return .shift(direction * (h * 3600 + m * 60 + s))
        }
        if mode == 1 { return CaptureTime.parse(timestamp) == nil ? nil : .set(timestamp) }
        return CaptureTime.parse(day + " 00:00:00") == nil ? nil : .dateOnly(day)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("批量调整拍摄时间").font(.title2.bold())
            Text("已选择 \(model.selected.count) 张照片 · 修改后不会自动归档").foregroundStyle(.secondary)
            Picker("方式", selection: $mode) { Text("整体偏移").tag(0); Text("统一时间").tag(1); Text("仅替换日期").tag(2) }.pickerStyle(.segmented)
            if mode == 0 {
                HStack { Picker("方向", selection: $direction) { Text("推迟").tag(1); Text("提前").tag(-1) }.frame(width: 155); TextField("小时", text: $hours).frame(width: 80); Text("小时"); TextField("分钟", text: $minutes).frame(width: 45); Text("分"); TextField("秒", text: $seconds).frame(width: 45); Text("秒") }
                Text("例如提前 8 小时可修正相机时差，照片之间的时间间隔保持不变。").font(.caption).foregroundStyle(.secondary)
            } else if mode == 1 { TextField("yyyy:MM:dd HH:mm:ss", text: $timestamp).textFieldStyle(.roundedBorder); Text("格式：2026:09:25 14:30:00；保留每张照片原有时区。").font(.caption).foregroundStyle(.secondary) }
            else { TextField("yyyy:MM:dd", text: $day).textFieldStyle(.roundedBorder); Text("保留每张照片原有的时分秒和时区。缺少原时间的照片会跳过。").font(.caption).foregroundStyle(.secondary) }
            if edit == nil { Text("请检查日期格式或时间偏移范围。").font(.caption).foregroundStyle(.orange) }
            Divider()
            Label("先预览变化，再写入文件；原片备份可用于撤销。", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.secondary)
            HStack { Button("取消", role: .cancel) { dismiss() }; Spacer(); Button("生成预览") { if let edit { model.previewTime(edit) } }.buttonStyle(.borderedProminent).disabled(edit == nil).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 630)
        .onAppear { timestamp = model.selected.first?.capture?.value ?? CaptureTime.formatter().string(from: Date()); day = String(timestamp.prefix(10)) }
    }
}
struct PlaceSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ViewState private var place = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("设置拍摄地点").font(.title2.bold())
            Text("为 \(model.selected.count) 张照片指定城市，用于筛选与归档。").foregroundStyle(.secondary)
            TextField("例如：苏州 · 江苏 · 中国", text: $place).textFieldStyle(.roundedBorder)
            Text("地点只保存到本地照片索引，不会改写照片 GPS。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("通过 GPS 识别…") { dismiss(); model.requestLocations() }; Spacer(); Button("取消", role: .cancel) { dismiss() }; Button("保存地点") { model.setPlace(place) }.buttonStyle(.borderedProminent).disabled(place.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).keyboardShortcut(.defaultAction) }
        }.padding(28).frame(width: 560)
    }
}
struct HistorySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @ViewState private var clean: OperationBatch?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("操作历史").font(.title2.bold()); Spacer(); Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("可继续失败或中断的批次；撤销会检查文件是否被外部修改。后续操作请先撤销，再撤销更早的批次。").font(.caption).foregroundStyle(.secondary)
            if model.history.isEmpty { ContentUnavailableView("还没有操作记录", systemImage: "clock", description: Text("归档与时间修改记录会保存在这里。")) }
            else { List(model.history) { batch in
                VStack(alignment: .leading, spacing: 10) {
                    HStack { Text(batch.title).font(.headline); Text(batch.created.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary); Spacer(); Text(localizedStatus(batch.status)).font(.caption) }
                    Text("\(batch.done) / \(batch.items.count) 张已完成").font(.caption).foregroundStyle(.secondary)
                    ForEach(batch.items.filter { $0.error != nil }) { item in Text("\(item.photo.name)：\(item.error ?? "")").font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                    HStack {
                        if ["partial", "cancelled", "interrupted", "running"].contains(batch.status) { Button("继续 / 重试") { model.execute(batch) }.disabled(model.busy) }
                        if batch.status != "undone" { Button(batch.status == "undoFailed" ? "继续撤销" : "撤销此批次") { model.execute(batch, undo: true) }.disabled(model.busy) }
                        if batch.status == "undone", batch.items.contains(where: { $0.files.contains(where: { $0.backup != nil }) }) { Button("清理此批次备份…") { clean = batch }.disabled(model.busy) }
                    }.controlSize(.small).buttonStyle(.borderless)
                }.padding(.vertical, 9).accessibilityElement(children: .contain)
            }.listStyle(.inset) }
            if model.busy { HStack { ProgressView(value: model.fraction); Text(model.status).font(.caption); Button("停止") { model.cancel() } } }
        }.padding(24).frame(width: 830, height: 590)
        .alert("清理已经撤销的原片备份？", isPresented: Binding(get: { clean != nil }, set: { if !$0 { clean = nil } })) { Button("取消", role: .cancel) { clean = nil }; Button("清理备份", role: .destructive) { if let batch = clean { model.cleanBackups(batch) }; clean = nil } } message: { Text("只删除这个已撤销批次的备份文件，照片原件不受影响。") }
    }
}
