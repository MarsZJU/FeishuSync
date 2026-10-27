import AppKit
import SwiftUI

@MainActor final class AppModel: ObservableObject {
    @Published var settings = Settings()
    @Published var busy = false
    @Published var status = "等待同步"
    @Published var persistenceError: String?
    private var timer: Timer?
    private var lastAttempt = Date.distantPast
    private var wakeObserver: NSObjectProtocol?
    private let configURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FeishuSync/settings.json")
    init() {
        if FileManager.default.fileExists(atPath: configURL.path) {
            do { settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: configURL)) }
            catch { persistenceError = "配置读取失败；为防覆盖，自动同步已暂停。\(error.localizedDescription)"; settings.paused = true }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, !self.settings.paused, Date().timeIntervalSince(self.lastAttempt) > 60 else { return }
                self.sync()
            }
        }
    }
    func save() {
        guard persistenceError == nil else { return }
        do {
            try FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(settings).write(to: configURL, options: .atomic)
        } catch { persistenceError = "配置保存失败：\(error.localizedDescription)"; settings.paused = true }
    }
    func tick() {
        guard !settings.paused, persistenceError == nil, Date().timeIntervalSince(lastAttempt) >= Double(max(5, settings.intervalMinutes) * 60) else { return }
        sync()
    }
    func togglePause() { settings.paused.toggle(); save() }
    func sync(locationID: UUID? = nil, id: UUID? = nil) {
        guard !busy, persistenceError == nil else { return }
        let entries = settings.jobs(locationID: locationID, documentID: id)
        guard !entries.isEmpty else { status = "没有启用的文档"; return }
        busy = true; lastAttempt = Date(); status = "正在同步…"
        let cli = settings.cliPath
        Task {
            var failures = 0
            for job in entries {
                let entry = job.entry, destination = job.destination
                status = "正在同步：\(entry.title)"
                // All process/network/disk work stays off the main actor.
                let outcome: Result<SyncResult, Error> = await Task.detached(priority: .utility) {
                    Result { try SyncEngine(run: CLI(cli).run).sync(entry, destination: destination) }
                }.value
                if let group = settings.locations.firstIndex(where: { $0.id == job.locationID }),
                   let index = settings.locations[group].documents.firstIndex(where: { $0.id == entry.id }) {
                    switch outcome {
                    case .success(let result):
                        settings.locations[group].documents[index].title = result.title
                        settings.locations[group].documents[index].status = result.message
                        settings.locations[group].documents[index].lastSuccess = Date()
                        settings.locations[group].documents[index].lastPath = result.path
                    case .failure(let error):
                        failures += 1; settings.locations[group].documents[index].status = "失败：" + error.localizedDescription
                    }
                }
                save()
            }
            busy = false
            status = failures == 0 ? "同步完成 · \(entries.count) 篇" : "\(failures) 篇同步失败 · 请打开设置查看"
        }
    }
    func openFolder(_ path: String) { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    func reveal(_ entry: DocumentEntry) {
        if let path = entry.lastPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }
    func chooseFolder(locationID: UUID? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        if let group = settings.locations.first(where: { $0.id == locationID }) { panel.directoryURL = URL(fileURLWithPath: group.destination) }
        if panel.runModal() == .OK, let url = panel.url {
            if let index = settings.locations.firstIndex(where: { $0.id == locationID }) {
                guard settings.locations[index].destination != url.path else { return }
                settings.locations[index].destination = url.path
                for doc in settings.locations[index].documents.indices {
                    settings.locations[index].documents[doc].lastPath = nil
                    settings.locations[index].documents[doc].lastSuccess = nil
                    settings.locations[index].documents[doc].status = "备份位置已更改，等待同步"
                }
            } else {
                settings.locations.append(BackupLocation(destination: url.path))
            }
            save()
        }
    }

}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State var validationError = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath.icloud").font(.largeTitle).foregroundStyle(.blue)
                VStack(alignment: .leading) {
                    Text("飞书备份").font(.title2.bold())
                    Text("飞书 → 本地 / iCloud · 单向保存").foregroundStyle(.secondary)
                }
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                Button("立即同步全部") { model.sync() }.disabled(model.busy)
            }
            Text(model.status).font(.callout)
            if let error = model.persistenceError { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            GroupBox("自动同步") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Toggle("启用自动同步", isOn: Binding(get: { !model.settings.paused }, set: { model.settings.paused = !$0; model.save() }))
                        Spacer()
                        Text("每")
                        Picker("间隔", selection: $model.settings.intervalMinutes) {
                            ForEach([5, 30], id: \.self) { Text("\($0) 分钟").tag($0) }
                        }.labelsHidden().frame(width: 130).onChange(of: model.settings.intervalMinutes) { _ in model.save() }
                    }
                    Text("仅在应用运行且 Mac 清醒、联网时同步；唤醒后补同步。不强制常醒。").font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }.disabled(model.busy)
            HStack {
                Text("备份位置与文档").font(.headline)
                Spacer()
                Button("添加备份位置…") { model.chooseFolder() }.disabled(model.busy)
            }
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach($model.settings.locations) { $location in
                        LocationView(model: model, location: $location)
                    }
                }.padding(2)
            }
            Text("自动：纯文本导出 Markdown，含图片导出 PDF。").font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("CLI 与登录") {
                TextField("CLI 可执行文件路径", text: $model.settings.cliPath).onChange(of: model.settings.cliPath) { _ in model.save() }.disabled(model.busy)
                Text("同步正常无需操作。登录过期时，运行下方命令完成授权，再重新同步。")
                Text("/opt/homebrew/bin/lark-cli auth login").font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }.font(.caption)
        }.padding(20).frame(minWidth: 760, minHeight: 650)
    }
}

