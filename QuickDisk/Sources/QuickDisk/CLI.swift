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
        let cacheRoot = fm.temporaryDirectory.appendingPathComponent("quickdisk-cachefixture-\(UUID().uuidString)")
        let cacheURL = fm.temporaryDirectory.appendingPathComponent("quickdisk-cache-\(UUID().uuidString).qdcache")
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true); defer { try? fm.removeItem(at: cacheRoot); try? fm.removeItem(at: cacheURL) }
        for index in 0..<650 { try Data([UInt8(index % 251)]).write(to: cacheRoot.appendingPathComponent("item-\(index).bin")) }
        let cacheScan = Scanner.scan(cacheRoot, stop: token)
        try ScanCacheStore.save(root: cacheScan.root, eventID: 42, errors: cacheScan.errors, skipped: cacheScan.skipped, to: cacheURL)
        guard let (cachedRoot, cacheEventID, cacheErrors, cacheSkipped, legacy) = ScanCacheStore.load(path: cacheRoot.path, cacheURL: cacheURL) else { throw CommandFailure(message: "persistent cache could not be opened") }
        try check(!legacy && cacheEventID == 42 && cacheErrors == cacheScan.errors && cacheSkipped == cacheScan.skipped && cachedRoot.count == cacheScan.root.count && cachedRoot.bytes == cacheScan.root.bytes, "persistent cache metadata failed")
        try check(cachedRoot.hasMoreChildren && cachedRoot.children.count == 500 && cachedRoot.hasMoreChildren, "lazy cache page loading failed")
        cachedRoot.loadAllChildren(); try check(cachedRoot.children.count == 650 && !cachedRoot.hasMoreChildren, "lazy cache completion failed")
        try fm.removeItem(at: cacheURL)
        try check(result.skipped == 2, "links were not skipped")
        try check(result.root.children.contains { $0.name == "empty" && $0.bytes == 0 }, "empty directory lost")
        let duplicate = Duplicates.find([result.root], stop: token) { _, _ in }
        try check(duplicate.groups.count == 1 && duplicate.groups[0].files.count == 2, "content duplicate detection failed")
        try check(duplicate.errors.isEmpty, "unexpected duplicate errors")
        var identities = result.fileIdentities
        func update(_ changes: [ChangedPath]) {
            var expanded = changes
            for change in changes where change.removed { expanded.append(ChangedPath(path: URL(fileURLWithPath: change.path).deletingLastPathComponent().path, removed: false)) }
            var known: [String: Set<String>] = [:]
            for change in expanded {
                if let node = TreeUpdater.node(at: change.path, in: result.root), node.isDirectory { known[change.path] = Set(node.children.map(\.id)) }
            }
            let snapshots = Scanner.snapshotChanges(expanded, root: result.root, knownChildren: known, stop: token)
            _ = TreeUpdater.apply(snapshots, to: result.root, fileIdentities: &identities)
        }
        var aInfo = stat(); _ = lstat(a.path, &aInfo)
        let linkedIdentity = FileIdentity(device: aInfo.st_dev, inode: aInfo.st_ino)
        let newLink = root.appendingPathComponent("added-hardlink.bin")
        try fm.linkItem(at: a, to: newLink)
        update([ChangedPath(path: root.path, removed: false)])
        try check(result.root.count == 3 && identities.count == 3, "incremental hardlink addition was counted twice")
        let countedLink = result.root.flatten().first { node in
            guard !node.isDirectory, let fingerprint = node.fingerprint else { return false }
            return fingerprint.device == UInt64(linkedIdentity.device) && fingerprint.inode == UInt64(linkedIdentity.inode)
        }
        try check(countedLink != nil, "no representative path retained for hardlink identity")
        try fm.removeItem(at: URL(fileURLWithPath: countedLink!.id))
        update([ChangedPath(path: countedLink!.id, removed: true)])
        let aliasesAfterDelete = result.root.flatten().filter { node in
            guard !node.isDirectory, let fingerprint = node.fingerprint else { return false }
            return fingerprint.device == UInt64(linkedIdentity.device) && fingerprint.inode == UInt64(linkedIdentity.inode)
        }
        try check(result.root.count == 3 && aliasesAfterDelete.count == 1 && identities.count == 3, "deleting a hardlink representative did not retain exactly one alias")
        let fresh = root.appendingPathComponent("fresh.bin"); try Data([4, 5, 6, 7, 8]).write(to: fresh)
        update([ChangedPath(path: fresh.path, removed: false)])
        try check(result.root.count == 4 && result.root.logical == 40008, "incremental file addition totals failed")
        let renamed = root.appendingPathComponent("fresh-renamed.bin"); try fm.moveItem(at: fresh, to: renamed)
        update([ChangedPath(path: fresh.path, removed: true), ChangedPath(path: renamed.path, removed: false)])
        try check(result.root.count == 4 && result.root.logical == 40008 && TreeUpdater.node(at: renamed.path, in: result.root) != nil, "incremental rename recovery failed")
        try Data([1, 2, 3, 4, 5, 6]).write(to: root.appendingPathComponent("other.bin"))
        update([ChangedPath(path: root.appendingPathComponent("other.bin").path, removed: false)])
        try check(result.root.count == 4 && result.root.logical == 40011, "incremental file modification totals failed")
        let newDirectory = root.appendingPathComponent("new-folder")
        try fm.createDirectory(at: newDirectory, withIntermediateDirectories: true)
        try Data([7, 8, 9, 10, 11, 12, 13]).write(to: newDirectory.appendingPathComponent("nested.bin"))
        update([ChangedPath(path: newDirectory.path, removed: false)])
        try check(result.root.count == 5 && result.root.logical == 40018 && TreeUpdater.node(at: newDirectory.appendingPathComponent("nested.bin").path, in: result.root) != nil, "new directory subtree was not scanned")
        try fm.removeItem(at: renamed); update([ChangedPath(path: renamed.path, removed: true)])
        try check(result.root.count == 4 && result.root.logical == 40013 && identities.count == 4, "incremental file removal totals failed")
        let cancelled = StopToken(); cancelled.cancel()
        try check(Scanner.scan(root, stop: cancelled).cancelled, "scan cancellation failed")
        let remote = RemoteScan.tree(label: "cloud://sample:", entries: [.init(path: "dir/a", directory: false, size: 7), .init(path: "dir/b", directory: false, size: 9), .init(path: "../escape", directory: false, size: 99)])
        try check(remote.bytes == 16 && remote.count == 2, "remote tree aggregation failed")
        try check(remote.children.first?.parent === remote, "remote parent link failed")
        try check(Commands.quote("a'b") == "'a'\\''b'", "SSH argument quoting failed")
        let imported = try JSONSerialization.data(withJSONObject: ["bytes": result.root.bytes, "files": result.root.count]); try check(!imported.isEmpty, "JSON encoding failed")
        print("PASS: scanner totals, hardlink deduplication, incremental add/update/remove/rename recovery, persistent cache serialization, new subtrees, symlink loops, empty folders, SHA-256 duplicates, cancellation, remote tree, SSH quoting, JSON")
    }
}
