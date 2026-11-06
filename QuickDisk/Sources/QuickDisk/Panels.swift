import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @AppStorage("theme") var theme = "dark"
    @AppStorage("depth") var depth = 6
    @AppStorage("watch") var watch = false
    @AppStorage("cacheEnabled") var cacheEnabled = true
    @AppStorage("historyEnabled") var historyEnabled = false
    @AppStorage("cacheFolderPath") var cacheFolderPath = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack { Text("Настройки").font(.largeTitle.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            Form {
                Picker("Оформление", selection: $theme) { Text("Тёмное").tag("dark"); Text("Светлое").tag("light") }
                Stepper("Глубина диаграммы: \(depth)", value: $depth, in: 2...10)
                Toggle("Обновлять только изменённые пути автоматически", isOn: $watch).onChange(of: watch) { _, newValue in if newValue { model.startWatching() } else { model.stopWatching() } }
                Toggle("Использовать кэш для ускорения сканирования", isOn: $cacheEnabled)
                    .help("Кэш сохраняет метаданные дерева на диск: повторное открытие папки быстрее и не требует сразу пересканировать её целиком. Если отключить, QuickDisk не будет читать или создавать файлы кэша, а каждое сканирование начнётся заново без крупных записей снимка.")
                Toggle("Автоматически сохранять историю сканов", isOn: $historyEnabled)
                    .disabled(!cacheEnabled)
                    .help("После каждого завершённого сканирования QuickDisk добавляет компактную запись в историю. Отдельную точку истории можно создать кнопкой «Сохранить снимок» в окне изменений. Файлы истории хранятся в выбранной папке кэша.")
                if cacheEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Папка для файлов кэша")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Text(cacheFolderPath.isEmpty ? "Стандартная папка QuickDisk" : cacheFolderPath)
                                .font(.caption).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("Выбрать…") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
                                panel.prompt = "Выбрать папку"
                                if !cacheFolderPath.isEmpty { panel.directoryURL = URL(fileURLWithPath: cacheFolderPath) }
                                if panel.runModal() == .OK, let url = panel.url {
                                    model.setCacheDirectory(url)
                                    cacheFolderPath = url.standardizedFileURL.path
                                }
                            }
                            Button("По умолчанию") { model.resetCacheDirectory(); cacheFolderPath = "" }
                                .disabled(cacheFolderPath.isEmpty)
                        }
                    }
                }
            }.formStyle(.grouped)
            if cacheEnabled {
                Text(historyEnabled
                     ? "Кэш содержит имена и метаданные файлов, не их содержимое. История сканов обновляется после каждого успешного сканирования; также можно сохранить снимок вручную. Хранятся последние 365 записей для каждого пути. Снимки лежат в этой же папке кэша."
                     : "Кэш содержит только имена и метаданные файлов, не их содержимое. Автоматическая история выключена; отдельный снимок можно сохранить вручную из окна изменений. При выключенном кэше новые снимки не создаются, уже записанная история остаётся доступной.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Кэш отключён: новые кэш-файлы и снимки истории не записываются. Полный скан будет выполняться каждый раз; существующая история остаётся в выбранной папке кэша и доступна для просмотра.").font(.callout).foregroundStyle(.secondary)
            }
            Text("QuickDisk 0.4.1 · macOS 14+\nУниверсальная сборка: Apple Silicon и Intel.\nТолько просмотр: приложение не удаляет и не перемещает ваши файлы.\nНет рекламы, аккаунтов, аналитики и фоновой проверки обновлений.\nЗакладки доступа, кэш и история снимков хранятся локально на этом Mac.").font(.callout).foregroundStyle(.secondary)
            Text("Выделенный объём — сумма блоков файлов, а не уникальное место APFS. Скрытое место — оценка разницы с ёмкостью тома; она может включать снимки и клоны APFS, сжатие, системные и недоступные данные. Облачные источники показывают размер объектов.").font(.caption).foregroundStyle(.secondary)
            Text("Клавиши: ⌘R — полный повторный скан; ⌘[ / ⌘] — назад и вперёд; ⌘O — выбрать папку.").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 650, height: 740)
    }
}

