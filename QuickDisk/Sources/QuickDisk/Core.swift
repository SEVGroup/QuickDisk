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
    fileprivate var rootPath: String?; let name: String; let isDirectory: Bool
    var bytes: Int64; var logical: Int64; var count: Int = 0
    private var storedChildren: [DiskNode] = []; private var lazyChildLoader: ((Int, Int) -> [DiskNode])?
    private var lazyChildrenTotal = 0; private var lazyChildrenLoaded = 0
    weak var parent: DiskNode?
    var modified: Date?; var issue: String?; var remote = false; var synthetic = false; var chartName: String?
    var fingerprint: FileFingerprint?
    init(path: String, directory: Bool, bytes: Int64 = 0, logical: Int64 = 0, fingerprint: FileFingerprint? = nil) {
        rootPath = path; name = URL(fileURLWithPath: path).lastPathComponent.isEmpty ? path : URL(fileURLWithPath: path).lastPathComponent
        isDirectory = directory; self.bytes = bytes; self.logical = logical; self.fingerprint = fingerprint
    }
    init(name: String, directory: Bool, bytes: Int64 = 0, logical: Int64 = 0, fingerprint: FileFingerprint? = nil) {
        rootPath = nil; self.name = name; isDirectory = directory; self.bytes = bytes; self.logical = logical; self.fingerprint = fingerprint
    }
    var id: String {
        if let rootPath { return rootPath }
        guard let parent else { return name }
        let parentPath = parent.id
        return parentPath.hasSuffix("/") ? parentPath + name : parentPath + "/" + name
    }
    var url: URL { URL(fileURLWithPath: id) }
    var children: [DiskNode] {
        get {
            if storedChildren.isEmpty, lazyChildLoader != nil { loadMoreChildren() }
            return storedChildren
        }
        set {
            storedChildren = newValue; lazyChildLoader = nil; lazyChildrenTotal = newValue.count; lazyChildrenLoaded = newValue.count
        }
    }
    var hasMoreChildren: Bool { lazyChildLoader != nil }
    var childrenLoadedCount: Int { lazyChildrenLoaded }
    var childrenTotalCount: Int { lazyChildLoader == nil ? storedChildren.count : lazyChildrenTotal }
    func installLazyChildren(total: Int, loader: @escaping (Int, Int) -> [DiskNode]) {
        lazyChildrenTotal = total; lazyChildrenLoaded = 0
        lazyChildLoader = total > 0 ? loader : nil
    }
    @discardableResult func loadMoreChildren(batchSize: Int = 500) -> Int {
        guard let loader = lazyChildLoader else { return 0 }
        let page = loader(lazyChildrenLoaded, batchSize)
        for child in page { storedChildren.append(child); child.setParent(self) }
        lazyChildrenLoaded += page.count
        if lazyChildrenLoaded >= lazyChildrenTotal || page.isEmpty { lazyChildLoader = nil }
        return page.count
    }
    func loadAllChildren() { while hasMoreChildren { _ = loadMoreChildren(batchSize: 4096) } }
    func attach(_ child: DiskNode) { storedChildren.append(child); child.setParent(self) }
    func setParent(_ parent: DiskNode) {
        self.parent = parent
        if isDirectory {
            let parentPath = parent.id
            rootPath = parentPath.hasSuffix("/") ? parentPath + name : parentPath + "/" + name
        }
        else { rootPath = nil }
    }
    var sorted: [DiskNode] { children.sorted { $0.bytes == $1.bytes ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.bytes > $1.bytes } }
    func flatten() -> [DiskNode] { var result: [DiskNode] = []; var pending = [self]; while let n = pending.popLast() { n.loadAllChildren(); result.append(n); pending.append(contentsOf: n.children) }; return result }
}
struct FileIdentity: Hashable, Sendable { let device: dev_t; let inode: ino_t }
private final class IdentityShard {
    let lock = NSLock(); var seen = Set<FileIdentity>(); var files = Set<FileIdentity>()
}
private final class ConcurrentIdentitySet: @unchecked Sendable {
    private let shards = (0..<64).map { _ in IdentityShard() }
    func insert(_ identity: FileIdentity, file: Bool) -> Bool {
        let shard = shards[Int(UInt(bitPattern: identity.hashValue) & 63)]
        shard.lock.lock(); defer { shard.lock.unlock() }
        guard shard.seen.insert(identity).inserted else { return false }
        if file { shard.files.insert(identity) }
        return true
    }
    var files: Set<FileIdentity> { shards.reduce(into: Set<FileIdentity>()) { result, shard in shard.lock.lock(); result.formUnion(shard.files); shard.lock.unlock() } }
}
enum TopItems {
    static func largest(_ items: [DiskNode], limit: Int) -> [DiskNode] {
        guard limit > 0, items.count > limit else { return items.sorted { $0.bytes > $1.bytes } }
        var heap: [DiskNode] = []; heap.reserveCapacity(limit)
        func less(_ a: DiskNode, _ b: DiskNode) -> Bool { a.bytes < b.bytes }
        for item in items {
            if heap.count < limit {
                heap.append(item); var i = heap.count - 1
                while i > 0 { let p = (i - 1) / 2; if !less(heap[i], heap[p]) { break }; heap.swapAt(i, p); i = p }
            } else if less(heap[0], item) {
                heap[0] = item; var i = 0
                while true { let l = i * 2 + 1; let r = l + 1; var s = i; if l < heap.count && less(heap[l], heap[s]) { s = l }; if r < heap.count && less(heap[r], heap[s]) { s = r }; if s == i { break }; heap.swapAt(i, s); i = s }
            }
        }
        return heap.sorted { $0.bytes > $1.bytes }
    }
}
private struct LegacyCachedEntry: Codable {
    let parent: Int; let name: String; let directory: Bool; let bytes: Int64; let logical: Int64; let count: Int
    let modified: Date?; let issue: String?; let fingerprint: FileFingerprint?
}
extension FileFingerprint: Codable {}
private struct LegacyScanCache: Codable { let rootPath: String; let eventID: UInt64; let errors: [String]; let skipped: Int; let entries: [LegacyCachedEntry] }
private final class BinaryTreeCache {
    private static let stride = 17 * MemoryLayout<UInt64>.size
    private let data: Data; private let recordsStart: Int; private let stringsStart: Int
    private let nodeCount: Int; let rootPath: String; let eventID: UInt64; let errors: [String]; let skipped: Int
    init?(data: Data) {
        guard data.count >= 56, String(decoding: data.prefix(8), as: UTF8.self) == "QDCACHE2" else { return nil }
        self.data = data
        var cursor = 8
        let rootLength = Int(Self.read(data, cursor)); cursor += 8
        eventID = Self.read(data, cursor); cursor += 8
        skipped = Int(Self.read(data, cursor)); cursor += 8
        let errorCount = Int(Self.read(data, cursor)); cursor += 8
        nodeCount = Int(Self.read(data, cursor)); cursor += 8
        let stringsLength = Int(Self.read(data, cursor)); cursor += 8
        guard rootLength >= 0, rootLength <= data.count - cursor else { return nil }
        rootPath = String(decoding: data[cursor..<(cursor + rootLength)], as: UTF8.self); cursor += rootLength
        var parsedErrors: [String] = []; parsedErrors.reserveCapacity(min(errorCount, 200))
        for _ in 0..<errorCount {
            guard data.count - cursor >= 8 else { return nil }
            let length = Int(Self.read(data, cursor)); cursor += 8
            guard length >= 0, length <= data.count - cursor else { return nil }
            parsedErrors.append(String(decoding: data[cursor..<(cursor + length)], as: UTF8.self)); cursor += length
        }
        errors = parsedErrors; recordsStart = cursor
        let (recordBytes, overflow) = nodeCount.multipliedReportingOverflow(by: Self.stride)
        guard nodeCount > 0, !overflow, recordBytes <= data.count - recordsStart else { return nil }
        stringsStart = recordsStart + recordBytes
        guard stringsLength >= 0, stringsLength <= data.count - stringsStart else { return nil }
    }
    var root: DiskNode { makeNode(0) }
    private func word(_ index: Int, _ field: Int) -> UInt64 { Self.read(data, recordsStart + index * Self.stride + field * 8) }
    private func makeNode(_ index: Int) -> DiskNode {
        let flags = word(index, 6); let directory = flags & 1 != 0
        let nameOffset = Int(word(index, 2)); let nameLength = Int(word(index, 3))
        let name = index == 0 ? rootPath : string(at: nameOffset, length: nameLength)
        var fingerprint: FileFingerprint?
        if flags & 4 != 0 {
            var modified = timespec(); modified.tv_sec = Int(Int64(bitPattern: word(index, 15))); modified.tv_nsec = Int(Int64(bitPattern: word(index, 16)))
            fingerprint = FileFingerprint(device: dev_t(word(index, 11)), inode: word(index, 12), size: Int64(bitPattern: word(index, 13)), blocks: Int64(bitPattern: word(index, 14)), modified: modified, directory: directory, flags: flags & 8 != 0 ? UInt32(SF_DATALESS) : 0)
        }
        let node = index == 0 ? DiskNode(path: name, directory: directory, bytes: Int64(bitPattern: word(index, 7)), logical: Int64(bitPattern: word(index, 8)), fingerprint: fingerprint) : DiskNode(name: name, directory: directory, bytes: Int64(bitPattern: word(index, 7)), logical: Int64(bitPattern: word(index, 8)), fingerprint: fingerprint)
        node.count = Int(word(index, 9))
        if flags & 2 != 0 { node.modified = Date(timeIntervalSince1970: Double(bitPattern: word(index, 10))) }
        let issueOffset = word(index, 4), issueLength = Int(word(index, 5))
        if issueOffset != UInt64.max { node.issue = string(at: Int(issueOffset), length: issueLength) }
        let first = word(index, 0), total = Int(word(index, 1))
        if first != UInt64.max, total > 0 {
            node.installLazyChildren(total: total) { [self] cursor, limit in
                let lower = Int(first) + cursor; let upper = min(Int(first) + total, lower + limit)
                return (lower..<upper).map(makeNode)
            }
        }
        return node
    }
    private func string(at offset: Int, length: Int) -> String {
        guard offset >= 0, length >= 0, offset + length <= data.count - stringsStart else { return "" }
        let lower = stringsStart + offset
        return String(decoding: data[lower..<(lower + length)], as: UTF8.self)
    }
    private static func read(_ data: Data, _ offset: Int) -> UInt64 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian } }
}
enum ScanCacheStore {
    static func url(for path: String, directory: URL? = nil) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("QuickDisk/ScanCache", isDirectory: true)
        return base.appendingPathComponent("\(digest).qdcache")
    }
    static func save(root: DiskNode, eventID: UInt64, errors: [String], skipped: Int, to target: URL? = nil) throws {
        var nodes = [root]; var ranges: [(UInt64, UInt64)] = [(UInt64.max, 0)]; var index = 0
        while index < nodes.count {
            let sorted = nodes[index].children.sorted { $0.bytes == $1.bytes ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.bytes > $1.bytes }
            if !sorted.isEmpty { ranges[index] = (UInt64(nodes.count), UInt64(sorted.count)); nodes.append(contentsOf: sorted); ranges.append(contentsOf: repeatElement((UInt64.max, UInt64(0)), count: sorted.count)) }
            index += 1
        }
        let pathData = Data(root.id.utf8); var stringsLength = 0
        for node in nodes { stringsLength += node.name.utf8.count + (node.issue?.utf8.count ?? 0) }
        var header = Data("QDCACHE2".utf8)
        append(UInt64(pathData.count), to: &header); append(eventID, to: &header); append(UInt64(skipped), to: &header); append(UInt64(errors.count), to: &header); append(UInt64(nodes.count), to: &header); append(UInt64(stringsLength), to: &header)
        header.append(pathData)
        for error in errors { let bytes = Data(error.utf8); var length = Data(); append(UInt64(bytes.count), to: &length); header.append(length); header.append(bytes) }
        let finalURL = target ?? url(for: root.id); try FileManager.default.createDirectory(at: finalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporaryURL = finalURL.appendingPathExtension("\(UUID().uuidString).partial"); FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL); defer { try? handle.close() }
        try handle.write(contentsOf: header)
        var recordBuffer = Data(); recordBuffer.reserveCapacity(1024 * 1024)
        var stringOffset: UInt64 = 0
        for i in nodes.indices {
            let node = nodes[i]; let name = Data(node.name.utf8); let issue = node.issue.map { Data($0.utf8) }
            let f = node.fingerprint; var flags: UInt64 = node.isDirectory ? 1 : 0
            if node.modified != nil { flags |= 2 }
            if f != nil { flags |= 4 }; if f?.onlineOnly == true { flags |= 8 }
            let issueOffset = issue == nil ? UInt64.max : stringOffset + UInt64(name.count)
            for word in [ranges[i].0, ranges[i].1, stringOffset, UInt64(name.count), issueOffset, UInt64(issue?.count ?? 0), flags,
                         UInt64(bitPattern: node.bytes), UInt64(bitPattern: node.logical), UInt64(node.count), node.modified?.timeIntervalSince1970.bitPattern ?? 0,
                         f?.device ?? 0, f?.inode ?? 0, UInt64(bitPattern: f?.size ?? 0), UInt64(bitPattern: f?.blocks ?? 0), UInt64(bitPattern: f?.modifiedSeconds ?? 0), UInt64(bitPattern: f?.modifiedNanoseconds ?? 0)] { append(word, to: &recordBuffer) }
            stringOffset += UInt64(name.count + (issue?.count ?? 0))
            if recordBuffer.count >= 1024 * 1024 { try handle.write(contentsOf: recordBuffer); recordBuffer.removeAll(keepingCapacity: true) }
        }
        if !recordBuffer.isEmpty { try handle.write(contentsOf: recordBuffer) }
        var textBuffer = Data(); textBuffer.reserveCapacity(1024 * 1024)
        for node in nodes {
            textBuffer.append(contentsOf: node.name.utf8); if let issue = node.issue { textBuffer.append(contentsOf: issue.utf8) }
            if textBuffer.count >= 1024 * 1024 { try handle.write(contentsOf: textBuffer); textBuffer.removeAll(keepingCapacity: true) }
        }
        if !textBuffer.isEmpty { try handle.write(contentsOf: textBuffer) }
        try handle.synchronize(); try handle.close()
        if rename(temporaryURL.path, finalURL.path) != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    static func load(path: String, cacheURL: URL? = nil) -> (DiskNode, UInt64, [String], Int, Bool)? {
        let target = cacheURL ?? url(for: path)
        if let data = try? Data(contentsOf: target, options: .mappedIfSafe), let cache = BinaryTreeCache(data: data), cache.rootPath == path { return (cache.root, cache.eventID, cache.errors, cache.skipped, false) }
        let legacyURL = target.deletingPathExtension().appendingPathExtension("plist")
        guard let data = try? Data(contentsOf: legacyURL, options: .mappedIfSafe), let cache = try? PropertyListDecoder().decode(LegacyScanCache.self, from: data), cache.rootPath == path, !cache.entries.isEmpty else { return nil }
        var nodes: [DiskNode] = []; nodes.reserveCapacity(cache.entries.count)
        for (index, entry) in cache.entries.enumerated() {
            let node = index == 0 ? DiskNode(path: cache.rootPath, directory: entry.directory, bytes: entry.bytes, logical: entry.logical, fingerprint: entry.fingerprint) : DiskNode(name: entry.name, directory: entry.directory, bytes: entry.bytes, logical: entry.logical, fingerprint: entry.fingerprint)
            node.count = entry.count; node.modified = entry.modified; node.issue = entry.issue
            if index > 0, entry.parent >= 0, entry.parent < nodes.count { nodes[entry.parent].attach(node) }
            nodes.append(node)
        }
        return (nodes[0], cache.eventID, cache.errors, cache.skipped, true)
    }
    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
}
struct FileFingerprint: Hashable, Sendable {
    let device: UInt64; let inode: UInt64; let size: Int64; let blocks: Int64
    let modifiedSeconds: Int64; let modifiedNanoseconds: Int64; let directory: Bool; let onlineOnly: Bool
    init(_ info: stat, directory: Bool) {
        device = UInt64(info.st_dev); inode = UInt64(info.st_ino); size = Int64(info.st_size); blocks = Int64(info.st_blocks)
        modifiedSeconds = Int64(info.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(info.st_mtimespec.tv_nsec)
        self.directory = directory; onlineOnly = info.st_flags & UInt32(SF_DATALESS) != 0
    }
    init(device: dev_t, inode: UInt64, size: Int64, blocks: Int64, modified: timespec, directory: Bool, flags: UInt32) {
        self.device = UInt64(device); self.inode = inode; self.size = size; self.blocks = blocks
        modifiedSeconds = Int64(modified.tv_sec); modifiedNanoseconds = Int64(modified.tv_nsec)
        self.directory = directory; onlineOnly = flags & UInt32(SF_DATALESS) != 0
    }
}
private struct DirectoryItem {
    let name: String; let kind: fsobj_type_t; let device: dev_t; let inode: UInt64
    let size: Int64; let allocated: Int64; let modified: timespec; let flags: UInt32; let error: Int32
}
private enum DirectoryReader {
    private static let commonMask: UInt32 = UInt32(truncatingIfNeeded: ATTR_CMN_RETURNED_ATTRS) | UInt32(truncatingIfNeeded: ATTR_CMN_ERROR) | UInt32(truncatingIfNeeded: ATTR_CMN_NAME) | UInt32(truncatingIfNeeded: ATTR_CMN_DEVID) | UInt32(truncatingIfNeeded: ATTR_CMN_OBJTYPE) | UInt32(truncatingIfNeeded: ATTR_CMN_MODTIME) | UInt32(truncatingIfNeeded: ATTR_CMN_FLAGS) | UInt32(truncatingIfNeeded: ATTR_CMN_FILEID)
    static func forEach(_ url: URL, _ body: (DirectoryItem) -> Void) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(fd) }
        var attributes = attrlist(); attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT); attributes.commonattr = commonMask
        attributes.fileattr = UInt32(ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH)
        let capacity = 256 * 1024
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: 8); defer { buffer.deallocate() }
        while true {
            let count = getattrlistbulk(fd, &attributes, buffer, capacity, 0)
            if count == 0 { return }
            if count < 0 {
                let code = errno
                if code == ENOTSUP || code == EINVAL { try fallback(url, body); return }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
            var offset = 0
            for _ in 0..<count {
                let start = offset
                guard capacity - offset >= MemoryLayout<UInt32>.size else { throw CommandFailure(message: "Повреждён ответ getattrlistbulk") }
                let recordLength = buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian
                guard recordLength >= 24 && Int(recordLength) <= capacity - start else { throw CommandFailure(message: "Некорректная длина элемента getattrlistbulk") }
                offset += MemoryLayout<UInt32>.size
                let returned = buffer.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self); offset += MemoryLayout<attribute_set_t>.size
                var itemError: UInt32 = 0
                if returned.commonattr & UInt32(ATTR_CMN_ERROR) != 0 { itemError = read(UInt32.self, buffer, &offset) }
                var name = ""; var device: dev_t = 0; var kind: fsobj_type_t = UInt32(VNON.rawValue); var modified = timespec(); var flags: UInt32 = 0; var inode: UInt64 = 0
                if returned.commonattr & UInt32(ATTR_CMN_NAME) != 0 {
                    let refOffset = offset; let reference = read(attrreference_t.self, buffer, &offset)
                    let address = buffer.advanced(by: refOffset + Int(reference.attr_dataoffset)).assumingMemoryBound(to: CChar.self)
                    name = String(cString: address)
                }
                if returned.commonattr & UInt32(ATTR_CMN_DEVID) != 0 { device = read(dev_t.self, buffer, &offset) }
                if returned.commonattr & UInt32(ATTR_CMN_OBJTYPE) != 0 { kind = read(fsobj_type_t.self, buffer, &offset) }
                if returned.commonattr & UInt32(ATTR_CMN_MODTIME) != 0 { modified = read(timespec.self, buffer, &offset) }
                if returned.commonattr & UInt32(ATTR_CMN_FLAGS) != 0 { flags = read(UInt32.self, buffer, &offset) }
                if returned.commonattr & UInt32(ATTR_CMN_FILEID) != 0 { inode = read(UInt64.self, buffer, &offset) }
                var allocated: Int64 = 0; var size: Int64 = 0
                if returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE) != 0 { allocated = read(off_t.self, buffer, &offset) }
                if returned.fileattr & UInt32(ATTR_FILE_DATALENGTH) != 0 { size = read(off_t.self, buffer, &offset) }
                body(DirectoryItem(name: name, kind: kind, device: device, inode: inode, size: size, allocated: allocated, modified: modified, flags: flags, error: Int32(itemError)))
                offset = start + Int(recordLength)
            }
        }
    }
    private static func read<T>(_ type: T.Type, _ buffer: UnsafeRawPointer, _ offset: inout Int) -> T {
        let value = buffer.loadUnaligned(fromByteOffset: offset, as: T.self); offset += MemoryLayout<T>.size; return value
    }
    private static func fallback(_ url: URL, _ body: (DirectoryItem) -> Void) throws {
        for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: []) {
            var info = stat()
            guard lstat(child.path, &info) == 0 else { body(DirectoryItem(name: child.lastPathComponent, kind: UInt32(VNON.rawValue), device: 0, inode: 0, size: 0, allocated: 0, modified: timespec(), flags: 0, error: errno)); continue }
            let type = info.st_mode & S_IFMT
            let kind: fsobj_type_t
            if type == S_IFDIR { kind = UInt32(VDIR.rawValue) }
            else if type == S_IFREG { kind = UInt32(VREG.rawValue) }
            else if type == S_IFLNK { kind = UInt32(VLNK.rawValue) }
            else { kind = UInt32(VNON.rawValue) }
            body(DirectoryItem(name: child.lastPathComponent, kind: kind, device: info.st_dev, inode: UInt64(info.st_ino), size: Int64(info.st_size), allocated: Int64(info.st_blocks) * 512, modified: info.st_mtimespec, flags: info.st_flags, error: 0))
        }
    }
}
struct ChangedPath: Sendable { let path: String; let removed: Bool }
struct PathSnapshot: @unchecked Sendable { let path: String; let node: DiskNode? }
struct ScanProgress: Sendable {
    let files: Int
    let bytes: Int64
    let path: String
    let errors: Int
    let preview: DiskNode?
    let expectedFiles: Int?
    let completed: Bool

