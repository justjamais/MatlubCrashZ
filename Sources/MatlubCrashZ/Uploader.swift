import Foundation

/// Sends pending events to the server. Events are deleted only after a 2xx response,
/// so anything that fails is retried on the next launch.
final class Uploader {
    private let config: MatlubCrashZ.Configuration
    private let store: EventStore
    private let session: URLSession
    private var inFlight = false
    private let lock = NSLock()

    init(config: MatlubCrashZ.Configuration, store: EventStore) {
        self.config = config
        self.store = store
        let sc = URLSessionConfiguration.ephemeral
        sc.timeoutIntervalForRequest = 30
        sc.waitsForConnectivity = false
        session = URLSession(configuration: sc)
    }

    func uploadPending(context: [String: Any], completion: (() -> Void)? = nil) {
        lock.lock()
        if inFlight { lock.unlock(); completion?(); return }
        inFlight = true
        lock.unlock()

        let files = store.pendingFiles()
        guard !files.isEmpty else {
            finish(); completion?(); return
        }
        SDKLog.info("uploading \(files.count) pending event(s)")

        // Batch up to 10 events per request.
        let batches = stride(from: 0, to: files.count, by: 10).map { Array(files[$0..<min($0 + 10, files.count)]) }
        let group = DispatchGroup()
        for batch in batches {
            group.enter()
            send(batch: batch, context: context) { group.leave() }
        }
        group.notify(queue: .global(qos: .utility)) { [weak self] in
            self?.finish()
            completion?()
        }
    }

    private func finish() {
        lock.lock(); inFlight = false; lock.unlock()
    }

    private func send(batch: [URL], context: [String: Any], completion: @escaping () -> Void) {
        var events: [[String: Any]] = []
        var sent: [URL] = []
        for url in batch {
            guard let data = try? Data(contentsOf: url),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                // Corrupt file: drop it.
                store.delete(url)
                continue
            }
            events.append(obj)
            sent.append(url)
        }
        guard !events.isEmpty else { completion(); return }

        var envelope = context
        envelope["uploadedAt"] = ISO8601DateFormatter().string(from: Date())
        envelope["events"] = events

        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { completion(); return }

        var request = URLRequest(url: config.serverURL.appendingPathComponent("api/ingest"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("MatlubCrashZ/\(MatlubCrashZ.sdkVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        session.dataTask(with: request) { [store] _, response, error in
            defer { completion() }
            if let error {
                SDKLog.error("upload failed: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200..<300:
                SDKLog.info("uploaded \(sent.count) event(s)")
                sent.forEach { store.delete($0) }
            case 400, 401, 403, 413, 422:
                // Server rejected the payload permanently; retrying would never succeed.
                SDKLog.error("server rejected batch with \(status); dropping")
                sent.forEach { store.delete($0) }
            default:
                SDKLog.error("upload got HTTP \(status); will retry later")
            }
        }.resume()
    }
}