struct SnapshotHistoryView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("cacheEnabled") private var cacheEnabled = true
    @State private var snapshots: [DiskSnapshot] = []
    @State private var fromID: UUID?
    @State private var toID: UUID?
    @State private var searchText = ""
    @State private var deletePromptID: UUID?

    private var root: DiskNode? { model.result?.root }
    private var selected: (DiskSnapshot, DiskSnapshot, Int, Int)? {
        guard let fromID, let toID,
              let fromIndex = snapshots.firstIndex(where: { $0.id == fromID }),
              let toIndex = snapshots.firstIndex(where: { $0.id == toID }),
              fromIndex < toIndex else { return nil }
        return (snapshots[fromIndex], snapshots[toIndex], fromIndex, toIndex)
    }
    private var hasHistoryGap: Bool {
        guard let (_, _, fromIndex, toIndex) = selected else { return false }
        return snapshots[(fromIndex + 1)...toIndex].contains { $0.gapBefore == true }
    }
    private var aggregatedChanges: [SnapshotChange] {
        guard !hasHistoryGap else { return [] }
        guard let (_, _, fromIndex, toIndex) = selected, toIndex > fromIndex + 1 else {
            return selected.map { $0.1.changes } ?? []
        }
        var byID: [String: SnapshotChange] = [:]
        for snapshot in snapshots[(fromIndex + 1)...toIndex] {
            for change in snapshot.changes {
                if let previous = byID[change.id] {
                    byID[change.id] = SnapshotChange(path: change.path, isDirectory: change.isDirectory,
                                                     beforeBytes: previous.beforeBytes, afterBytes: change.afterBytes,
                                                     beforeLogical: previous.beforeLogical, afterLogical: change.afterLogical)
                } else { byID[change.id] = change }
            }
        }
        return Array(byID.values).filter { $0.bytesDelta != 0 || $0.logicalDelta != 0 }
    }
    private var folderChanges: [SnapshotChange] {
        Array(aggregatedChanges.filter { $0.isDirectory && matches($0) }.sorted { $0.bytesDelta.magnitude > $1.bytesDelta.magnitude })
    }
    private var fileChanges: [SnapshotChange] {
        Array(aggregatedChanges.filter { !$0.isDirectory && matches($0) }.sorted { $0.bytesDelta.magnitude > $1.bytesDelta.magnitude })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("История диска").font(.system(size: 27, weight: .bold, design: .rounded))
                    Text(root?.id ?? "Локальное сканирование").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(root?.id ?? "")
                }
                Spacer()
                Menu {
                    ForEach(snapshots) { snapshot in
                        Button(snapshotLabelText(snapshot), systemImage: "trash") { deletePromptID = snapshot.id }
                    }
                } label: {
                    Label("Удалить снимок", systemImage: "trash")
                }
                .disabled(snapshots.isEmpty)
                .help("Выберите снимок истории для удаления")
                Button { model.saveSnapshot() } label: {
                    if model.busy { Label("Сканирую…", systemImage: "hourglass") }
                    else { Label("Сохранить снимок", systemImage: "camera.badge.plus") }
                }.buttonStyle(.borderedProminent).tint(.indigo)
                    .disabled(model.busy || !cacheEnabled || (root?.remote ?? true))
                    .help(cacheEnabled ? "Выполнить свежий скан и сохранить его в истории" : "Включите кэш в настройках: снимки хранятся в папке кэша")
                Button("Закрыть") { dismiss() }
            }
            HStack(spacing: 9) {
                Image(systemName: "info.circle.fill").foregroundStyle(.indigo)
                Text("Снимок выполняет новый скан. Дата фиксируется по его завершении. Файлы истории сохраняются в выбранной папке кэша.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(.indigo.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            if model.busy {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(model.status).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Остановить") { model.cancel() }.buttonStyle(.borderless) }
                    .padding(.horizontal, 4)
            }
            if snapshots.isEmpty {
                ContentUnavailableView("История пока пуста", systemImage: "clock.arrow.circlepath", description: Text(cacheEnabled ? "Нажмите «Сохранить снимок». QuickDisk выполнит сканирование и добавит первую точку истории." : "Включите кэш в настройках, чтобы сохранять снимки в папке кэша."))
            } else if snapshots.count == 1 {
                snapshotCard(snapshots[0])
                ContentUnavailableView("Есть один снимок", systemImage: "clock", description: Text("Сохраните ещё один снимок, чтобы увидеть, какие папки и файлы изменились."))
            } else {
                snapshotSelectors
                if let (start, end, _, _) = selected {
                    comparison(start: start, end: end)
                } else {
                    ContentUnavailableView("Выберите даты", systemImage: "arrow.left.arrow.right", description: Text("Укажите более ранний и более поздний снимок."))
                }
            }
        }
        .padding(24).frame(minWidth: 1080, minHeight: 760)
        .onAppear { loadSnapshots() }
        .onChange(of: model.snapshotHistoryVersion) { _, _ in loadSnapshots(keepSelection: true) }
        .confirmationDialog("Удалить снимок истории?", isPresented: Binding(
            get: { deletePromptID != nil },
            set: { if !$0 { deletePromptID = nil } }
        ), titleVisibility: .visible) {
            Button("Удалить снимок", role: .destructive) {
                if let root, let deletePromptID { model.deleteSnapshot(deletePromptID, for: root) }
                deletePromptID = nil
            }
            Button("Отмена", role: .cancel) { deletePromptID = nil }
        } message: {
            if let snapshot = snapshots.first(where: { $0.id == deletePromptID }) {
                Text("Удалить снимок от \(dateLabel(snapshot.date))? Это не удалит файлы на диске.")
            }
        }
    }

    private var snapshotSelectors: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("СРАВНИТЬ С").font(.caption2.bold()).foregroundStyle(.secondary)
                Picker("Снимок начала", selection: $fromID) {
                    ForEach(Array(snapshots.dropLast())) { snapshot in Text(snapshotLabelText(snapshot)).tag(Optional(snapshot.id)) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            Image(systemName: "arrow.right").foregroundStyle(.tertiary).padding(.top, 17)
            VStack(alignment: .leading, spacing: 6) {
                Text("ПО СНИМОК").font(.caption2.bold()).foregroundStyle(.secondary)
                Picker("Снимок окончания", selection: $toID) {
                    ForEach(Array(snapshots.dropFirst())) { snapshot in Text(snapshotLabelText(snapshot)).tag(Optional(snapshot.id)) }
                }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            Text("\(snapshots.count) снимков").font(.caption).foregroundStyle(.secondary)
        }.padding(14).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private func loadSnapshots(keepSelection: Bool = false) {
        let oldFrom = fromID, oldTo = toID
        guard let root else { snapshots = []; return }
        snapshots = model.snapshots(for: root).sorted { $0.date < $1.date }
        if keepSelection, snapshots.contains(where: { $0.id == oldFrom }), snapshots.contains(where: { $0.id == oldTo }) {
            fromID = oldFrom; toID = oldTo
        } else if snapshots.count >= 2 {
            fromID = snapshots[snapshots.count - 2].id; toID = snapshots[snapshots.count - 1].id
        } else { fromID = snapshots.first?.id; toID = snapshots.last?.id }
    }

    private func snapshotCard(_ snapshot: DiskSnapshot) -> some View {
        HStack(spacing: 14) {
            Image(systemName: snapshot.isManual == true ? "camera.fill" : "clock.arrow.circlepath")
                .font(.title2).foregroundStyle(.indigo).frame(width: 46, height: 46).background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 4) {
                Text(dateLabel(snapshot.date)).font(.headline)
                Text(snapshot.isManual == true ? "Сохранён вручную" : "Автоматическая запись")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            metricMini("Занято по скану", humanSize(snapshot.scannedBytes))
            metricMini("Свободно", snapshot.free.map(humanSize) ?? "—")
            metricMini("Файлов", snapshot.fileCount.formatted())
        }.padding(16).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14))
    }

    private func comparison(start: DiskSnapshot, end: DiskSnapshot) -> some View {
        let usedStart = start.capacity.flatMap { capacity in start.free.map { capacity - $0 } }
        let usedEnd = end.capacity.flatMap { capacity in end.free.map { capacity - $0 } }
        let scannedDelta = end.scannedBytes - start.scannedBytes
        let usedDelta = usedStart.flatMap { old in usedEnd.map { $0 - old } }
        let unexplained = usedDelta.map { $0 - scannedDelta }
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                metric("Свободное место", delta(end.free, from: start.free), hint: "по данным macOS", emphasize: true)
                metric("Изменение файлов", signedSize(scannedDelta), hint: "по выделенным блокам")
                metric("Изменение на томе", usedDelta.map(signedSize) ?? "—", hint: "занятая ёмкость")
                metric("Не объяснено сканом", unexplained.map(signedSize) ?? "—", hint: "APFS, система, недоступные")
            }
            if start.errorCount > 0 || end.errorCount > 0 || start.skippedCount > 0 || end.skippedCount > 0 {
                Label("Сканирование было неполным: часть объектов могла быть недоступна.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 2)
            }
            if hasHistoryGap {
                Label("Между снимками история была выключена или кэш изменялся без записи снимка. Показатели тома сравниваются, список файловых изменений неполон.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange).padding(.horizontal, 2)
            }
            HStack {
                Text("Где изменилось").font(.headline)
                Spacer()
                TextField("Поиск по пути", text: $searchText)
                    .textFieldStyle(.roundedBorder).frame(width: 300)
            }.padding(.top, 4)
            HStack(alignment: .top, spacing: 14) {
                changePanel(title: "Папки", changes: folderChanges, empty: hasHistoryGap ? "История неполная для выбранного периода." : "Папки не изменились.")
                changePanel(title: "Файлы", changes: fileChanges, empty: hasHistoryGap ? "История неполная для выбранного периода." : "Файлы не изменились.")
            }.frame(maxHeight: .infinity)
            if let firstRecordIndex = snapshots.firstIndex(where: { $0.id == start.id }),
               let lastRecordIndex = snapshots.firstIndex(where: { $0.id == end.id }) {
                let folderTruncated = snapshots[(firstRecordIndex + 1)...lastRecordIndex].contains(where: \.folderChangesTruncated)
                let fileTruncated = snapshots[(firstRecordIndex + 1)...lastRecordIndex].contains(where: \.fileChangesTruncated)
                if folderTruncated || fileTruncated { Text("Слишком много изменений для полного списка: показаны 500 крупнейших папок и файлов на скан.").font(.caption).foregroundStyle(.secondary) }
            }
            Text("Оценка разницы может включать снимки APFS, системные данные и недоступные файлы. Она не показывает точный перечень таких объектов.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, _ value: String, hint: String, emphasize: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 18, weight: .bold, design: .rounded)).foregroundStyle(emphasize ? .orange : .primary).lineLimit(1).minimumScaleFactor(0.7)
            Text(hint).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(2)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func metricMini(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.callout, design: .rounded, weight: .bold)).monospacedDigit()
        }.frame(minWidth: 90, alignment: .trailing)
    }

    private func changePanel(title: String, changes: [SnapshotChange], empty: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: title == "Папки" ? "folder.fill" : "doc.fill").font(.headline)
                Spacer()
                Text("\(changes.count)").font(.caption.monospacedDigit().bold()).foregroundStyle(.secondary)
            }
            if changes.isEmpty {
                ContentUnavailableView(empty, systemImage: title == "Папки" ? "folder" : "doc", description: Text("Попробуйте выбрать другой период или очистить поиск."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(changes) { change in SnapshotChangeRow(change: change) }
                    }
                }
            }
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
    }

    private func matches(_ change: SnapshotChange) -> Bool {
        searchText.isEmpty || change.path.localizedCaseInsensitiveContains(searchText)
    }

    private func snapshotLabelText(_ snapshot: DiskSnapshot) -> String {
        "\(dateLabel(snapshot.date)) · занято \(humanSize(snapshot.scannedBytes))"
    }
    private func dateLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
    private func signedSize(_ amount: Int64) -> String { (amount > 0 ? "+" : amount < 0 ? "−" : "") + humanSize(amount.magnitude > UInt64(Int64.max) ? Int64.max : Int64(amount.magnitude)) }
    private func delta(_ current: Int64?, from previous: Int64?) -> String {
        guard let current, let previous else { return "—" }
        let change = current - previous
        return change == 0 ? "без изменений" : (change < 0 ? "−" : "+") + humanSize(change.magnitude > UInt64(Int64.max) ? Int64.max : Int64(change.magnitude))
    }
}

