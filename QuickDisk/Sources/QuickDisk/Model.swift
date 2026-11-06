import SwiftUI
import AppKit
import CoreServices
import CoreText
import PDFKit
import UniformTypeIdentifiers

@MainActor final class AppModel: ObservableObject {
    @Published var result: ScanResult?
    @Published var current: DiskNode?
    @Published var progress: ScanProgress?
    @Published var busy = false
    @Published var status = "Выберите диск или папку"
    @Published var message: String?
    @Published var duplicateGroups: [DuplicateGroup] = []
    @Published var duplicateBusy = false
    @Published var duplicateStatus = "Сравнение содержимого файлов, включая переименованные копии"
    @Published var recent: [String] = UserDefaults.standard.stringArray(forKey: "recent") ?? []
    @Published var snapshotHistoryVersion = 0
    private var token = StopToken(); private var dupToken = StopToken()
    private var generation = UUID(); private var back: [DiskNode] = []; private var forward: [DiskNode] = []
    private var stream: FSEventStreamRef?; private var refreshTask: DispatchWorkItem?
    private var pendingChanges: [String: Bool] = [:]; private var pendingFullRefresh = false
    private var activeScopedURL: URL?; private var hasScopedAccess = false
    private var fileIdentities = Set<FileIdentity>()
    private var cacheEventID: UInt64 = 0
    private var isCachedSnapshot = false
    var sourceURL: URL?
    private var diskCacheEnabled: Bool { UserDefaults.standard.object(forKey: "cacheEnabled") as? Bool ?? true }
    nonisolated private static var diskCacheIsEnabled: Bool { UserDefaults.standard.object(forKey: "cacheEnabled") as? Bool ?? true }
    private func cacheDirectoryURL() -> URL? {
        let defaults = UserDefaults.standard
        let path = defaults.string(forKey: "cacheFolderPath") ?? ""
        guard !path.isEmpty else { return nil }
        if let data = defaults.data(forKey: "cacheFolderBookmark") {
            do {
                var stale = false
                let resolved = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale, let refreshed = try? resolved.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    defaults.set(refreshed, forKey: "cacheFolderBookmark")
                }
                return resolved
            } catch { return URL(fileURLWithPath: path, isDirectory: true) }
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
    func setCacheDirectory(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "cacheFolderBookmark")
            UserDefaults.standard.set(url.standardizedFileURL.path, forKey: "cacheFolderPath")
        } catch { message = "Не удалось сохранить доступ к выбранной папке кэша: \(error.localizedDescription)" }
    }
    func resetCacheDirectory() {
        UserDefaults.standard.removeObject(forKey: "cacheFolderBookmark")
        UserDefaults.standard.removeObject(forKey: "cacheFolderPath")
    }
    func snapshots(for root: DiskNode) -> [DiskSnapshot] {
        guard !root.remote else { return [] }
        let directory = cacheDirectoryURL()
        let cacheFile = ScanCacheStore.url(for: root.id, directory: directory)
        let started = directory?.startAccessingSecurityScopedResource() ?? false
        defer { if started { directory?.stopAccessingSecurityScopedResource() } }
        return SnapshotHistoryStore.load(from: SnapshotHistoryStore.url(for: cacheFile))
    }
    func deleteSnapshot(_ id: UUID, for root: DiskNode) {
        guard !root.remote else { return }
        let directory = cacheDirectoryURL()
        let cacheFile = ScanCacheStore.url(for: root.id, directory: directory)
        let historyFile = SnapshotHistoryStore.url(for: cacheFile)
        let started = directory?.startAccessingSecurityScopedResource() ?? false
        defer { if started { directory?.stopAccessingSecurityScopedResource() } }
        do {
            try SnapshotHistoryStore.delete(id: id, from: historyFile)
            snapshotHistoryVersion += 1
        } catch {
            message = "Не удалось удалить снимок: \(error.localizedDescription)"
        }
    }
    var canBack: Bool { !back.isEmpty }; var canForward: Bool { !forward.isEmpty }
    var volumes: [URL] { FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeIsBrowsableKey], options: [.skipHiddenVolumes]) ?? [] }
    func pickFolder(startAt: URL? = nil) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.prompt = "Сканировать"; panel.directoryURL = startAt
        if panel.runModal() == .OK, let url = panel.url { rememberAccess(for: url); scan(url) }
    }
    func scanVolume(_ url: URL) {
        let hasBookmark = (UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data])?[url.standardizedFileURL.path] != nil
        if hasBookmark { scan(url) } else { pickFolder(startAt: url) }
    }
    func scanRecent(_ path: String) {
        let url = URL(fileURLWithPath: path)
        guard diskCacheEnabled else { scan(url); return }
        let hasBookmark = (UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data])?[url.standardizedFileURL.path] != nil
        guard hasBookmark else { pickFolder(startAt: url); return }
        let resolved = authorizedURL(for: url)
        guard FileManager.default.fileExists(atPath: resolved.path) else { scan(url); return }
        if activeScopedURL?.standardizedFileURL.path != resolved.standardizedFileURL.path {
            if hasScopedAccess, let activeScopedURL { activeScopedURL.stopAccessingSecurityScopedResource() }
            hasScopedAccess = resolved.startAccessingSecurityScopedResource(); activeScopedURL = hasScopedAccess ? resolved : nil
        }
        stopWatching(); token.cancel(); token = StopToken(); let run = UUID(); generation = run
        sourceURL = resolved; busy = true; current = nil; status = "Открытие сохранённого результата…"
        let cacheDirectory = cacheDirectoryURL()
        let cacheFile = ScanCacheStore.url(for: resolved.standardizedFileURL.path, directory: cacheDirectory)
        let cacheScopeStarted = cacheDirectory?.startAccessingSecurityScopedResource() ?? false
        DispatchQueue.global(qos: .utility).async {
            let cached = ScanCacheStore.load(path: resolved.standardizedFileURL.path, cacheURL: cacheFile)
            if cacheScopeStarted { cacheDirectory?.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                guard self.generation == run else { return }
                guard let (root, eventID, errors, skipped, legacy) = cached else { self.scan(url); return }
                self.cacheEventID = eventID; self.fileIdentities = []; self.isCachedSnapshot = true
                self.result = ScanResult(root: root, errors: errors, skipped: skipped, seconds: 0, cancelled: false)
                self.current = root; self.progress = nil; self.busy = false; self.back = []; self.forward = []; self.duplicateGroups = []
                self.status = "Открыт сохранённый результат · проверка изменений…"
                self.recent.removeAll { $0 == path }; self.recent.insert(path, at: 0); self.recent = Array(self.recent.prefix(8)); UserDefaults.standard.set(self.recent, forKey: "recent")
                if legacy, self.diskCacheEnabled {
                    let migrationScopeStarted = cacheDirectory?.startAccessingSecurityScopedResource() ?? false
                    DispatchQueue.global(qos: .utility).async {
                        defer { if migrationScopeStarted { cacheDirectory?.stopAccessingSecurityScopedResource() } }
                        try? ScanCacheStore.save(root: root, eventID: eventID, errors: errors, skipped: skipped, to: cacheFile)
                    }
                }
                if UserDefaults.standard.bool(forKey: "watch") { self.scan(resolved, preserveCurrent: true) }
                else { self.status = "Открыт сохранённый результат · автоматическое обновление выключено" }
            }
        }
    }
    func rememberAccess(for url: URL) {
        do {
            let data = try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
            var values = UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data] ?? [:]
            values[url.standardizedFileURL.path] = data
            UserDefaults.standard.set(values, forKey: "folderBookmarks")
        } catch { message = "macOS не смогла сохранить разрешение для этой папки. При следующем запуске может потребоваться выбрать её снова." }
    }
    private func authorizedURL(for url: URL) -> URL {
        let path = url.standardizedFileURL.path
        guard let data = (UserDefaults.standard.dictionary(forKey: "folderBookmarks") as? [String: Data])?[path] else { return url }
        do {
            var stale = false
            let resolved = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale { rememberAccess(for: resolved) }
            return resolved
        } catch { return url }
    }
    func navigate(_ node: DiskNode) { guard node.isDirectory, current?.id != node.id else { return }; if let current { back.append(current) }; forward = []; self.current = node }
    func goBack() { guard let n = back.popLast() else { return }; if let current { forward.append(current) }; current = n }
    func goForward() { guard let n = forward.popLast() else { return }; if let current { back.append(current) }; current = n }
    func loadMoreChildren(_ node: DiskNode) { _ = node.loadMoreChildren(); if current?.id == node.id { current = node } }
    func home() { if busy { cancel() }; current = nil; back = []; forward = []; pendingChanges.removeAll(); pendingFullRefresh = false; stopWatching() }
    func cancel() { token.cancel(); status = "Остановка…" }
    func cancelDuplicates() { dupToken.cancel() }
    func saveSnapshot() {
        guard let sourceURL else { message = "Сначала просканируйте локальный диск или папку."; return }
        guard diskCacheEnabled else { message = "Чтобы сохранять снимки, включите кэш в настройках. Снимки будут храниться в выбранной папке кэша."; return }
        scan(sourceURL, saveSnapshot: true)
    }
    func scan(_ url: URL, preserveCurrent: Bool = false, saveSnapshot: Bool = false) {
        if !preserveCurrent { isCachedSnapshot = false }
        let scanURL = authorizedURL(for: url)
        if activeScopedURL?.standardizedFileURL.path != scanURL.standardizedFileURL.path {
            if hasScopedAccess, let activeScopedURL { activeScopedURL.stopAccessingSecurityScopedResource() }
            hasScopedAccess = scanURL.startAccessingSecurityScopedResource()
            activeScopedURL = hasScopedAccess ? scanURL : nil
        }
        stopWatching(); token.cancel(); let newToken = StopToken(); token = newToken; let run = UUID(); generation = run
        let scanBaseline = FSEventsGetCurrentEventId(); cacheEventID = UInt64(scanBaseline)
        let cacheEnabledAtStart = diskCacheEnabled
        let historyEnabledAtStart = UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true
        let saveHistoryAtStart = historyEnabledAtStart || saveSnapshot
        let cacheDirectory = cacheEnabledAtStart ? cacheDirectoryURL() : nil
        let cacheFile = cacheEnabledAtStart ? ScanCacheStore.url(for: scanURL.standardizedFileURL.path, directory: cacheDirectory) : nil
        let historyFile = cacheFile.map(SnapshotHistoryStore.url(for:))
        busy = true; progress = nil; if !preserveCurrent { current = nil }; sourceURL = scanURL; status = "Сканирование \(scanURL.path)"; duplicateGroups = []
        DispatchQueue.global(qos: .userInitiated).async {
            var previousRoot: DiskNode?
            var historyGapBefore = false
            if cacheEnabledAtStart && saveHistoryAtStart, let cacheFile {
                let cacheScopeStarted = cacheDirectory?.startAccessingSecurityScopedResource() ?? false
                previousRoot = ScanCacheStore.load(path: scanURL.standardizedFileURL.path, cacheURL: cacheFile)?.0
                if let historyFile,
                   let latest = SnapshotHistoryStore.load(from: historyFile).last,
                   let attributes = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
                   let cacheModified = attributes[.modificationDate] as? Date {
                    historyGapBefore = cacheModified > latest.date.addingTimeInterval(1)
                }
                if cacheScopeStarted { cacheDirectory?.stopAccessingSecurityScopedResource() }
            }
            var historyWasSaved = false
            var historyError: String?
            let result = Scanner.scan(scanURL, stop: newToken) { progress in
                DispatchQueue.main.async { guard self.generation == run else { return }; self.progress = progress; if let preview = progress.preview { self.current = preview } }
            }
            var cacheSaved = false
            if !result.cancelled && cacheEnabledAtStart && Self.diskCacheIsEnabled {
                DispatchQueue.main.async { guard self.generation == run else { return }; self.progress = nil; self.status = "Скан завершён · сохранение локального кэша…" }
                let cacheScopeStarted = cacheDirectory?.startAccessingSecurityScopedResource() ?? false
                defer { if cacheScopeStarted { cacheDirectory?.stopAccessingSecurityScopedResource() } }
                do {
                    try ScanCacheStore.save(root: result.root, eventID: UInt64(scanBaseline), errors: result.errors, skipped: result.skipped, to: cacheFile)
                    cacheSaved = true
                }
                catch { NSLog("QuickDisk cache save failed: %@", error.localizedDescription) }
            }
            if !result.cancelled, cacheSaved,
               (saveSnapshot || (historyEnabledAtStart && (UserDefaults.standard.object(forKey: "historyEnabled") as? Bool ?? true))),
               let historyFile {
                let cacheScopeStarted = cacheDirectory?.startAccessingSecurityScopedResource() ?? false
                let values = try? scanURL.resourceValues(forKeys: [.volumeURLKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
                let isVolumeRoot = values?.volume?.standardizedFileURL.path == scanURL.standardizedFileURL.path
                let capacity = isVolumeRoot ? Int64(values?.volumeTotalCapacity ?? 0) : nil
                let free = isVolumeRoot ? Int64(values?.volumeAvailableCapacity ?? 0) : nil
                do {
                    try SnapshotHistoryStore.append(root: result.root, previousRoot: previousRoot,
                                                    capacity: capacity, free: free,
                                                    errors: result.errors.count, skipped: result.skipped,
                                                    gapBefore: historyGapBefore,
                                                    isManual: saveSnapshot,
                                                    to: historyFile)
                    historyWasSaved = true
                } catch {
                    historyError = error.localizedDescription
                    NSLog("QuickDisk snapshot history save failed: %@", error.localizedDescription)
                }
                if cacheScopeStarted { cacheDirectory?.stopAccessingSecurityScopedResource() }
            }
            DispatchQueue.main.async {
                guard self.generation == run else { return }
                self.result = result; self.fileIdentities = result.fileIdentities; self.current = result.root; self.busy = false; self.back = []; self.forward = []
                if !result.cancelled { self.isCachedSnapshot = false }
                self.status = "\(result.cancelled ? "Остановлено" : "Готово") · \(result.root.count.formatted()) файлов · \(String(format: "%.1f", result.seconds)) с · пропущено: \(result.skipped) · ошибок: \(result.errors.count)"
                if !result.cancelled { self.recent.removeAll { $0 == scanURL.path }; self.recent.insert(scanURL.path, at: 0); self.recent = Array(self.recent.prefix(8)); UserDefaults.standard.set(self.recent, forKey: "recent"); self.startWatching(); self.flushPendingChangesIfNeeded() }
                if historyWasSaved {
                    self.snapshotHistoryVersion += 1
                    if saveSnapshot { self.status += " · снимок сохранён" }
                } else if saveSnapshot && !result.cancelled {
                    self.message = historyError.map { "Не удалось сохранить снимок: \($0)" } ?? "Не удалось сохранить снимок: кэш не был записан. Проверьте доступ к папке кэша."
                }
            }
        }
    }
    func remote(kind: String, host: String, path: String) {
        stopWatching(); token.cancel(); let t = StopToken(); token = t; let run = UUID(); generation = run
        busy = true; progress = nil; sourceURL = nil; status = "\(kind): чтение каталога…"
        DispatchQueue.global(qos: .userInitiated).async {
            do { let result = try RemoteScan.scan(kind: kind, host: host, path: path, stop: t)
                DispatchQueue.main.async { guard self.generation == run else { return }; self.result = result; self.fileIdentities = []; self.current = result.root; self.busy = false; self.back = []; self.forward = []; self.status = "\(kind) · \(result.root.count) файлов · ошибок: \(result.errors.count) · только просмотр" }
            } catch { DispatchQueue.main.async { guard self.generation == run else { return }; self.busy = false; self.message = error.localizedDescription; self.status = "Сканирование не завершено" } }
        }
    }
    func findDuplicates(extra: [URL] = []) {
        guard !duplicateBusy else { return }
        let roots = result.map { [$0.root] } ?? []
        guard !roots.isEmpty || !extra.isEmpty else { message = "Сначала просканируйте папку или добавьте папки для сравнения."; return }
        let scopedExtra = extra.map(authorizedURL(for:)).map { ($0, $0.startAccessingSecurityScopedResource()) }
        let t = StopToken(); dupToken = t; duplicateBusy = true; duplicateGroups = []
        DispatchQueue.global(qos: .userInitiated).async {
            var allRoots = roots
            for (url, _) in scopedExtra { if t.cancelled { break }; allRoots.append(Scanner.scan(url, stop: t).root) }
            let found = Duplicates.find(allRoots, stop: t) { done, total in
                if done % 10 == 0 || done == total { DispatchQueue.main.async { self.duplicateStatus = "Проверено \(done) из \(total) файлов" } }
            }
            DispatchQueue.main.async { for (url, started) in scopedExtra where started { url.stopAccessingSecurityScopedResource() }; self.duplicateGroups = found.groups; self.duplicateBusy = false; self.duplicateStatus = "\(t.cancelled ? "Остановлено" : "Готово") · групп: \(found.groups.count) · ошибок: \(found.errors.count)"; if !found.errors.isEmpty { self.message = found.errors.prefix(12).joined(separator: "\n") } }
        }
    }
    func exportReport() {
        guard let root = current else { return }
        exportReport(root: root, depth: max(2, UserDefaults.standard.integer(forKey: "depth")), nodes: root.children)
    }
    func exportReport(root: DiskNode, depth: Int, nodes: [DiskNode]) {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "QuickDisk-report.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try writePDF(to: url, root: root, depth: depth, nodes: nodes) }
        catch { message = "Не удалось сохранить PDF: \(error.localizedDescription)" }
    }
    private func writePDF(to url: URL, root: DiskNode, depth: Int, nodes: [DiskNode]) throws {
        let values = root.remote ? nil : try? root.url.resourceValues(forKeys: [.volumeURLKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey])
        let capacity = Int64(values?.volumeTotalCapacity ?? 0)
        let free = Int64(values?.volumeAvailableCapacity ?? 0)
        let isVolume = values?.volume?.standardizedFileURL.path == root.url.standardizedFileURL.path
        let chart = DiskChart(root: root, depth: depth,
                              volumeCapacity: isVolume ? capacity : nil,
                              volumeFree: isVolume ? free : nil) { _ in }
            .frame(width: 680, height: 680)
        let renderer = ImageRenderer(content: chart)
        renderer.scale = 2
        guard let chartImage = renderer.cgImage else { throw NSError(domain: "QuickDisk.PDF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось построить изображение диаграммы."]) }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "QuickDisk.PDF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось создать PDF-файл."])
        }
        let date = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ink = NSColor(calibratedRed: 0.10, green: 0.14, blue: 0.23, alpha: 1)
        let muted = NSColor(calibratedRed: 0.42, green: 0.47, blue: 0.57, alpha: 1)
        let background = NSColor(calibratedRed: 0.95, green: 0.965, blue: 0.985, alpha: 1)
        let card = NSColor.white
        let accent = NSColor(calibratedRed: 0.98, green: 0.48, blue: 0.15, alpha: 1)

        context.beginPDFPage(nil)
        context.setFillColor(background.cgColor); context.fill(page)
        fillPDFRect(CGRect(x: 0, y: 666, width: 612, height: 126), color: ink, in: context, radius: 0)
        drawPDFText("QUICKDISK  /  ОТЧЁТ ПО МЕСТУ", in: context, x: 32, y: 758, size: 8, color: NSColor(calibratedRed: 0.76, green: 0.81, blue: 0.91, alpha: 1))
        drawPDFText("Статистика диска", in: context, x: 32, y: 729, size: 23, color: .white)
        drawPDFText(String(root.id.suffix(76)), in: context, x: 32, y: 707, size: 8, color: NSColor(calibratedRed: 0.83, green: 0.87, blue: 0.94, alpha: 1))
        drawPDFText(date, in: context, x: 450, y: 758, size: 8, color: NSColor(calibratedRed: 0.83, green: 0.87, blue: 0.94, alpha: 1))

        let metricY: CGFloat = 582, metricHeight: CGFloat = 68, gap: CGFloat = 10, metricWidth: CGFloat = 130
        let hidden = isVolume ? max(0, capacity - free - root.bytes) : 0
        let metrics: [(String, String, String)] = [
            ("ЗАНЯТО ПО СКАНУ", humanSize(root.bytes), "выделенные блоки"),
            ("ЛОГИЧЕСКИЙ ОБЪЁМ", humanSize(root.logical), "размер содержимого"),
            ("ФАЙЛЫ", root.count.formatted(), "в открытом дереве"),
            (isVolume ? "СВОБОДНО" : "ЭЛЕМЕНТЫ", isVolume ? humanSize(free) : nodes.count.formatted(), isVolume ? "на томе" : "в этой папке")
        ]
        for (index, metric) in metrics.enumerated() {
            let x = 32 + CGFloat(index) * (metricWidth + gap)
            fillPDFRect(CGRect(x: x, y: metricY, width: metricWidth, height: metricHeight), color: card, in: context, radius: 10)
            drawPDFText(metric.0, in: context, x: x + 11, y: metricY + 48, size: 6.5, color: muted)
            drawPDFText(metric.1, in: context, x: x + 11, y: metricY + 25, size: 15, color: index == 0 ? accent : ink)
            drawPDFText(metric.2, in: context, x: x + 11, y: metricY + 10, size: 6.5, color: muted)
        }

        let chartCard = CGRect(x: 32, y: 145, width: 340, height: 420)
        let listCard = CGRect(x: 384, y: 145, width: 196, height: 420)
        fillPDFRect(chartCard, color: card, in: context, radius: 14)
        fillPDFRect(listCard, color: card, in: context, radius: 14)
        drawPDFText("КАРТА ЗАНЯТОГО МЕСТА", in: context, x: 48, y: 540, size: 8, color: muted)
        // The chart is rendered into a large, fixed canvas and placed inside a white panel.
        // Keep the image uncropped so its full circular sectors remain visible in the PDF.
        context.draw(chartImage, in: CGRect(x: 42, y: 178, width: 320, height: 320))
        if isVolume {
            context.setFillColor(NSColor(white: 0.38, alpha: 1).cgColor); context.fillEllipse(in: CGRect(x: 52, y: 157, width: 7, height: 7))
            drawPDFText("Свободно", in: context, x: 64, y: 157, size: 7, color: muted)
            context.setFillColor(NSColor(white: 0.68, alpha: 1).cgColor); context.fillEllipse(in: CGRect(x: 139, y: 157, width: 7, height: 7))
            drawPDFText("Скрытое место (оценка)", in: context, x: 151, y: 157, size: 7, color: muted)
        }
        drawPDFText("КРУПНЕЙШИЕ ЭЛЕМЕНТЫ", in: context, x: 400, y: 540, size: 7.2, color: muted)
        drawPDFText("На диске  /  Логический", in: context, x: 400, y: 523, size: 6.5, color: muted)

        let topNodes = Array(nodes.sorted { $0.bytes > $1.bytes }.prefix(6))
        let maxBytes = max(1, topNodes.first?.bytes ?? 1)
        let barColors: [NSColor] = [
            NSColor(calibratedRed: 0.78, green: 0.27, blue: 0.87, alpha: 1),
            NSColor(calibratedRed: 0.90, green: 0.81, blue: 0.22, alpha: 1),
            NSColor(calibratedRed: 0.18, green: 0.75, blue: 0.31, alpha: 1),
            NSColor(calibratedRed: 0.12, green: 0.70, blue: 0.62, alpha: 1),
            NSColor(calibratedRed: 0.13, green: 0.73, blue: 0.82, alpha: 1),
            NSColor(calibratedRed: 0.24, green: 0.43, blue: 0.91, alpha: 1),
            NSColor(calibratedRed: 0.88, green: 0.35, blue: 0.60, alpha: 1)
        ]
        for (index, node) in topNodes.enumerated() {
            let y = CGFloat(490 - index * 49)
            let title = "\(node.isDirectory ? "Папка" : "Файл") · \(node.name.prefix(22))"
            drawPDFText(title, in: context, x: 400, y: y, size: 8, color: ink)
            drawPDFText("\(humanSize(node.bytes))   /   \(humanSize(node.logical))", in: context, x: 400, y: y - 14, size: 7, color: muted)
            let barWidth = max(5, 164 * CGFloat(node.bytes) / CGFloat(maxBytes))
            fillPDFRect(CGRect(x: 400, y: y - 25, width: 164, height: 4), color: background, in: context, radius: 2)
            fillPDFRect(CGRect(x: 400, y: y - 25, width: barWidth, height: 4), color: barColors[index % barColors.count], in: context, radius: 2)
            if index < topNodes.count - 1 {
                context.setStrokeColor(background.cgColor); context.setLineWidth(0.7)
                context.move(to: CGPoint(x: 400, y: y - 34)); context.addLine(to: CGPoint(x: 564, y: y - 34)); context.strokePath()
            }
        }
        if topNodes.isEmpty { drawPDFText("Нет элементов для отображения", in: context, x: 400, y: 488, size: 7, color: muted) }
        let omitted = max(0, nodes.count - topNodes.count)
        drawPDFText("Показано \(topNodes.count) из \(nodes.count) элементов", in: context, x: 400, y: 168, size: 6.5, color: muted)

        if isVolume {
            drawPDFText("Ёмкость \(humanSize(capacity))   ·   Скрытое место (оценка) \(humanSize(hidden))", in: context, x: 34, y: 112, size: 8, color: ink)
            drawPDFText("Оценка скрытого места может включать снимки APFS, служебные и недоступные данные.", in: context, x: 34, y: 96, size: 7, color: muted)
        } else {
            drawPDFText("Показаны крупнейшие элементы текущей папки; размеры приведены как выделенные / логические.", in: context, x: 34, y: 104, size: 7, color: muted)
        }
        drawPDFText("Сформировано QuickDisk · просмотр без изменения пользовательских файлов", in: context, x: 34, y: 38, size: 7, color: muted)
        drawPDFText(omitted > 0 ? "+ ещё \(omitted)" : "", in: context, x: 516, y: 38, size: 7, color: muted)
        context.endPDFPage()
        context.closePDF()
    }
    private func fillPDFRect(_ rect: CGRect, color: NSColor, in context: CGContext, radius: CGFloat) {
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(path); context.setFillColor(color.cgColor); context.fillPath()
    }
    private func drawPDFText(_ text: String, in context: CGContext, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor) {
        let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color.cgColor
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
    func startWatching() {
        stopWatching()
        guard UserDefaults.standard.bool(forKey: "watch"), let url = sourceURL else { return }
        if isCachedSnapshot { if !busy { scan(url, preserveCurrent: true) }; return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, eventFlags, _ in
            guard let info else { return }
            let model = Unmanaged<AppModel>.fromOpaque(info).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(rawPaths).takeUnretainedValue() as NSArray
            let pathValues = paths.compactMap { $0 as? String }
            var changes: [ChangedPath] = []; var fullRefresh = false
            for index in 0..<count {
                let flags = eventFlags[index]
                if flags & UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped) != 0 {
                    fullRefresh = true; continue
                }
                guard index < pathValues.count else { continue }
                let removed = flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0
                changes.append(ChangedPath(path: URL(fileURLWithPath: pathValues[index]).standardizedFileURL.path, removed: removed))
            }
            DispatchQueue.main.async { model.queueChanges(changes, fullRefresh: fullRefresh) }
        }, &context, [url.path] as CFArray, cacheEventID == 0 ? FSEventStreamEventId(kFSEventStreamEventIdSinceNow) : FSEventStreamEventId(cacheEventID), 2, UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents))
        if let stream { FSEventStreamSetDispatchQueue(stream, .main); FSEventStreamStart(stream) }
    }
    private func queueChanges(_ changes: [ChangedPath], fullRefresh: Bool) {
        guard UserDefaults.standard.bool(forKey: "watch"), sourceURL != nil else { return }
        pendingFullRefresh = pendingFullRefresh || fullRefresh
        for change in changes {
            pendingChanges[change.path] = change.removed
            if change.removed, let sourceURL {
                let parent = URL(fileURLWithPath: change.path).deletingLastPathComponent().standardizedFileURL.path
                if parent.hasPrefix(sourceURL.standardizedFileURL.path) { pendingChanges[parent] = false }
            }
        }
        refreshTask?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flushPendingChangesIfNeeded() }
        refreshTask = item; DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: item)
    }
    private func flushPendingChangesIfNeeded() {
        guard UserDefaults.standard.bool(forKey: "watch"), let url = sourceURL,
              !pendingChanges.isEmpty || pendingFullRefresh else { return }
        guard !busy, let root = result?.root else {
            refreshTask?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.flushPendingChangesIfNeeded() }
            refreshTask = item; DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
            return
        }
        if pendingFullRefresh {
            pendingChanges.removeAll(); pendingFullRefresh = false
            scan(url)
            return
        }
        let changes = pendingChanges.map { ChangedPath(path: $0.key, removed: $0.value) }
        pendingChanges.removeAll()
        var knownChildren: [String: Set<String>] = [:]
        for change in changes {
            if let node = TreeUpdater.node(at: change.path, in: root), node.isDirectory { knownChildren[change.path] = Set(node.children.map(\.id)) }
        }
        let run = generation; let stop = StopToken(); busy = true; status = "Обновление \(changes.count) изменённых путей…"
        DispatchQueue.global(qos: .utility).async {
            let snapshots = Scanner.snapshotChanges(changes, root: root, knownChildren: knownChildren, stop: stop)
            DispatchQueue.main.async {
                guard self.generation == run else { return }
                let updated = TreeUpdater.apply(snapshots, to: root, fileIdentities: &self.fileIdentities)
                self.busy = false
                self.status = "Обновлены только изменённые пути · \(updated) · \(root.count.formatted()) файлов"
                self.current = self.current.flatMap { TreeUpdater.node(at: $0.id, in: root) } ?? root
                if !self.pendingChanges.isEmpty || self.pendingFullRefresh { self.flushPendingChangesIfNeeded() }
            }
        }
    }
    func stopWatching() { refreshTask?.cancel(); pendingChanges.removeAll(); pendingFullRefresh = false; if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }; stream = nil }
}