    var percent: Int? {
        if completed { return 100 }
        guard let expectedFiles, expectedFiles > 0 else { return nil }
        return min(99, max(0, Int(Double(files) / Double(expectedFiles) * 100)))
    }
}
struct ScanResult: @unchecked Sendable {
    let root: DiskNode; let errors: [String]; let skipped: Int; let seconds: Double; let cancelled: Bool
    let fileIdentities: Set<FileIdentity>
    init(root: DiskNode, errors: [String], skipped: Int, seconds: Double, cancelled: Bool, fileIdentities: Set<FileIdentity> = []) {
        self.root = root; self.errors = errors; self.skipped = skipped; self.seconds = seconds; self.cancelled = cancelled; self.fileIdentities = fileIdentities
    }
}
enum Scanner {
    static func scan(_ url: URL, expectedFiles: Int? = nil, stop: StopToken, progress: @escaping (ScanProgress) -> Void = { _ in }) -> ScanResult {
        let start = Date()
        let rootURL = url.standardizedFileURL
        let root = DiskNode(path: rootURL.path, directory: true)
        var rootStat = stat(); _ = lstat(root.id, &rootStat)
        var allowedDevices = Set([rootStat.st_dev])
        var errors: [String] = []; var errorCount = 0; var skipped = 0; var files = 0; var total: Int64 = 0
        let seen = ConcurrentIdentitySet(); _ = seen.insert(FileIdentity(device: rootStat.st_dev, inode: rootStat.st_ino), file: false)
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
                    try DirectoryReader.forEach(directory.url) { item in
                        if stop.cancelled { return }
                        if item.error != 0 { localErrorCount += 1; if localErrors.count < 200 { localErrors.append("\(directory.id)/\(item.name): \(String(cString: strerror(item.error)))") }; return }
                        if item.kind == UInt32(VLNK.rawValue) { localSkipped += 1; return }
                        let isDir = item.kind == UInt32(VDIR.rawValue)
                        guard isDir || item.kind == UInt32(VREG.rawValue) else { localSkipped += 1; return }
                        let isDataVolume = root.id == "/" && directory.id == "/System/Volumes" && item.name == "Data"
                        if isDir && (!allowedDevices.contains(item.device) || isDataVolume) { localSkipped += 1; return }
                        let inode = FileIdentity(device: item.device, inode: ino_t(item.inode))
                        let fresh = seen.insert(inode, file: !isDir)
                        if !fresh { localSkipped += 1; return }
                        let onlineOnly = item.flags & UInt32(SF_DATALESS) != 0
                        let allocated = isDir || onlineOnly ? 0 : item.allocated
                        let fingerprint = FileFingerprint(device: item.device, inode: item.inode, size: item.size, blocks: item.allocated / 512, modified: item.modified, directory: isDir, flags: item.flags)
                        let child = DiskNode(name: item.name, directory: isDir, bytes: allocated, logical: isDir ? 0 : item.size, fingerprint: fingerprint)
                        child.modified = Date(timeIntervalSince1970: Double(item.modified.tv_sec))
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
                if Date().timeIntervalSince(last) > 1.2 {
                    var previewBudget = 480
                    func preview(_ n: DiskNode, _ level: Int) -> DiskNode {
                        previewBudget -= 1
                        let copy = DiskNode(path: n.id, directory: n.isDirectory, bytes: n.bytes, logical: n.logical); copy.count = n.count
                        if level > 0 {
                            for c in TopItems.largest(n.children, limit: 40) { guard previewBudget > 0 else { break }; copy.attach(preview(c, level - 1)) }
                            let remaining = n.bytes - copy.children.reduce(0) { $0 + $1.bytes }
                            if remaining > 0 { let rest = DiskNode(path: n.id + "/… остальные элементы", directory: false, bytes: remaining); rest.remote = true; copy.attach(rest) }
                        }
                        return copy
                    }
                    progress(ScanProgress(files: files, bytes: total, path: directory.id, errors: errorCount,
                                          preview: preview(root, 3), expectedFiles: expectedFiles, completed: false))
                    last = Date()
                }
                condition.broadcast(); condition.unlock()
            }
        }
        for n in root.flatten().reversed() where n.isDirectory { n.bytes = n.children.reduce(0) { $0 + $1.bytes }; n.logical = n.children.reduce(0) { $0 + $1.logical }; n.count = n.children.reduce(0) { $0 + $1.count } }
        if !stop.cancelled {
            progress(ScanProgress(files: root.count, bytes: root.bytes, path: root.id, errors: errorCount,
                                  preview: nil, expectedFiles: expectedFiles, completed: true))
        }
        return ScanResult(root: root, errors: errors, skipped: skipped, seconds: Date().timeIntervalSince(start), cancelled: stop.cancelled, fileIdentities: seen.files)
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

enum TreeUpdater {
    static func node(at path: String, in root: DiskNode) -> DiskNode? {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        guard target == root.id || target.hasPrefix(root.id.hasSuffix("/") ? root.id : root.id + "/") else { return nil }
        if target == root.id { return root }
        let relative = String(target.dropFirst(root.id.count)).split(separator: "/").map(String.init)
        var cursor = root; var currentPath = root.id
        for component in relative {
            currentPath = URL(fileURLWithPath: currentPath).appendingPathComponent(component).standardizedFileURL.path
            guard let child = cursor.children.first(where: { $0.id == currentPath }) else { return nil }
            cursor = child
        }
        return cursor
    }

