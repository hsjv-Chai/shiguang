import SwiftUI
import AppKit
import PhotoCore

@main struct PhotoArchiveApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("拾光 · 照片归档") { ContentView().environmentObject(model).frame(minWidth: 1080, minHeight: 700).onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancel() } }
            .defaultSize(width: 1360, height: 860)
            .commands {
                CommandGroup(replacing: .newItem) { Button("添加照片文件夹…") { model.chooseSource() }.keyboardShortcut("o").disabled(model.busy) }
                CommandGroup(after: .pasteboard) { Button("全选照片") { model.selection = Set(model.filtered.map(\.id)) }.keyboardShortcut("a"); Button("取消选择") { model.selection.removeAll() }.keyboardShortcut("a", modifiers: [.command, .shift]) }
            }
        Settings { VStack(alignment: .leading, spacing: 16) {
            Text("备份与隐私").font(.title2.bold())
            Text("时间修改前会保存完整原片。移动归档会记录原路径。")
            Text(model.backupPath).font(.caption).textSelection(.enabled)
            Button("更改备份目录…") { model.chooseBackup() }.disabled(model.busy)
            Divider()
            Button("撤回 GPS 联网许可") { UserDefaults.standard.set(false, forKey: "geocodeConsent") }.disabled(model.busy)
            Text("下次识别地点时将重新询问。照片不会上传，手动地点不修改 GPS。").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(width: 460) }
    }
}
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        // Set the running Dock tile explicitly: Launch Services may retain a
        // generic icon when this locally built bundle is replaced in place.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            app.applicationIconImage = icon
        }
        app.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
