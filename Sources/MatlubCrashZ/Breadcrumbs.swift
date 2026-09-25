import Foundation

/// A single breadcrumb: something that happened before a crash.
public struct Breadcrumb: Codable, Sendable {
    public var timestamp: Date
    public var category: String
    public var message: String
    public var level: String
    public var data: [String: String]?

    public init(timestamp: Date = Date(), category: String = "default", message: String, level: String = "info", data: [String: String]? = nil) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
        self.level = level
        self.data = data
    }
}

/// Thread-safe ring buffer of breadcrumbs. A JSON snapshot is written to a per-launch file on every
/// (coalesced) change so it survives a hard crash and can be matched to the report through its launch id.
///
/// The snapshot used to go into KSCrash's user info, but that store caps string values at 1024 bytes:
/// 100 breadcrumbs (~15 KB) were truncated into invalid JSON, so reports arrived with no breadcrumbs at all.
final class BreadcrumbBuffer {
    private let lock = NSLock()
    private var items: [Breadcrumb] = []
    private let capacity: Int
    private let directory: URL
    private let fileURL: URL

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init(capacity: Int, directory: URL, launchId: String) {
        self.capacity = max(1, capacity)
        self.directory = directory.appendingPathComponent("breadcrumbs", isDirectory: true)
        self.fileURL = self.directory.appendingPathComponent(Self.fileName(for: launchId))
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    static func fileName(for launchId: String) -> String { "breadcrumbs-\(launchId).json" }

    private let queue = DispatchQueue(label: "com.matlub.crash.breadcrumbs", qos: .utility)
    private var flushScheduled = false

    func add(_ crumb: Breadcrumb) {
        lock.lock()
        items.append(crumb)
        if items.count > capacity { items.removeFirst(items.count - capacity) }
        let schedule = !flushScheduled
        flushScheduled = true
        lock.unlock()
        // Persist at most a few times per second: encoding 100 crumbs on every network request would add up.
        if schedule { queue.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.flush() } }
    }

    private func flush() {
        lock.lock()
        flushScheduled = false
        let snapshot = items
        lock.unlock()
        if let data = try? Self.encoder.encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func all() -> [Breadcrumb] {
        lock.lock(); defer { lock.unlock() }
        return items
    }

    /// Breadcrumbs persisted by the launch with this id, if still on disk.
    func persisted(forLaunchId launchId: String) -> [[String: Any]]? {
        let url = directory.appendingPathComponent(Self.fileName(for: launchId))
        guard let data = try? Data(contentsOf: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return arr
    }

    /// Deletes files of launches other than the given ids (plus the 3 most recent, like the console log).
    func prune(keeping launchIds: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let keep = Set(launchIds.map(Self.fileName(for:)))
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
