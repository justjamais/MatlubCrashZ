import Foundation
import OSLog
import UIKit

/// Mirrors this process's `os.Logger` / `os_log` entries into the console log file. iOS only lets an app read its
/// *own* process's log store, so entries are polled while the app runs (every `interval` seconds, plus when the app goes
/// to the background); the last few seconds before a crash can be missing.
final class OSLogCapture {
    private let console: ConsoleCapture
    private let subsystems: [String]?
    private let interval: TimeInterval
    private var timer: DispatchSourceTimer?
    private var lastDate = Date()
    private let queue = DispatchQueue(label: "com.matlub.crash.oslog", qos: .utility)
    private var observers: [NSObjectProtocol] = []
    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; f.locale = Locale(identifier: "en_US_POSIX"); return f }()

    /// - subsystems: only these subsystems (prefix match); `nil` = everything except Apple's own (`com.apple.*`).
    init(console: ConsoleCapture, subsystems: [String]?, interval: TimeInterval = 10) {
        self.console = console
        self.subsystems = subsystems
        self.interval = interval
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + interval, repeating: interval)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.poll() }
        })
    }

    deinit {
        timer?.cancel()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func poll() {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return }
        let since = lastDate
        let position = store.position(date: since)
        guard let entries = try? store.getEntries(at: position) else { return }
        var newest = since
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries where entry.date > since {
            if !accepts(entry.subsystem) { continue }
            let level: String
            switch entry.level { case .debug: level = "debug"; case .info: level = "info"; case .notice: level = "notice"; case .error: level = "error"; case .fault: level = "fault"; default: level = "?" }
            lines.append("\(Self.time.string(from: entry.date)) [\(level)] \(entry.subsystem)/\(entry.category): \(entry.composedMessage)")
            if entry.date > newest { newest = entry.date }
        }
        lastDate = newest
        if !lines.isEmpty { console.appendLine(lines.joined(separator: "\n")) }
    }

    private func accepts(_ subsystem: String) -> Bool {
        if let subsystems { return subsystems.contains { subsystem.hasPrefix($0) } }
        return !subsystem.hasPrefix("com.apple.") && !subsystem.isEmpty && subsystem != "com.matlub.crash"
    }
}
