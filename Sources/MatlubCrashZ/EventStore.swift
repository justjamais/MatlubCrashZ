import Foundation

/// Disk-backed queue of events waiting to be uploaded.
/// Each event is one JSON file under Application Support/MatlubCrashZ/pending.
final class EventStore {
    let directory: URL
    private let maxEvents: Int
    private let lock = NSLock()

    init(maxEvents: Int) {
        self.maxEvents = maxEvents
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        directory = base.appendingPathComponent("MatlubCrashZ/pending", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Never let crash data go to iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dir = directory
        try? dir.setResourceValues(values)
    }

    /// Persists an event and returns its file URL.
    @discardableResult
    func save(_ event: [String: Any]) -> URL? {
        lock.lock(); defer { lock.unlock() }
        guard JSONSerialization.isValidJSONObject(event),
              let data = try? JSONSerialization.data(withJSONObject: event) else {
            SDKLog.error("event is not valid JSON, dropping")
            return nil
        }
        let id = (event["id"] as? String) ?? UUID().uuidString
        let url = directory.appendingPathComponent("\(id).json")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            SDKLog.error("cannot write event: \(error)")
            return nil
        }
        trimIfNeeded()
        return url
    }

    /// Pending event files, oldest first.
    func pendingFiles() -> [URL] {
        let keys: [URLResourceKey] = [.creationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
                return da < db
            }
    }

    func delete(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    private func trimIfNeeded() {
        let files = pendingFiles()
        guard files.count > maxEvents else { return }
        for url in files.prefix(files.count - maxEvents) {
            SDKLog.info("dropping old pending event \(url.lastPathComponent)")
            delete(url)
        }
    }
}
