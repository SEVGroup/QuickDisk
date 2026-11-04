import Foundation
import Darwin

enum CLI {
    static func run() {
        let args = CommandLine.arguments
        let path = args[2]; let token = StopToken()
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { fputs("Папка не найдена: \(path)\n", stderr); exit(2) }
        let result = Scanner.scan(URL(fileURLWithPath: path), stop: token) { progress in
            if args.contains("--progress") { fputs("\(progress.files) файлов · \(humanSize(progress.bytes)) · \(progress.path)\n", stderr) }
        }
        if args.contains("--json") {
            let rows: [[String: Any]] = result.root.flatten().map { ["path": $0.id, "allocatedBytes": $0.bytes, "logicalBytes": $0.logical, "directory": $0.isDirectory, "files": $0.count, "error": $0.issue ?? ""] }
            let data = try! JSONSerialization.data(withJSONObject: ["entries": rows, "errors": result.errors, "seconds": result.seconds], options: [.prettyPrinted, .sortedKeys]); print(String(decoding: data, as: UTF8.self))
        } else {
            func option(_ key: String, fallback: Int) -> Int { if let i = args.firstIndex(of: key), args.indices.contains(i + 1), let n = Int(args[i + 1]) { return max(0, n) }; return fallback }
            let depth = option("--depth", fallback: 2), top = option("--top", fallback: 15)
            func tree(_ n: DiskNode, _ level: Int) { print(String(repeating: "  ", count: level) + humanSize(n.bytes) + "  " + n.name); if level < depth { for child in n.sorted.prefix(top) { tree(child, level + 1) } } }; tree(result.root, 0)
            fputs("\(result.root.count) файлов; ошибок: \(result.errors.count); \(String(format: "%.2f", result.seconds)) с\n", stderr)
        }
    }
}
enum SelfCheck {
    static func run() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("quickdisk-selfcheck-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
        func check(_ condition: Bool, _ message: String) throws { if !condition { throw CommandFailure(message: message) } }
        let a = root.appendingPathComponent("a.bin"); let b = root.appendingPathComponent("renamed.bin")
        let data = Data((0..<20000).map { UInt8($0 % 251) }); try data.write(to: a); try data.write(to: b)
        try fm.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        try fm.linkItem(at: a, to: root.appendingPathComponent("hardlink.bin"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("other.bin"))
        let token = StopToken(); let result = Scanner.scan(root, stop: token)
        try check(result.root.count == 3, "hardlinks or symlinks counted twice")
        try check(result.root.logical == 40003, "incorrect logical aggregate")
        try check(result.skipped == 2, "links were not skipped")
        try check(result.root.children.contains { $0.name == "empty" && $0.bytes == 0 }, "empty directory lost")
        let duplicate = Duplicates.find([result.root], stop: token) { _, _ in }
        try check(duplicate.groups.count == 1 && duplicate.groups[0].files.count == 2, "content duplicate detection failed")
        try check(duplicate.errors.isEmpty, "unexpected duplicate errors")
        let cancelled = StopToken(); cancelled.cancel()
        try check(Scanner.scan(root, stop: cancelled).cancelled, "scan cancellation failed")
        let remote = RemoteScan.tree(label: "cloud://sample:", entries: [.init(path: "dir/a", directory: false, size: 7), .init(path: "dir/b", directory: false, size: 9), .init(path: "../escape", directory: false, size: 99)])
        try check(remote.bytes == 16 && remote.count == 2, "remote tree aggregation failed")
        try check(remote.children.first?.parent === remote, "remote parent link failed")
        try check(Commands.quote("a'b") == "'a'\\''b'", "SSH argument quoting failed")
        let imported = try JSONSerialization.data(withJSONObject: ["bytes": result.root.bytes, "files": result.root.count]); try check(!imported.isEmpty, "JSON encoding failed")
        print("PASS: scanner totals, inode deduplication, symlink loops, empty folders, SHA-256 duplicates, cancellation, remote tree, path validation, SSH quoting, JSON")
    }
}
