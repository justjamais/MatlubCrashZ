import Foundation
import UIKit

/// Counts app launches ("sessions") and how many of them ended in a crash, and reports them
/// to the server in one tiny request per launch. Counts accumulate locally when offline, so
/// nothing is lost and the server never sees more than one request per launch.
final class SessionTracker {
    private let config: MatlubCrashZ.Configuration
    private let defaults = UserDefaults.standard
    private let session: URLSession
    private let lock = NSLock()
    private var inFlight = false

    private enum Key {
        static let installId = "MatlubCrashZ.installId"
        static let pendingSessions = "MatlubCrashZ.pendingSessions"
        static let pendingCrashed = "MatlubCrashZ.pendingCrashed"
    }

    /// Anonymous, per-install identifier (survives launches, not reinstalls). Used only for counting distinct users.
    let installId: String

    init(config: MatlubCrashZ.Configuration) {
        self.config = config
        let sc = URLSessionConfiguration.ephemeral
        sc.timeoutIntervalForRequest = 15
        session = URLSession(configuration: sc)
        if let id = defaults.string(forKey: Key.installId) {
            installId = id
        } else {
            installId = UUID().uuidString
            defaults.set(installId, forKey: Key.installId)
        }
    }

    /// Call once per launch, right after the crash handler is installed.
    func recordLaunch(crashedLastLaunch: Bool) {
        lock.lock()
        defaults.set(defaults.integer(forKey: Key.pendingSessions) + 1, forKey: Key.pendingSessions)
        if crashedLastLaunch {
            defaults.set(defaults.integer(forKey: Key.pendingCrashed) + 1, forKey: Key.pendingCrashed)
        }
        lock.unlock()
        // Spread launches out (e.g. after a push wakes every device at once) so the server sees a smooth rate.
        let delay = Double.random(in: 0.5...10)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.flush()
        }
    }

    func flush() {
        lock.lock()
        if inFlight { lock.unlock(); return }
        let sessions = defaults.integer(forKey: Key.pendingSessions)
        let crashed = defaults.integer(forKey: Key.pendingCrashed)
        guard sessions > 0 else { lock.unlock(); return }
        inFlight = true
        lock.unlock()

        let body: [String: Any] = [
            "installId": installId,
            "sessions": sessions,
            "crashed": crashed,
            "appVersion": DeviceInfo.appVersion,
            "appBuild": DeviceInfo.appBuild,
            "osVersion": DeviceInfo.systemVersion,
            "device": DeviceInfo.modelIdentifier,
            "environment": config.environment,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { finish(); return }
        var request = URLRequest(url: config.serverURL.appendingPathComponent("api/session"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = data

        session.dataTask(with: request) { [weak self] _, response, error in
            guard let self else { return }
            defer { self.finish() }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if error == nil, (200..<300).contains(status) || status == 429 || (400..<500).contains(status) {
                // Accepted (or permanently rejected): either way don't resend these counts.
                self.lock.lock()
                self.defaults.set(max(0, self.defaults.integer(forKey: Key.pendingSessions) - sessions), forKey: Key.pendingSessions)
                self.defaults.set(max(0, self.defaults.integer(forKey: Key.pendingCrashed) - crashed), forKey: Key.pendingCrashed)
                self.lock.unlock()
                SDKLog.info("session ping ok (\(sessions) sessions, \(crashed) crashed)")
            } else {
                SDKLog.error("session ping failed (\(status)) \(error?.localizedDescription ?? ""); will retry next launch")
            }
        }.resume()
    }

    private func finish() {
        lock.lock(); inFlight = false; lock.unlock()
    }
}
