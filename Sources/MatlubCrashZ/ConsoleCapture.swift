import Foundation
import Darwin

/// Tees stdout/stderr (`print`, `NSLog`, C `printf`) into a per-launch file so the last lines before a crash can be
/// attached to the report on the next launch. Output still reaches the original descriptors (Xcode console).
/// `os.Logger` / `os_log` output does not go through stdout and is not captured — use `MatlubCrashZ.log` for those.
final class ConsoleCapture {
    private let directory: URL
    private let maxBytes: Int
    private let queue = DispatchQueue(label: "com.matlub.crash.console", qos: .utility)
    private var file: FileHandle?
    private var written = 0
    private var sources: [DispatchSourceRead] = []
    private var originals: [Int32: Int32] = [:]

    init(directory: URL, maxBytes: Int = 128 * 1024) {
        self.directory = directory.appendingPathComponent("console", isDirectory: true)
        self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    static func fileName(for launchId: String) -> String { "console-\(launchId).log" }

    func start(launchId: String) {
        let url = directory.appendingPathComponent(Self.fileName(for: launchId))
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try? FileHandle(forWritingTo: url)
        guard file != nil else { return }
        // Line-buffer stdout so `print` reaches us immediately instead of sitting in a 4 KB buffer when the crash hits.
        setvbuf(stdout, nil, _IOLBF, 0)
        setvbuf(stderr, nil, _IONBF, 0)
        for fd in [STDOUT_FILENO, STDERR_FILENO] { redirect(fd: fd) }
    }

    private func redirect(fd: Int32) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return }
        let readEnd = fds[0], writeEnd = fds[1]
        let original = dup(fd)
        originals[fd] = original
        guard dup2(writeEnd, fd) >= 0 else { close(readEnd); close(writeEnd); return }
        close(writeEnd)

        let source = DispatchSource.makeReadSource(fileDescriptor: readEnd, queue: queue)
        source.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 8192)
            let n = read(readEnd, &buffer, buffer.count)
            guard n > 0 else { return }
            if original >= 0 { _ = buffer.withUnsafeBufferPointer { write(original, $0.baseAddress, n) } }
            self?.append(Data(buffer[0..<n]))
        }
        source.setCancelHandler { close(readEnd) }
        source.resume()
        sources.append(source)
    }

    private func append(_ data: Data) {
        guard let file else { return }
        file.write(data)
        written += data.count
        // Keep only the tail once the file grows past the cap.
        if written > maxBytes * 2 {
            if let all = try? Data(contentsOf: file.currentURL(directory: directory)) {
                let tail = all.suffix(maxBytes)
                try? file.truncate(atOffset: 0)
                file.write(tail)
                written = tail.count
            }
        }
    }

    /// Last `maxBytes` of the console log written by the launch with this id, if still on disk.
    func log(forLaunchId launchId: String) -> String? {
        let url = directory.appendingPathComponent(Self.fileName(for: launchId))
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return String(decoding: data.suffix(maxBytes), as: UTF8.self)
    }

    /// Deletes logs of launches other than the given ids.
    func prune(keeping launchIds: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let keep = Set(launchIds.map(Self.fileName(for:)))
        // Also keep the 3 most recent files regardless, so a crash whose report is delivered late still finds its log.
        let recent = files.sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }.prefix(3).map { $0.lastPathComponent }
        for f in files where !keep.contains(f.lastPathComponent) && !recent.contains(f.lastPathComponent) {
            try? FileManager.default.removeItem(at: f)
        }
    }
}

private extension FileHandle {
    func currentURL(directory: URL) -> URL {
        // FileHandle has no URL accessor; resolve it through the descriptor.
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if fcntl(fileDescriptor, F_GETPATH, &buf) == 0 { return URL(fileURLWithPath: String(cString: buf)) }
        return directory
    }
}