    @discardableResult static func apply(_ changes: [PathSnapshot], to root: DiskNode, fileIdentities: inout Set<FileIdentity>) -> Int {
        let ordered = changes.sorted { ($0.node == nil ? 0 : 1) < ($1.node == nil ? 0 : 1) }
        var count = 0
        for change in ordered where apply(change, to: root, fileIdentities: &fileIdentities) { count += 1 }
        return count
    }

    @discardableResult private static func apply(_ change: PathSnapshot, to root: DiskNode, fileIdentities: inout Set<FileIdentity>) -> Bool {
        if change.path == root.id {
            guard let snapshot = change.node, root.isDirectory, snapshot.issue == nil else { return false }
            reconcile(root, with: snapshot, fileIdentities: &fileIdentities); recomputeAncestors(root); return true
        }
        let parentPath = URL(fileURLWithPath: change.path).deletingLastPathComponent().standardizedFileURL.path
        guard let parent = node(at: parentPath, in: root), parent.isDirectory else { return false }
        if let index = parent.children.firstIndex(where: { $0.id == change.path }) {
            guard let snapshot = change.node else {
                removeIdentities(in: parent.children[index], from: &fileIdentities); parent.children.remove(at: index); recomputeAncestors(parent); return true
            }
            guard snapshot.issue == nil else { return false }
            let existing = parent.children[index]
            if let replacement = merged(existing, snapshot, parent: parent, fileIdentities: &fileIdentities) { parent.children[index] = replacement }
            else { parent.children.remove(at: index) }
        } else {
            guard let snapshot = change.node, snapshot.issue == nil else { return false }
            if let inserted = merged(nil, snapshot, parent: parent, fileIdentities: &fileIdentities) { parent.children.append(inserted) }
        }
        recomputeAncestors(parent); return true
    }

