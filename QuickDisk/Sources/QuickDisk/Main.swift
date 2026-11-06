import SwiftUI
import AppKit

struct QuickDiskApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(QuickDiskAppDelegate.self) private var appDelegate
    init() {
        UserDefaults.standard.register(defaults: ["depth": 6, "theme": "dark", "watch": false, "cacheEnabled": true, "historyEnabled": false])
    }
    var body: some Scene {
        WindowGroup { ContentView().environmentObject(model).frame(minWidth: 1000, minHeight: 680).onOpenURL { url in if url.isFileURL { model.rememberAccess(for: url); model.scan(url) } } }
        .windowStyle(.hiddenTitleBar).defaultSize(width: 1250, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { Button("Сканировать папку…") { model.pickFolder() }.keyboardShortcut("o"); Button("Экспорт отчёта PDF…") { model.exportReport() }.keyboardShortcut("e", modifiers: [.command, .shift]); Button("Повторить сканирование") { if let url = model.sourceURL { model.scan(url) } }.keyboardShortcut("r"); Button("Назад") { model.goBack() }.keyboardShortcut("[", modifiers: .command).disabled(!model.canBack); Button("Вперёд") { model.goForward() }.keyboardShortcut("]", modifiers: .command).disabled(!model.canForward) }
        }
        Settings { SettingsView().environmentObject(model) }
    }
}
final class QuickDiskAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let iconURL = Bundle.main.url(forResource: "QuickDisk", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
    }
}
@main struct QuickDiskEntry {
    static func main() {
        if CommandLine.arguments.contains("--self-test") { do { try SelfCheck.run(); exit(0) } catch { fputs("FAIL: \(error)\n", stderr); exit(1) } }
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "scan" { CLI.run(); exit(0) }
        QuickDiskApp.main()
    }
}
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("depth") var depth = 6; @AppStorage("theme") var theme = "dark"
    @State private var kind = "Все"; @State private var minimum = 0
    @State private var sheet: String?; @State private var errors = false; @State private var sort = "Размер"
    var filtered: [DiskNode] {
        guard let current = model.current else { return [] }
        let floor: Int64 = minimum == 1 ? 10_000_000 : minimum == 2 ? 100_000_000 : minimum == 3 ? 1_000_000_000 : 0
        return current.children.filter { (kind == "Все" || (kind == "Папки" ? $0.isDirectory : !$0.isDirectory)) && $0.bytes >= floor }.sorted {
            if sort == "Имя" { return $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if sort == "Дата" { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            return $0.bytes > $1.bytes
        }
    }
    var breadcrumbs: [DiskNode] { guard let current = model.current else { return [] }; var nodes: [DiskNode] = []; var cursor: DiskNode? = current; while let node = cursor { nodes.append(node); cursor = node.parent }; return nodes.reversed() }
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.busy { progress }
            if let current = model.current { explorer(current).disabled(model.busy) } else { home }
            Divider()
            footer
        }
        .background(theme == "dark" ? Color(red: 0.065, green: 0.075, blue: 0.12) : Color(nsColor: .windowBackgroundColor))
        .preferredColorScheme(theme == "dark" ? .dark : .light)
        .sheet(item: Binding(get: { sheet.map(SheetID.init) }, set: { sheet = $0?.id })) { item in
            switch item.id {
            case "remote": RemoteView().environmentObject(model)
            case "duplicates": DuplicateView().environmentObject(model)
            case "history": SnapshotHistoryView().environmentObject(model)
            default: SettingsView().environmentObject(model)
            }
        }
        .alert("QuickDisk", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) { Button("Понятно") { model.message = nil } } message: { Text(model.message ?? "") }
        .sheet(isPresented: $errors) { VStack(alignment: .leading, spacing: 16) { Text("Ошибки и ограничения доступа").font(.title2); Text("Без разрешений macOS некоторые каталоги недоступны. Пропуски не означают, что папки пусты. Показаны первые 200 ошибок.").foregroundStyle(.secondary); ScrollView { Text(model.result?.errors.joined(separator: "\n") ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }; Button("Закрыть") { errors = false } }.padding(24).frame(width: 800, height: 500) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in if let url { DispatchQueue.main.async { model.rememberAccess(for: url); model.scan(url) } } }; return true
        }
    }
    var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "bolt.circle.fill").font(.system(size: 29)).foregroundStyle(.orange)
            Text("QuickDisk").font(.system(size: 23, weight: .bold, design: .rounded))
            Divider().frame(height: 22)
            Button { model.home() } label: { Image(systemName: "square.grid.2x2") }.help("Диски")
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!model.canBack)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }.disabled(!model.canForward)
            Spacer()
            Button { model.pickFolder() } label: { Label("Папка", systemImage: "folder.badge.plus") }.disabled(model.busy)
            Button { sheet = "history" } label: { Label("Изменения", systemImage: "clock.arrow.circlepath") }.disabled(model.result?.root.remote ?? true).help("Сравнить сохранённые снимки сканирования")
            Button { if let url = model.sourceURL { model.scan(url) } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.sourceURL == nil || model.busy).help("Повторить сканирование")
            Button { sheet = "settings" } label: { Image(systemName: "gearshape") }
        }.buttonStyle(.borderless).padding(.horizontal, 22).padding(.vertical, 17)
    }
    var progress: some View {
        HStack(spacing: 16) { ProgressView().controlSize(.small); VStack(alignment: .leading) {
            Text(model.progress.map { "\($0.files.formatted()) файлов · \(humanSize($0.bytes)) · ошибок: \($0.errors)" } ?? model.status).font(.callout)
            if let path = model.progress?.path { Text(path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
        }; Spacer(); Button("Остановить") { model.cancel() } }.padding(14).background(.indigo.opacity(0.16))
    }
    var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) { Text("Место для важного.").font(.system(size: 38, weight: .bold, design: .rounded)); Text("Найдите крупные файлы и папки на диске и делайте с ними что пожелаете, решать вам.").font(.title3).foregroundStyle(.secondary) }.padding(.vertical, 18)
                Text("ДИСКИ").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(model.volumes, id: \.path) { url in volumeCard(url) }
                HStack(spacing: 16) {
                    homeCard("Любая папка", "Выберите папку или перетащите её в окно", "folder.fill") { model.pickFolder() }
                    homeCard("Сервер и облако", "SSH · S3 · Drive · Dropbox через rclone", "network") { sheet = "remote" }
                }
                if !model.recent.isEmpty {
                    Text("НЕДАВНИЕ СКАНИРОВАНИЯ").font(.caption.bold()).foregroundStyle(.secondary)
                    ForEach(model.recent, id: \.self) { path in HStack { Image(systemName: "clock").foregroundStyle(.secondary); Button(path) { model.scanRecent(path) }.buttonStyle(.plain); Spacer(); Image(systemName: "arrow.up.right") }.padding(10).background(.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8)) }
                }
                Text("Сканирование читает метаданные файлов; их содержимое не открывается.").font(.caption).foregroundStyle(.secondary)
            }.padding(32).frame(maxWidth: 1200)
        }
    }
    func homeCard(_ name: String, _ description: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { VStack(alignment: .leading, spacing: 12) { Image(systemName: icon).font(.title).foregroundStyle(.orange); Text(name).font(.headline); Text(description).font(.caption).foregroundStyle(.secondary).frame(height: 32, alignment: .top) }.frame(maxWidth: .infinity, alignment: .leading).padding(22).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16)) }.buttonStyle(.plain).disabled(model.busy)
    }
    func volumeCard(_ url: URL) -> some View {
        let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey])
        let capacity = Int64(v?.volumeTotalCapacity ?? 0); let free = Int64(v?.volumeAvailableCapacity ?? 0)
        return HStack(spacing: 20) {
            Image(systemName: "internaldrive.fill").font(.system(size: 34)).foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 6) { Text(v?.volumeName ?? url.lastPathComponent).font(.title3.bold()); Text("\(humanSize(capacity)) · \(url.path)").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            VStack(alignment: .trailing, spacing: 8) { ProgressView(value: Double(max(0, capacity - free)), total: Double(max(1, capacity))).tint(.orange).frame(width: 220); Text("Свободно \(humanSize(free))").font(.caption) }
            Button("Сканировать") { model.scanVolume(url) }.buttonStyle(.borderedProminent).tint(.indigo).disabled(model.busy)
        }.padding(22).background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }
    func explorer(_ current: DiskNode) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) { ForEach(breadcrumbs.indices, id: \.self) { index in let node = breadcrumbs[index]; if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }; Button(node.name.isEmpty ? "/" : node.name) { model.navigate(node) }.buttonStyle(.plain).font(.system(.caption, design: .rounded, weight: node.id == current.id ? .semibold : .regular)).foregroundStyle(node.id == current.id ? .primary : .secondary).lineLimit(1) }; Spacer(); if current.remote { Text("Удалённый источник · только просмотр").font(.caption).foregroundStyle(.orange) }; Button { current.loadAllChildren(); model.exportReport(root: current, depth: depth, nodes: filtered) } label: { Label("Экспорт PDF", systemImage: "square.and.arrow.up") } }.padding(.horizontal, 22).padding(.vertical, 12)
            if let root = model.result?.root, !root.remote, !model.busy { VolumeSummary(root: root) }
            HSplitView {
                VStack {
                    let volume = chartVolume(for: current)
                    DiskChart(root: current, depth: depth, volumeCapacity: volume.0, volumeFree: volume.1, isScanning: model.busy) { node in open(node) }.frame(minWidth: 440)
                    HStack { Text("\(current.count.formatted()) файлов"); Spacer(); Text("На диске \(humanSize(current.bytes)) · размер \(humanSize(current.logical))") }.font(.caption).foregroundStyle(.secondary).padding()
                }
                VStack(alignment: .leading, spacing: 12) {
                    HStack { Text(current.name).font(.title2.bold()).lineLimit(1); Spacer(); Text(humanSize(current.bytes)).font(.title2.bold()).foregroundStyle(.orange) }
                    HStack {
                        Picker("Вид", selection: $kind) { ForEach(["Все", "Папки", "Файлы"], id: \.self) { Text($0) } }.labelsHidden()
                        Picker("От", selection: $minimum) { Text("Любой размер").tag(0); Text("10 MB+").tag(1); Text("100 MB+").tag(2); Text("1 GB+").tag(3) }.labelsHidden()
                        Picker("Порядок", selection: $sort) { ForEach(["Размер", "Имя", "Дата"], id: \.self) { Text($0) } }.labelsHidden()
                    }.font(.caption)
                    List {
                        ForEach(filtered) { node in
                        HStack(spacing: 10) {
                            Image(systemName: node.issue != nil ? "lock.trianglebadge.exclamationmark" : node.isDirectory ? "folder.fill" : "doc.fill").foregroundStyle(node.issue != nil ? .orange : .indigo).frame(width: 21)
                            Text(node.name).lineLimit(1)
                            Spacer(); Text(humanSize(node.bytes)).monospacedDigit().foregroundStyle(.secondary)
                        }.padding(.vertical, 5).contentShape(Rectangle()).onTapGesture(count: 2) { open(node) }
                        .contextMenu { Button("Открыть") { open(node) }; if !node.remote { Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) }; Button("Быстрый просмотр") { _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/qlmanage"), arguments: ["-p", node.id]) } }; Button("Скопировать путь") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(node.id, forType: .string) } }
                        .draggable(node.id)
                        }
                        if current.hasMoreChildren {
                            Text("Кэш загружается партиями; порядок применяется к уже загруженным элементам.").font(.caption2).foregroundStyle(.secondary)
                            Button("Показать ещё · загружено \(current.childrenLoadedCount) из \(current.childrenTotalCount)") { model.loadMoreChildren(current) }.frame(maxWidth: .infinity, alignment: .center)
                        }
                    }.listStyle(.plain)
                    Text("Двойной щелчок — открыть папку · контекстное меню — Finder и предпросмотр").font(.caption2).foregroundStyle(.secondary)
                }.padding(20).frame(minWidth: 380, idealWidth: 480)
            }
        }
    }
    func open(_ node: DiskNode) { if node.isDirectory { model.navigate(node) } else if !node.remote { NSWorkspace.shared.activateFileViewerSelecting([node.url]) } }
    var footer: some View {
        HStack(spacing: 16) {
            Label("Только просмотр", systemImage: "eye").font(.caption).foregroundStyle(.orange)
            Text(model.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            if !(model.result?.errors.isEmpty ?? true) { Button { errors = true } label: { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) } }
            Text("v0.4.1").font(.caption2).foregroundStyle(.tertiary)
        }.padding(14)
    }
    func chartVolume(for current: DiskNode) -> (Int64?, Int64?) {
        guard let scannedRoot = model.result?.root, scannedRoot.id == current.id, !scannedRoot.remote else { return (nil, nil) }
        let values = try? scannedRoot.url.resourceValues(forKeys: [.volumeURLKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        guard values?.volume?.standardizedFileURL.path == scannedRoot.url.standardizedFileURL.path else { return (nil, nil) }
        return (Int64(values?.volumeTotalCapacity ?? 0), Int64(values?.volumeAvailableCapacity ?? 0))
    }
}
struct SheetID: Identifiable { let id: String; init(_ id: String) { self.id = id } }

struct VolumeSummary: View {
    let root: DiskNode
    var body: some View {
        let values = try? root.url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeURLKey])
        let capacity = Int64(values?.volumeTotalCapacity ?? 0)
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        let isVolume = values?.volume?.standardizedFileURL.path == root.url.standardizedFileURL.path
        HStack(spacing: 20) {
            Label("Свободно: \(humanSize(free))", systemImage: "circle.fill").foregroundStyle(Color(white: 0.48)).help("Свободное место по данным macOS на момент просмотра.")
            if isVolume {
                Label("Скрыто (оценка): \(humanSize(max(0, capacity - free - root.bytes)))", systemImage: "circle.fill").foregroundStyle(Color(white: 0.68))
                    .help("Разница между занятой ёмкостью тома и найденными файлами. Может включать снимки и клоны APFS, сжатие, системные и недоступные данные; это приблизительная оценка.")
            }
            Spacer()
        }.font(.caption).padding(.horizontal, 22).padding(.bottom, 10)
    }
}
