import SwiftUI
import AppKit

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    @AppStorage("theme") var theme = "dark"
    @AppStorage("depth") var depth = 6
    @AppStorage("watch") var watch = false
    @AppStorage("cacheEnabled") var cacheEnabled = true
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
                Text("Кэш содержит только имена и метаданные файлов, не их содержимое. При выключении уже созданные файлы кэша остаются на диске, но QuickDisk больше не читает и не обновляет их. Явный экспорт PDF работает отдельно от настройки кэша.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Кэш отключён: QuickDisk не открывает и не создаёт снимки дерева. Полный скан будет выполняться каждый раз. Уже существующие файлы кэша не удаляются.").font(.callout).foregroundStyle(.secondary)
            }
            Text("QuickDisk 0.3.0 · macOS 14+\nУниверсальная сборка: Apple Silicon и Intel.\nТолько просмотр: приложение не удаляет и не перемещает ваши файлы.\nНет рекламы, аккаунтов, аналитики и фоновой проверки обновлений.\nЗакладки доступа и настройки кэша хранятся локально на этом Mac.").font(.callout).foregroundStyle(.secondary)
            Text("Выделенный объём — сумма блоков файлов, а не уникальное место APFS. Скрытое место — оценка разницы с ёмкостью тома; она может включать снимки и клоны APFS, сжатие, системные и недоступные данные. Облачные источники показывают размер объектов.").font(.caption).foregroundStyle(.secondary)
            Text("Клавиши: ⌘R — полный повторный скан; ⌘[ / ⌘] — назад и вперёд; ⌘O — выбрать папку.").font(.caption).foregroundStyle(.secondary)
        }.padding(28).frame(width: 650, height: 740)
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