private struct SnapshotChangeRow: View {
    let change: SnapshotChange

    private var added: Bool { change.beforeBytes == 0 && change.afterBytes > 0 }
    private var removed: Bool { change.beforeBytes > 0 && change.afterBytes == 0 }
    private var statusTitle: String { added ? "Добавлен" : removed ? "Удалён" : change.bytesDelta > 0 ? "Стало больше" : "Стало меньше" }
    private var statusIcon: String { added ? "plus.circle.fill" : removed ? "minus.circle.fill" : change.bytesDelta > 0 ? "arrow.up.right.circle.fill" : "arrow.down.right.circle.fill" }
    private var statusColor: Color { change.bytesDelta > 0 ? .orange : .green }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: statusIcon).foregroundStyle(statusColor).frame(width: 18).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(change.path).font(.system(.caption, design: .monospaced)).lineLimit(2).truncationMode(.middle)
                    .textSelection(.enabled).help(change.path)
                HStack(spacing: 6) {
                    Text(statusTitle).foregroundStyle(statusColor)
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(humanSize(change.beforeBytes)) → \(humanSize(change.afterBytes))").foregroundStyle(.secondary)
                }.font(.system(size: 10))
            }
            Spacer(minLength: 6)
            Text(signedSize(change.bytesDelta)).font(.system(.caption, design: .rounded, weight: .bold)).monospacedDigit().foregroundStyle(statusColor)
        }
        .padding(.vertical, 9).padding(.horizontal, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Скопировать полный путь") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(change.path, forType: .string)
            }
            Button("Показать в Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: change.path)])
            }.disabled(!FileManager.default.fileExists(atPath: change.path))
        }
        Divider()
    }

    private func signedSize(_ amount: Int64) -> String {
        (amount > 0 ? "+" : amount < 0 ? "−" : "") + humanSize(amount.magnitude > UInt64(Int64.max) ? Int64.max : Int64(amount.magnitude))
    }
}