    private static func merged(_ existing: DiskNode?, _ snapshot: DiskNode, parent: DiskNode, fileIdentities: inout Set<FileIdentity>) -> DiskNode? {
        guard let existing else { return register(snapshot, parent: parent, fileIdentities: &fileIdentities) }
        let sameIdentity = existing.isDirectory == snapshot.isDirectory && existing.fingerprint?.device == snapshot.fingerprint?.device && existing.fingerprint?.inode == snapshot.fingerprint?.inode
        guard sameIdentity else {
            removeIdentities(in: existing, from: &fileIdentities)
            return register(snapshot, parent: parent, fileIdentities: &fileIdentities)
        }
        existing.fingerprint = snapshot.fingerprint; existing.modified = snapshot.modified; existing.issue = snapshot.issue
        if existing.isDirectory { reconcile(existing, with: snapshot, fileIdentities: &fileIdentities); recomputeOne(existing) }
        else {
            existing.bytes = snapshot.bytes; existing.logical = snapshot.logical; existing.count = snapshot.count
        }
        existing.setParent(parent); return existing
    }

    private static func register(_ snapshot: DiskNode, parent: DiskNode, fileIdentities: inout Set<FileIdentity>) -> DiskNode? {
        snapshot.setParent(parent)
        if snapshot.isDirectory {
            let candidates = snapshot.children; snapshot.children = []
            for candidate in candidates {
                if let child = merged(nil, candidate, parent: snapshot, fileIdentities: &fileIdentities) { snapshot.attach(child) }
            }
            recomputeOne(snapshot)
        } else if let identity = identity(of: snapshot) {
            guard fileIdentities.insert(identity).inserted else { return nil }
        }
        return snapshot
    }

