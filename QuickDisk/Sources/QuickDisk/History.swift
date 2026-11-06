import Foundation

struct SnapshotChange: Codable, Identifiable, Sendable {
    let path: String
    let isDirectory: Bool
    let beforeBytes: Int64
    let afterBytes: Int64
    let beforeLogical: Int64
    let afterLogical: Int64

    var id: String { (isDirectory ? "d:" : "f:") + path }
    var bytesDelta: Int64 { afterBytes - beforeBytes }
    var logicalDelta: Int64 { afterLogical - beforeLogical }
}

struct DiskSnapshot: Codable, Identifiable, Sendable {
    let id: UUID
    let date: Date
    let rootPath: String
    let capacity: Int64?
    let free: Int64?
    let scannedBytes: Int64
    let logicalBytes: Int64
    let fileCount: Int
    let errorCount: Int
    let skippedCount: Int
    let changes: [SnapshotChange]
    let changedFolderCount: Int
    let changedFileCount: Int
    let folderChangesTruncated: Bool
    let fileChangesTruncated: Bool
    let gapBefore: Bool?
    let isManual: Bool?
}

enum SnapshotHistoryStore {
    static let retentionCount = 365
    private static let detailLimit = 500

    static func url(for cacheURL: URL) -> URL {
        cacheURL.deletingPathExtension().appendingPathExtension("qdHistory.json")
    }

    static func load(from url: URL) -> [DiskSnapshot] {
        let decoder = JSONDecoder()
        // Older builds wrote dates in several Foundation-compatible numeric scales.
        // Normalize seconds, milliseconds, microseconds, and nanoseconds since epoch,
        // plus Date's legacy seconds-since-2001 representation.
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(Double.self)
            let seconds: Double
            if abs(value) >= 1e17 { seconds = value / 1e9 }
            else if abs(value) >= 1e14 { seconds = value / 1e6 }
            else if abs(value) >= 1e11 { seconds = value / 1e3 }
            else if value < 1e9 { seconds = value + 978_307_200 }
            else { seconds = value }
            return Date(timeIntervalSince1970: seconds)
        }
        guard let data = try? Data(contentsOf: url),
              let snapshots = try? decoder.decode([DiskSnapshot].self, from: data) else { return [] }
        return snapshots.sorted { $0.date < $1.date }
    }

    static func delete(id: UUID, from url: URL) throws {
        let remaining = load(from: url).filter { $0.id != id }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(remaining).write(to: url, options: .atomic)
    }

    @discardableResult
    static func append(root: DiskNode, previousRoot: DiskNode?, capacity: Int64?, free: Int64?,
                       errors: Int, skipped: Int, gapBefore: Bool = false, isManual: Bool = false,
                       to url: URL, date: Date = Date()) throws -> DiskSnapshot {
        var folderCollector = BoundedChanges(limit: detailLimit)
        var fileCollector = BoundedChanges(limit: detailLimit)
        if let previousRoot, previousRoot.id == root.id {
            collectChanges(previous: previousRoot, current: root, folders: &folderCollector, files: &fileCollector)
        }
        let snapshot = DiskSnapshot(
            id: UUID(), date: date, rootPath: root.id, capacity: capacity, free: free,
            scannedBytes: root.bytes, logicalBytes: root.logical, fileCount: root.count,
            errorCount: errors, skippedCount: skipped,
            changes: folderCollector.sortedItems + fileCollector.sortedItems,
            changedFolderCount: folderCollector.totalCount, changedFileCount: fileCollector.totalCount,
            folderChangesTruncated: folderCollector.totalCount > detailLimit,
            fileChangesTruncated: fileCollector.totalCount > detailLimit, gapBefore: gapBefore, isManual: isManual
        )
        var history = load(from: url)
        history.append(snapshot)
        if history.count > retentionCount { history.removeFirst(history.count - retentionCount) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        try encoder.encode(history).write(to: url, options: .atomic)
        return snapshot
    }

    private static func collectChanges(previous: DiskNode, current: DiskNode,
                                       folders: inout BoundedChanges, files: inout BoundedChanges) {
        var pending: [(DiskNode, DiskNode, Int)] = [(previous, current, 0)]
        while let (old, new, depth) = pending.popLast() {
            old.loadAllChildren(); new.loadAllChildren()
            var oldByName = Dictionary(old.children.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let newChildren = new.children
            let newNames = Set(newChildren.map(\.name))

            for child in old.children where !newNames.contains(child.name) {
                recordSingle(child, before: child.bytes, after: 0, beforeLogical: child.logical, afterLogical: 0,
                             depth: depth + 1, folders: &folders, files: &files)
            }
            for child in newChildren {
                guard let oldChild = oldByName.removeValue(forKey: child.name) else {
                    recordSingle(child, before: 0, after: child.bytes, beforeLogical: 0, afterLogical: child.logical,
                                 depth: depth + 1, folders: &folders, files: &files)
                    continue
                }
                if child.isDirectory && oldChild.isDirectory {
                    if oldChild.bytes != child.bytes || oldChild.logical != child.logical {
                        folders.insert(SnapshotChange(path: child.id, isDirectory: true,
                                                      beforeBytes: oldChild.bytes, afterBytes: child.bytes,
                                                      beforeLogical: oldChild.logical, afterLogical: child.logical))
                    }
                    pending.append((oldChild, child, depth + 1))
                } else if oldChild.bytes != child.bytes || oldChild.logical != child.logical {
                    files.insert(SnapshotChange(path: child.id, isDirectory: false,
                                                beforeBytes: oldChild.bytes, afterBytes: child.bytes,
                                                beforeLogical: oldChild.logical, afterLogical: child.logical))
                }
            }
        }
    }

    private static func recordSingle(_ node: DiskNode, before: Int64, after: Int64,
                                     beforeLogical: Int64, afterLogical: Int64, depth: Int,
                                     folders: inout BoundedChanges, files: inout BoundedChanges) {
        if node.isDirectory {
            folders.insert(SnapshotChange(path: node.id, isDirectory: true,
                                          beforeBytes: before, afterBytes: after,
                                          beforeLogical: beforeLogical, afterLogical: afterLogical))
        } else {
            files.insert(SnapshotChange(path: node.id, isDirectory: false,
                                        beforeBytes: before, afterBytes: after,
                                        beforeLogical: beforeLogical, afterLogical: afterLogical))
        }
    }

    private struct BoundedChanges {
        let limit: Int
        private(set) var totalCount = 0
        private var heap: [SnapshotChange] = []
        var sortedItems: [SnapshotChange] { heap.sorted { score($0) > score($1) } }

        mutating func insert(_ change: SnapshotChange) {
            totalCount += 1
            if heap.count < limit {
                heap.append(change)
                siftUp(heap.count - 1)
            } else if !heap.isEmpty, score(change) > score(heap[0]) {
                heap[0] = change
                siftDown(0)
            }
        }

        private func score(_ change: SnapshotChange) -> UInt64 { change.bytesDelta.magnitude }
        private mutating func siftUp(_ start: Int) {
            var index = start
            while index > 0 {
                let parent = (index - 1) / 2
                if score(heap[parent]) <= score(heap[index]) { break }
                heap.swapAt(parent, index); index = parent
            }
        }
        private mutating func siftDown(_ start: Int) {
            var index = start
            while true {
                let left = index * 2 + 1, right = left + 1
                var smallest = index
                if left < heap.count && score(heap[left]) < score(heap[smallest]) { smallest = left }
                if right < heap.count && score(heap[right]) < score(heap[smallest]) { smallest = right }
                if smallest == index { return }
                heap.swapAt(index, smallest); index = smallest
            }
        }
    }
}
