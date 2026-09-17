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

/// Thread-safe ring buffer of breadcrumbs. A JSON snapshot is pushed to KSCrash's
/// persistent user-info store on every write so it survives a hard crash.
final class BreadcrumbBuffer {
    private let lock = NSLock()
    private var items: [Breadcrumb] = []
    private let capacity: Int
    private let onChange: (String) -> Void

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    init(capacity: Int, onChange: @escaping (String) -> Void) {
        self.capacity = max(1, capacity)
        self.onChange = onChange
    }

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
        if let data = try? Self.encoder.encode(snapshot), let json = String(data: data, encoding: .utf8) {
            onChange(json)
        }
    }

    func all() -> [Breadcrumb] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}
