import Foundation

struct CommandFailure: LocalizedError { let message: String; var errorDescription: String? { message } }
enum Commands {
    static func executable(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/", "/usr/bin/", "/bin/"].map { $0 + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static func run(_ executable: String, _ arguments: [String], stop: StopToken) throws -> Data {
        let fm = FileManager.default; let folder = fm.temporaryDirectory.appendingPathComponent("quickdisk-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true); defer { try? fm.removeItem(at: folder) }
        let out = folder.appendingPathComponent("out"); let err = folder.appendingPathComponent("err")
        fm.createFile(atPath: out.path, contents: nil); fm.createFile(atPath: err.path, contents: nil)
        let oh = try FileHandle(forWritingTo: out); let eh = try FileHandle(forWritingTo: err); defer { try? oh.close(); try? eh.close() }
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.standardOutput = oh; process.standardError = eh; process.standardInput = FileHandle.nullDevice
        try process.run()
        while process.isRunning {
            if stop.cancelled { process.terminate(); process.waitUntilExit(); throw CancellationError() }
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard process.terminationStatus == 0 else { let message = String(data: (try? Data(contentsOf: err)) ?? Data(), encoding: .utf8) ?? "Ошибка команды"; throw CommandFailure(message: String(message.prefix(5000))) }
        return try Data(contentsOf: out)
    }
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
struct RemoteEntry: Decodable { let path: String; let directory: Bool; let size: Int64 }
enum RemoteScan {
    static func scan(kind: String, host: String, path: String, stop: StopToken) throws -> ScanResult {
        let start = Date(); let entries: [RemoteEntry]; let label: String
        if kind == "SSH" {
            guard !host.isEmpty, !host.hasPrefix("-"), host.range(of: "^[a-zA-Z0-9_.@:-]+$", options: .regularExpression) != nil else { throw CommandFailure(message: "Укажите SSH-алиас или user@host") }
            let script = """
import os,sys,json,stat
root=sys.argv[1]; rows=[]; errors=[]
if not os.path.isdir(root): raise RuntimeError('Folder not found')
def failed(e): errors.append(str(e))
for parent,dirs,files in os.walk(root,followlinks=False,onerror=failed):
 dirs[:]=[d for d in dirs if not os.path.islink(os.path.join(parent,d))]
 for name in dirs+files:
  p=os.path.join(parent,name)
  try:
   s=os.lstat(p)
   if not (stat.S_ISDIR(s.st_mode) or stat.S_ISREG(s.st_mode)): continue
   rows.append({'path':os.path.relpath(p,root),'directory':stat.S_ISDIR(s.st_mode),'size':0 if stat.S_ISDIR(s.st_mode) else getattr(s,'st_blocks',0)*512})
  except OSError as e: errors.append(str(e))
json.dump({'entries':rows,'errors':errors[:200]},sys.stdout)
"""
            let command = "python3 -c " + Commands.quote(script) + " " + Commands.quote(path)
            let data = try Commands.run("/usr/bin/ssh", ["-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=15", host, command], stop: stop)
            struct Output: Decodable { let entries: [RemoteEntry]; let errors: [String] }
            let output = try JSONDecoder().decode(Output.self, from: data)
            let root = tree(label: "ssh://" + host + path, entries: output.entries)
            return ScanResult(root: root, errors: output.errors, skipped: 0, seconds: Date().timeIntervalSince(start), cancelled: false)
        } else {
            guard let rclone = Commands.executable("rclone") else { throw CommandFailure(message: "rclone не установлен. Установите его с rclone.org и добавьте аккаунт командой rclone config.") }
            guard path.contains(":"), !path.hasPrefix("-"), !path.hasPrefix(":") else { throw CommandFailure(message: "Укажите настроенный remote:path, например drive:Projects") }
            let data = try Commands.run(rclone, ["lsjson", path, "--recursive", "--no-mimetype", "--no-modtime"], stop: stop)
            struct Item: Decodable { let Path: String; let Size: Int64; let IsDir: Bool }
            entries = try JSONDecoder().decode([Item].self, from: data).map { RemoteEntry(path: $0.Path, directory: $0.IsDir, size: max(0, $0.Size)) }
            label = "cloud://" + path
        }
        return ScanResult(root: tree(label: label, entries: entries), errors: [], skipped: 0, seconds: Date().timeIntervalSince(start), cancelled: false)
    }
    static func tree(label: String, entries: [RemoteEntry]) -> DiskNode {
        let root = DiskNode(path: label, directory: true); root.remote = true
        var dirs: [String: DiskNode] = ["": root]
        func folder(_ path: String) -> DiskNode {
            if let n = dirs[path] { return n }
            let parentPath = (path as NSString).deletingLastPathComponent
            let parent = folder(parentPath == "." ? "" : parentPath)
            let n = DiskNode(path: label + "/" + path, directory: true); n.remote = true; parent.attach(n); dirs[path] = n; return n
        }
        for e in entries where !e.path.hasPrefix("/") && !e.path.split(separator: "/").contains("..") {
            if e.directory { _ = folder(e.path) } else {
                let p = (e.path as NSString).deletingLastPathComponent
                let n = DiskNode(path: label + "/" + e.path, directory: false, bytes: e.size, logical: e.size); n.remote = true; n.count = 1
                folder(p == "." ? "" : p).attach(n)
            }
        }
        func sum(_ n: DiskNode) { for c in n.children { sum(c) }; if n.isDirectory { n.bytes = n.children.reduce(0) { $0 + $1.bytes }; n.logical = n.bytes; n.count = n.children.reduce(0) { $0 + $1.count } } }; sum(root); return root
    }
}