struct LocationView: View {
    @ObservedObject var model: AppModel
    @Binding var location: BackupLocation
    @State private var expanded = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                Button {
                    expanded.toggle()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption).frame(width: 12)
                        Label(location.label, systemImage: "folder").font(.headline)
                        Spacer()
                        Text("\(location.documents.count) 篇文档").font(.caption).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(expanded ? "收起" : "展开")备份位置：\(location.label)，\(location.documents.count) 篇文档")
                .help(location.destination)
                if expanded {
                    Text(location.destination).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("同步此位置") { model.sync(locationID: location.id) }
                        Button("更改位置…") { model.chooseFolder(locationID: location.id) }
                        Button("打开") { model.openFolder(location.destination) }
                        Spacer()
                        Button("移除位置") { model.settings.locations.removeAll { $0.id == location.id }; model.save() }
                    }
                    ForEach($location.documents) { $entry in
                        DocumentView(model: model, entry: $entry, locationID: location.id, remove: {
                            location.documents.removeAll { $0.id == entry.id }; model.save()
                        })
                    }
                    if location.documents.isEmpty { Text("尚未添加文档").foregroundStyle(.secondary) }
                    Button("添加文档") { location.documents.append(DocumentEntry(url: "")); model.save() }
                }
            }.padding(8)
        }.disabled(model.busy)
    }
}
struct DocumentView: View {
    @ObservedObject var model: AppModel
    @Binding var entry: DocumentEntry
    let locationID: UUID
    let remove: () -> Void
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("启用", isOn: $entry.enabled).labelsHidden().onChange(of: entry.enabled) { _ in model.save() }
                    Text(entry.title).font(.headline).lineLimit(1)
                    Spacer()
                    Button("同步") { model.sync(locationID: locationID, id: entry.id) }.disabled(!entry.enabled || entry.url.isEmpty)
                    Button("查看文件") { model.reveal(entry) }.disabled(entry.lastPath == nil)
                    Button("移除", action: remove)
                }
                TextField("粘贴飞书文档 / Wiki 页面链接", text: $entry.url)
                    .textFieldStyle(.roundedBorder).onChange(of: entry.url) { _ in
                        entry.lastPath = nil; entry.lastSuccess = nil; entry.title = "尚未读取标题"; entry.status = "链接已修改，等待同步"; model.save()
                    }
                HStack {
                    Picker("导出格式", selection: $entry.mode) { ForEach(ExportMode.allCases, id: \.self) { Text($0.label).tag($0) } }
                        .frame(width: 285).onChange(of: entry.mode) { _ in model.save() }
                    Spacer()
                    if let date = entry.lastSuccess { Text("上次成功：" + date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary) }
                }
                Text(entry.status).font(.caption).foregroundStyle(entry.status.hasPrefix("失败") ? .red : .secondary).textSelection(.enabled)
            }.padding(5)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let model = AppModel()
    var item: NSStatusItem!
    var window: NSWindow?
    var menuTimer: Timer?
    var menuIsOpen = false
    func menuWillOpen(_ menu: NSMenu) { menuIsOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuIsOpen = false }
    func applicationDidFinishLaunching(_ notification: Notification) {
        // One app instance owns the scheduler; a second launch reveals the first instance.
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "org.feishusync.desktop")
        if let other = peers.first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            other.activate(options: [.activateAllWindows]); NSApp.terminate(nil); return
        }
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath.icloud", accessibilityDescription: "飞书备份")
        // Standard responder actions make copy/paste/select-all work in native text fields.
        let main = NSMenu()
        let applicationMenu = NSMenu(); let appRoot = NSMenuItem(); appRoot.submenu = applicationMenu; main.addItem(appRoot)
        let close = NSMenuItem(title: "关闭设置", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        applicationMenu.addItem(close)
        let quitItem = NSMenuItem(title: "退出飞书备份", action: #selector(quit), keyEquivalent: "q"); quitItem.target = self; applicationMenu.addItem(quitItem)
        let edit = NSMenu(title: "编辑"); let editRoot = NSMenuItem(title: "编辑", action: nil, keyEquivalent: ""); editRoot.submenu = edit; main.addItem(editRoot)
        for (name, selector, key) in [("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a"), ("撤销", "undo:", "z")] {
            edit.addItem(NSMenuItem(title: name, action: Selector(selector), keyEquivalent: key))
        }
        NSApp.mainMenu = main
        rebuildMenu()
        menuTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.rebuildMenu() } }
        showSettings()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func rebuildMenu() {
        if menuIsOpen { return }
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector?, enabled: Bool = true, object: Any? = nil) {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self; entry.isEnabled = enabled; entry.representedObject = object; menu.addItem(entry)
        }
        menu.autoenablesItems = false
        add("设置与同步详情…", #selector(showSettings))
        menu.addItem(.separator())
        add(model.status, nil, enabled: false)
        add(model.settings.paused ? "自动同步已暂停" : "自动同步：每 \(model.settings.intervalMinutes) 分钟", nil, enabled: false)
        menu.addItem(.separator())
        add("立即同步全部", #selector(syncAll), enabled: !model.busy)
        for location in model.settings.locations {
            let submenu = NSMenu(title: location.label)
            submenu.autoenablesItems = false
            func child(_ title: String, _ action: Selector?, _ object: Any?, _ enabled: Bool = true) {
                let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
                entry.target = self; entry.representedObject = object; entry.isEnabled = enabled; submenu.addItem(entry)
            }
            child(location.destination, nil, nil, false)
            child("打开此备份位置", #selector(openFolder(_:)), location.destination)
            child("同步此位置全部文档", #selector(syncLocation(_:)), location.id.uuidString, !model.busy)
            submenu.addItem(.separator())
            for doc in location.documents where doc.enabled {
                child("同步：" + (doc.title == "尚未读取标题" ? String(doc.url.suffix(32)) : doc.title), #selector(syncOne(_:)), [location.id.uuidString, doc.id.uuidString], !model.busy)
            }
            let group = NSMenuItem(title: "备份位置：" + location.label, action: nil, keyEquivalent: "")
            group.submenu = submenu; menu.addItem(group)
        }
        add(model.settings.paused ? "恢复自动同步" : "暂停自动同步", #selector(pauseSync))
        add("飞书登录说明…", #selector(loginHelp))
        menu.addItem(.separator())
        add("退出飞书备份", #selector(quit))
        item.menu = menu
        item.button?.toolTip = "飞书备份 · " + model.status
    }
    @objc func syncAll() { model.sync() }
    @objc func syncOne(_ sender: NSMenuItem) {
        if let ids = sender.representedObject as? [String], ids.count == 2, let group = UUID(uuidString: ids[0]), let doc = UUID(uuidString: ids[1]) { model.sync(locationID: group, id: doc) }
    }
    @objc func syncLocation(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? String, let id = UUID(uuidString: value) { model.sync(locationID: id) }
    }
    @objc func pauseSync() { model.togglePause(); rebuildMenu() }
    @objc func openFolder(_ sender: NSMenuItem) { if let path = sender.representedObject as? String { model.openFolder(path) } }
    @objc func showSettings() {
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 720), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            created.title = "飞书备份设置"; created.isReleasedWhenClosed = false
            created.contentView = NSHostingView(rootView: SettingsView(model: model))
            created.center(); window = created
        }
        NSApp.activate(ignoringOtherApps: true); window?.makeKeyAndOrderFront(nil)
    }
    @objc func loginHelp() {
        showSettings()
        let alert = NSAlert(); alert.messageText = "飞书登录"
        alert.informativeText = "同步正常无需重新登录。登录过期时，在终端运行：\n\n/opt/homebrew/bin/lark-cli auth login\n\n完成浏览器授权后，回到应用重新同步。"
        alert.addButton(withTitle: "知道了"); alert.runModal()
    }
    @objc func quit() {
        if model.busy {
            let alert = NSAlert(); alert.messageText = "正在同步"; alert.informativeText = "请等待本次同步结束后退出，旧备份始终保留。"; alert.runModal(); return
        }
        NSApp.terminate(nil)
    }
}

@main struct FeishuSyncApplication {
    @MainActor static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { application.run() }
    }
}
