import Foundation
import CryptoKit
import Darwin

func humanSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
final class StopToken: @unchecked Sendable {
    private let lock = NSLock(); private var stopped = false
    var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func cancel() { lock.lock(); stopped = true; lock.unlock() }
}
final class DiskNode: Identifiable, @unchecked Sendable {
    let id: String; let name: String; let isDirectory: Bool
    var bytes: Int64; var logical: Int64; var count: Int = 0
    var children: [DiskNode] = []; weak var parent: DiskNode?
    var modified: Date?; var issue: String?; var remote = false; var synthetic = false; var chartName: String?
    var fingerprint: FileFingerprint?
    init(path: String, directory: Bool, bytes: Int64 = 0, logical: Int64 = 0, fingerprint: FileFingerprint? = nil) {
        id = path; name = URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent
        isDirectory = directory; self.bytes = bytes; self.logical = logical; self.fingerprint = fingerprint
    }
    var url: URL { URL(fileURLWithPath: id) }
    func attach(_ child: DiskNode) { children.append(child); child.parent = self }
    var sorted: [DiskNode] { children.sorted { $0.bytes == $1.bytes ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.bytes > $1.bytes } }
    func flatten() -> [DiskNode] { var result: [DiskNode] = []; var pending = [self]; while let n = pending.popLast() { result.append(n); pending.append(contentsOf: n.children) }; return result }
}
struct FileIdentity: Hashable { let device: dev_t; let inode: ino_t }
struct FileFingerprint: Hashable, Sendable {
    let device: UInt64; let inode: UInt64; let size: Int64; let blocks: Int64
    let modifiedSeconds: Int64; let modifiedNanoseconds: Int64; let directory: Bool; let onlineOnly: Bool
    init(_ info: stat, directory: Bool) {
        device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size); blocks = Int64(info.st_blocks)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        self.directory = directory; onlineOnly = info.st_flags & UInt32(SF_DATALESS) != 0
    }
}
struct ChangedPath: Sendable { let path: String; let removed: Bool }
struct PathSnapshot: @unchecked Sendable { let path: String; let node: DiskNode? }
struct ScanProgress: Sendable { let files: Int; let bytes: Int64; let path: String; let errors: Int; let preview: DiskNode? }
struct ScanResult: @unchecked Sendable { let root: DiskNode; let errors: [String]; let skipped: Int; let seconds: Double; let cancelled: Bool }
enum Scanner {
    static func scan(_ url: URL, stop: StopToken, progress: @escaping (ScanProgress) -> Void = { _ in }) -> ScanResult {
        let start = Date(); let fm = FileManager.default
        let rootURL = url.standardizedFileURL
        let root = DiskNode(path: rootURL.path, directory: true)
        var rootStat = stat(); _ = lstat(root.id, &rootStat)
        var allowedDevices = Set([rootStat.st_dev])
        var errors: [String] = []; var errorCount = 0; var skipped = 0; var files = 0; var total: Int64 = 0
        var seen = Set<FileIdentity>(); seen.insert(FileIdentity(device: rootStat.st_dev, inode: rootStat.st_ino))
        if root.id == "/" { var dataStat = stat(); if lstat("/System/Volumes/Data", &dataStat) == 0 { allowedDevices.insert(dataStat.st_dev) } }
        let condition = NSCondition()
        var pending = [root]; var active = 0
        var last = Date.distantPast
        let workerCount = 6
        DispatchQueue.concurrentPerform(iterations: workerCount) { _ in
            while !stop.cancelled {
                condition.lock()
                while pending.isEmpty && active > 0 && !stop.cancelled { condition.wait() }
                guard !stop.cancelled, let directory = pending.popLast() else { condition.unlock(); return }
                active += 1
                condition.unlock()
                var newChildren: [DiskNode] = []; var childDirectories: [DiskNode] = []
                var localErrors: [String] = []; var localErrorCount = 0; var localSkipped = 0; var localFiles = 0; var localBytes: Int64 = 0; var localLogical: Int64 = 0
                do {
                    let urls = try fm.contentsOfDirectory(at: directory.url, includingPropertiesForKeys: nil, options: [])
                    for file in urls {
                        if stop.cancelled { break }
                        var info = stat()
                        guard lstat(file.path, &info) == 0 else { localErrorCount += 1; if localErrors.count < 200 { localErrors.append("\(file.path): \(String(cString: strerror(errno)))") }; continue }
                        let type = info.st_mode & S_IFMT
                        if type == S_IFLNK { localSkipped += 1; continue }
                        let isDir = type == S_IFDIR
                        guard isDir || type == S_IFREG else { localSkipped += 1; continue }
                        if isDir && (!allowedDevices.contains(info.st_dev) || (root.id == "/" && file.path == "/System/Volumes/Data")) { localSkipped += 1; continue }
                        let inode = FileIdentity(device: info.st_dev, inode: info.st_ino)
                        condition.lock(); let fresh = seen.insert(inode).inserted; condition.unlock()
                        if !fresh { localSkipped += 1; continue }
                        let onlineOnly = info.st_flags & UInt32(SF_DATALESS) != 0
                        let allocated = isDir || onlineOnly ? 0 : Int64(info.st_blocks) * 512
                        let child = DiskNode(path: file.path, directory: isDir, bytes: allocated, logical: isDir ? 0 : Int64(info.st_size), fingerprint: FileFingerprint(info, directory: isDir))
                        child.modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
                        newChildren.append(child)
                        if isDir { childDirectories.append(child) } else { localFiles += 1; localBytes += allocated; localLogical += child.logical; child.count = 1 }
                    }
                } catch {
                    directory.issue = error.localizedDescription; localErrorCount += 1
                    if localErrors.count < 200 { localErrors.append("\(directory.id): \(error.localizedDescription)") }
                }
                condition.lock()
                for child in newChildren { directory.attach(child) }
                pending.append(contentsOf: childDirectories)
                active -= 1
                var ancestor: DiskNode? = directory
                while let node = ancestor { node.bytes += localBytes; node.logical += localLogical; node.count += localFiles; ancestor = node.parent }
                files += localFiles; total += localBytes; skipped += localSkipped; errorCount += localErrorCount
                if errors.count < 200 { errors.append(contentsOf: localErrors.prefix(200 - errors.count)) }
                if Date().timeIntervalSince(last) > 0.6 {
                    var previewBudget = 1200
                    func preview(_ n: DiskNode, _ level: Int) -> DiskNode {
                        previewBudget -= 1
                        let copy = DiskNode(path: n.id, directory: n.isDirectory, bytes: n.bytes, logical: n.logical); copy.count = n.count
                        if level > 0 {
                            for c in n.sorted.prefix(100) { guard previewBudget > 0 else { break }; copy.attach(preview(c, level - 1)) }
                            let remaining = n.bytes - copy.children.reduce(0) { $0 + $1.bytes }
                            if remaining > 0 { let rest = DiskNode(path: n.id + "/… остальные элементы", directory: false, bytes: remaining); rest.remote = true; copy.attach(rest) }
                        }
                        return copy
                    }
                    progress(ScanProgress(files: files, bytes: total, path: directory.id, errors: errorCount, preview: preview(root, 3)))
                    last = Date()
                }
                condition.broadcast(); condition.unlock()
            }
        }
        for n in root.flatten().reversed() where n.isDirectory { n.bytes = n.children.reduce(0) { $0 + $1.bytes }; n.logical = n.children.reduce(0) { $0 + $1.logical }; n.count = n.children.reduce(0) { $0 + $1.count } }
        return ScanResult(root: root, errors: errors, skipped: skipped, seconds: Date().timeIntervalSince(start), cancelled: stop.cancelled)
    }