struct RemoteView: View {
    @EnvironmentObject var model: AppModel; @Environment(\.dismiss) var dismiss
    @State var kind = "SSH"; @State var host = ""; @State var path = "/home"
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Сервер и облачное хранилище").font(.title.bold())
            Picker("Источник", selection: $kind) { Text("SSH").tag("SSH"); Text("rclone").tag("rclone") }.pickerStyle(.segmented)
                .onChange(of: kind) { _, value in path = value == "SSH" ? "/home" : "" }
            if kind == "SSH" {
                TextField("user@host или алиас из ~/.ssh/config", text: $host).textFieldStyle(.roundedBorder)
                Text("Используется существующий SSH-ключ или агент и запись known_hosts. Интерактивные пароли не поддерживаются. На сервере нужен Python 3. Агент на сервер не устанавливается.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Укажите настроенный источник rclone, например drive:Projects. Используются существующие настройки rclone. Аккаунты и пароли в QuickDisk не сохраняются.").font(.callout).foregroundStyle(.secondary)
                HStack { Text(Commands.executable("rclone") == nil ? "rclone не найден" : "rclone найден").foregroundStyle(.orange); Spacer(); Link("Документация rclone", destination: URL(string: "https://rclone.org/docs/")!) }
            }
            TextField(kind == "SSH" ? "Абсолютный путь на сервере" : "remote:path", text: $path).textFieldStyle(.roundedBorder)
            Text("QuickDisk отправит команду чтения выбранного каталога на указанный сервер или в настроенный облачный сервис. Результат доступен только для просмотра.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Отмена") { dismiss() }; Spacer(); Button("Сканировать") { model.remote(kind: kind, host: host, path: path); dismiss() }.buttonStyle(.borderedProminent).disabled(path.isEmpty || (kind == "SSH" && (host.isEmpty || !path.hasPrefix("/")))) }
        }.padding(28).frame(width: 620)
    }
}
struct DuplicateView: View {
    @EnvironmentObject var model: AppModel; @Environment(\.dismiss) var dismiss
    @State private var extra: [URL] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Поиск дубликатов").font(.title.bold()); Spacer(); Button("Закрыть") { dismiss() } }
            Text("Сравниваются полные SHA‑256 содержимого. Файлы нулевого размера и файлы только в облаке пропускаются. Жёсткие ссылки не считаются копиями.").font(.callout).foregroundStyle(.secondary)
            HStack {
                Button("Добавить папки…") { let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true; if panel.runModal() == .OK { for url in panel.urls { model.rememberAccess(for: url) }; extra = Array(Set(extra + panel.urls)).sorted { $0.path < $1.path } } }.disabled(model.duplicateBusy)
                Spacer()
                if model.duplicateBusy { ProgressView().controlSize(.small); Button("Остановить") { model.cancelDuplicates() } }
                else { Button("Найти совпадения") { model.findDuplicates(extra: extra) }.buttonStyle(.borderedProminent) }
            }
            if let root = model.result?.root, !root.remote { Text("Текущий источник: \(root.id)").font(.caption).foregroundStyle(.secondary) }
            ForEach(extra, id: \.path) { url in HStack { Text(url.path).font(.caption).lineLimit(1).truncationMode(.middle); Spacer(); Button { extra.removeAll { $0 == url } } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).disabled(model.duplicateBusy) } }
            Text(model.duplicateStatus).font(.caption).foregroundStyle(.orange)
            if model.duplicateGroups.isEmpty { ContentUnavailableView("Совпадений пока нет", systemImage: "doc.on.doc", description: Text("Добавьте папки или используйте текущий локальный результат сканирования")) }
            else {
                Text("Объём повторных копий: \(humanSize(model.duplicateGroups.reduce(0) { $0 + $1.savings }))").font(.headline)
                List(model.duplicateGroups) { group in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text("\(group.files.count) одинаковых файлов").font(.headline); Spacer(); Text(humanSize(group.savings)).foregroundStyle(.orange) }
                        ForEach(group.files) { file in HStack { Image(systemName: "doc").foregroundStyle(.indigo); Text(file.id).font(.system(.caption, design: .monospaced)).textSelection(.enabled).lineLimit(2); Spacer(); Button("Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) } } }
                    }.padding(.vertical, 8)
                }.listStyle(.plain)
            }
            Text("Результаты справочные: QuickDisk не выбирает и не удаляет копии.").font(.caption2).foregroundStyle(.secondary)
        }.padding(26).frame(width: 900, height: 650)
    }
}