    private static func reconcile(_ directory: DiskNode, with snapshot: DiskNode, fileIdentities: inout Set<FileIdentity>) {
        let nextIDs = Set(snapshot.children.map(\.id))
        for previous in directory.children where !nextIDs.contains(previous.id) { removeIdentities(in: previous, from: &fileIdentities) }
        let previous = Dictionary(uniqueKeysWithValues: directory.children.map { ($0.id, $0) })
        var children: [DiskNode] = []; children.reserveCapacity(snapshot.children.count)
        for candidate in snapshot.children {
            if let child = merged(previous[candidate.id], candidate, parent: directory, fileIdentities: &fileIdentities) { children.append(child) }
        }
        directory.children = children
        directory.fingerprint = snapshot.fingerprint; directory.modified = snapshot.modified; directory.issue = snapshot.issue
        recomputeOne(directory)
    }

    private static func identity(of node: DiskNode) -> FileIdentity? {
        guard !node.isDirectory, let fingerprint = node.fingerprint else { return nil }
        return FileIdentity(device: dev_t(fingerprint.device), inode: ino_t(fingerprint.inode))
    }

    private static func removeIdentities(in node: DiskNode, from identities: inout Set<FileIdentity>) {
        for item in node.flatten() { if let identity = identity(of: item) { identities.remove(identity) } }
    }

    private static func recomputeOne(_ directory: DiskNode) {
        guard directory.isDirectory else { return }
        directory.bytes = directory.children.reduce(0) { $0 + $1.bytes }
        directory.logical = directory.children.reduce(0) { $0 + $1.logical }
        directory.count = directory.children.reduce(0) { $0 + $1.count }
    }

    private static func recomputeAncestors(_ directory: DiskNode) {
        var node: DiskNode? = directory
        while let current = node { recomputeOne(current); node = current.parent }
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