    static func snapshotChanges(_ changes: [ChangedPath], root: DiskNode, knownChildren: [String: Set<String>], stop: StopToken) -> [PathSnapshot] {
        var rootInfo = stat(); _ = lstat(root.id, &rootInfo)
        var allowedDevices = Set([rootInfo.st_dev])
        if root.id == "/" { var dataInfo = stat(); if lstat("/System/Volumes/Data", &dataInfo) == 0 { allowedDevices.insert(dataInfo.st_dev) } }
        let ordered = changes.sorted { $0.path.filter { $0 == "/" }.count < $1.path.filter { $0 == "/" }.count }
        return ordered.compactMap { change in
            if stop.cancelled { return nil }
            guard !change.removed else { return PathSnapshot(path: change.path, node: nil) }
            let recursiveNewDirectories = true
            let node = snapshot(URL(fileURLWithPath: change.path), root: root, allowedDevices: allowedDevices,
                                existingPaths: knownChildren[change.path] ?? [], scanContents: true,
                                recursiveNewDirectories: recursiveNewDirectories, stop: stop)
            return node == nil ? nil : PathSnapshot(path: change.path, node: node)
        }
    }

    private static func snapshot(_ url: URL, root: DiskNode, allowedDevices: Set<dev_t>, existingPaths: Set<String>, scanContents: Bool, recursiveNewDirectories: Bool, stop: StopToken) -> DiskNode? {
        if stop.cancelled { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        let type = info.st_mode & S_IFMT
        guard type == S_IFDIR || type == S_IFREG else { return nil }
        let isDirectory = type == S_IFDIR
        if isDirectory && (!allowedDevices.contains(info.st_dev) || (root.id == "/" && url.path == "/System/Volumes/Data")) { return nil }
        let onlineOnly = info.st_flags & UInt32(SF_DATALESS) != 0
        let allocated = isDirectory || onlineOnly ? 0 : Int64(info.st_blocks) * 512
        let node = DiskNode(path: url.path, directory: isDirectory, bytes: allocated,
                            logical: isDirectory ? 0 : Int64(info.st_size), fingerprint: FileFingerprint(info, directory: isDirectory))
        node.modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec))
        if !isDirectory { node.count = 1; return node }
        guard scanContents else { return node }
        do {
            for childURL in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) {
                if stop.cancelled { break }
                let childIsKnown = existingPaths.contains(childURL.path)
                guard let child = snapshot(childURL, root: root, allowedDevices: allowedDevices, existingPaths: [],
                                           scanContents: !childIsKnown,
                                           recursiveNewDirectories: recursiveNewDirectories && !childIsKnown, stop: stop) else { continue }
                node.attach(child)
            }
            node.bytes = node.children.reduce(0) { $0 + $1.bytes }
            node.logical = node.children.reduce(0) { $0 + $1.logical }
            node.count = node.children.reduce(0) { $0 + $1.count }
        } catch { node.issue = error.localizedDescription }
        return node
    }
}
struct DuplicateGroup: Identifiable, @unchecked Sendable {
    let id: String; let files: [DiskNode]
    var savings: Int64 { Int64(files.count - 1) * (files.first?.bytes ?? 0) }
}
enum Duplicates {
    static func hash(_ url: URL, stop: StopToken) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while !stop.cancelled { guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }; hash.update(data: data) }
        if stop.cancelled { throw CancellationError() }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func find(_ roots: [DiskNode], stop: StopToken, progress: @escaping (Int, Int) -> Void) -> (groups: [DuplicateGroup], errors: [String]) {
        var seen = Set<FileIdentity>(); var nodes: [DiskNode] = []
        for n in roots.flatMap({ $0.flatten() }) where !n.isDirectory && n.logical > 0 && n.bytes > 0 && !n.remote {
            var info = stat(); guard lstat(n.id, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            if seen.insert(FileIdentity(device: info.st_dev, inode: info.st_ino)).inserted { nodes.append(n) }
        }
        let candidates = Dictionary(grouping: nodes, by: { $0.logical }).values.filter { $0.count > 1 }.flatMap { $0 }
        var hashes: [String: [DiskNode]] = [:]; var errors: [String] = []
        for (i, node) in candidates.enumerated() {
            if stop.cancelled { break }
            do {
                let before = try node.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let key = try hash(node.url, stop: stop)
                let after = try node.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate else { errors.append("Изменён во время проверки: \(node.id)"); continue }
                hashes[key, default: []].append(node)
            } catch { if !stop.cancelled { errors.append("\(node.id): \(error.localizedDescription)") } }
            progress(i + 1, candidates.count)
        }
        let result = hashes.filter { $0.value.count > 1 }.map { DuplicateGroup(id: $0.key, files: $0.value.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }) }.sorted { $0.savings > $1.savings }
        return (result, errors)
    }
}
