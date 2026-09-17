import Foundation
import UIKit

/// Self-hosted crash reporter.
///
/// ```swift
/// @main struct MyApp: App {
///     init() {
///         MatlubCrashZ.start(.init(serverURL: URL(string: "https://crash.example.com")!, apiKey: "..."))
///     }
/// }
/// ```
///
/// Call `start` as early as possible (App `init` or `application(_:didFinishLaunchingWithOptions:)`).
/// Crashes are written to disk while the app dies and uploaded on the next launch.
public enum MatlubCrashZ {
    public static let sdkVersion = "1.1.1"

    nonisolated(unsafe) private static var shared: Core?
    private static let startLock = NSLock()

    /// Installs crash handlers, subscribes to MetricKit and uploads anything left over from the previous run.
    public static func start(_ configuration: Configuration) {
        startLock.lock(); defer { startLock.unlock() }
        guard shared == nil else {
            SDKLog.error("MatlubCrashZ.start called twice; ignoring")
            return
        }
        SDKLog.enabled = configuration.debugLogging
        let remote = configuration.remoteConfig ? RemoteConfig.cached() : nil
        if remote?.enabled == false {
            // Kill switch from the server: do nothing this launch, but keep checking so it can be re-enabled.
            SDKLog.info("disabled by remote config")
            RemoteConfig.fetch(configuration: configuration)
            return
        }
        shared = Core(configuration: configuration.applying(remote))
        if configuration.remoteConfig { RemoteConfig.fetch(configuration: configuration) }
    }

    /// The server-side overrides currently applied (cached from the previous launch), if any.
    public static var remoteConfig: RemoteConfig? { RemoteConfig.cached() }

    /// Records something that happened; the last N breadcrumbs are attached to every report.
    public static func log(_ message: String, category: String = "default", level: String = "info", data: [String: String]? = nil) {
        shared?.breadcrumbs.add(Breadcrumb(category: category, message: message, level: level, data: data))
    }

    /// Identifies the user in reports. Pass `nil` to clear.
    public static func setUser(id: String?, email: String? = nil, name: String? = nil) {
        shared?.setUser(id: id, email: email, name: name)
    }

    /// Attaches an arbitrary string to every report (e.g. current screen, feature flags).
    public static func setValue(_ value: String?, forKey key: String) {
        shared?.setCustom(value, forKey: key)
    }

    /// Reports a non-fatal error with the current stack trace, without terminating the app.
    public static func report(_ error: Error, context: String? = nil) {
        let name = String(reflecting: type(of: error))
        var reason = String(describing: error)
        if let context { reason = "\(context): \(reason)" }
        shared?.kscrash?.reportError(name: name, reason: reason, stack: Thread.callStackSymbols)
        shared?.scheduleUpload()
    }

    /// Anonymous per-install identifier used for distinct-user counts.
    public static var installId: String? { shared?.sessions.installId }

    /// Whether the previous run ended in a crash detected by the in-process handler.
    public static var crashedLastLaunch: Bool { shared?.kscrash?.crashedLastLaunch ?? false }

    /// Forces an upload attempt of pending events now.
    public static func flush() {
        shared?.scheduleUpload()
    }
}

// MARK: - Core

final class Core {
    let configuration: MatlubCrashZ.Configuration
    let store: EventStore
    let uploader: Uploader
    let kscrash: KSCrashCollector?
    private(set) var metricKit: MetricKitCollector?
    let breadcrumbs: BreadcrumbBuffer
    let sessions: SessionTracker
    private var console: ConsoleCapture?
    private var osLog: OSLogCapture?
    private var auto: AutoBreadcrumbs?

    private let lock = NSLock()
    private var user: [String: String] = [:]
    private var custom: [String: String] = [:]
    private var observers: [NSObjectProtocol] = []
    private let launchId = UUID().uuidString

    init(configuration: MatlubCrashZ.Configuration) {
        self.configuration = configuration
        store = EventStore(maxEvents: configuration.maxPendingEvents)
        uploader = Uploader(config: configuration, store: store)
        sessions = SessionTracker(config: configuration)

        var collector: KSCrashCollector? = nil
        if configuration.enableKSCrash {
            let c = KSCrashCollector()
            do {
                try c.install(appName: DeviceInfo.appName,
                              captureConsoleLog: configuration.captureConsoleLog,
                              reportResolvedHangs: configuration.reportResolvedHangs)
                collector = c
                SDKLog.info("KSCrash installed (crashedLastLaunch=\(c.crashedLastLaunch))")
            } catch {
                SDKLog.error("KSCrash install failed: \(error)")
            }
        }
        kscrash = collector

        breadcrumbs = BreadcrumbBuffer(capacity: configuration.maxBreadcrumbs) { [weak collector] json in
            collector?.setUserInfo(json, forKey: "breadcrumbs")
        }

        kscrash?.setUserInfo(launchId, forKey: "launchId")
        kscrash?.setUserInfo(configuration.environment, forKey: "environment")

        if configuration.captureConsoleLog {
            console = ConsoleCapture(directory: store.directory.deletingLastPathComponent())
        }

        // Move reports left by the previous run into our upload queue (attaching that launch's console log).
        drainKSCrashReports()
        console?.prune(keeping: [launchId])
        console?.start(launchId: launchId)
        if configuration.captureOSLog, let console {
            osLog = OSLogCapture(console: console, subsystems: configuration.osLogSubsystems)
            osLog?.start()
        }
        if configuration.autoBreadcrumbs || configuration.networkBreadcrumbs {
            auto = AutoBreadcrumbs(network: configuration.networkBreadcrumbs, screens: configuration.autoBreadcrumbs)
            auto?.start()
        }

        if configuration.enableMetricKit {
            metricKit = MetricKitCollector { [weak self] kind, json in
                self?.enqueue(source: "metrickit", kind: kind, payload: json)
                self?.scheduleUpload()
            }
        }

        observeLifecycle()
        sessions.recordLaunch(crashedLastLaunch: kscrash?.crashedLastLaunch ?? false)
        if configuration.autoUpload { scheduleUpload() }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: user / custom data

    func setUser(id: String?, email: String?, name: String?) {
        lock.lock()
        user = [:]
        if let id { user["id"] = id }
        if let email { user["email"] = email }
        if let name { user["name"] = name }
        let snapshot = user
        lock.unlock()
        kscrash?.setUserInfo(id, forKey: "user.id")
        kscrash?.setUserInfo(email, forKey: "user.email")
        kscrash?.setUserInfo(name, forKey: "user.name")
        _ = snapshot
    }

    func setCustom(_ value: String?, forKey key: String) {
        lock.lock()
        if let value { custom[key] = value } else { custom.removeValue(forKey: key) }
        lock.unlock()
        kscrash?.setUserInfo(value, forKey: "custom.\(key)")
    }

    // MARK: queueing

    private func drainKSCrashReports() {
        guard let kscrash else { return }
        let reports = kscrash.drainReports()
        guard !reports.isEmpty else { return }
        SDKLog.info("found \(reports.count) KSCrash report(s) from previous run")
        for report in reports {
            let kind = Self.kind(ofKSCrashReport: report)
            var consoleLog: String? = nil
            if let user = report["user"] as? [String: Any], let id = user["launchId"] as? String {
                consoleLog = console?.log(forLaunchId: id)
            }
            enqueue(source: "kscrash", kind: kind, payload: report, consoleLog: consoleLog)
        }
    }

    /// Maps KSCrash's error type to a coarse event kind.
    private static func kind(ofKSCrashReport report: [String: Any]) -> String {
        let crash = report["crash"] as? [String: Any]
        let error = crash?["error"] as? [String: Any]
        let type = (error?["type"] as? String) ?? ""
        switch type {
        case "user": return "nonfatal"
        case "termination", "memory_termination": return "termination"
        case "hang", "deadlock", "watchdog": return "hang"
        default: return "crash"
        }
    }

    func enqueue(source: String, kind: String, payload: [String: Any], consoleLog: String? = nil) {
        lock.lock()
        let userSnapshot = user
        let customSnapshot = custom
        lock.unlock()

        // KSCrash reports carry the breadcrumbs that were persisted at crash time; MetricKit diagnostics
        // describe an earlier process, so the current buffer would only mislead.
        let crumbs: [[String: Any]]
        if source == "kscrash" {
            crumbs = Self.breadcrumbs(fromKSCrashReport: payload)
        } else {
            crumbs = []
        }

        var event: [String: Any] = [
            "id": UUID().uuidString,
            "source": source,
            "kind": kind,
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "launchId": launchId,
            "user": userSnapshot,
            "custom": customSnapshot,
            "breadcrumbs": crumbs,
            "payload": Self.sanitize(payload),
        ]
        if let consoleLog { event["consoleLog"] = consoleLog }
        store.save(event)
    }

    private static func breadcrumbs(fromKSCrashReport report: [String: Any]) -> [[String: Any]] {
        guard let user = report["user"] as? [String: Any],
              let json = user["breadcrumbs"] as? String,
              let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return arr
    }

    /// JSONSerialization refuses NaN/inf and non-JSON types; scrub them so a bad value never blocks an upload.
    private static func sanitize(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            var out: [String: Any] = [:]
            for (k, v) in dict { out[k] = sanitize(v) }
            return out
        case let arr as [Any]:
            return arr.map(sanitize)
        case let num as NSNumber:
            let d = num.doubleValue
            if d.isNaN || d.isInfinite { return NSNull() }
            return num
        case is String, is NSNull, is Bool:
            return value
        case let date as Date:
            return ISO8601DateFormatter().string(from: date)
        case let data as Data:
            return data.base64EncodedString()
        default:
            return String(describing: value)
        }
    }

    // MARK: upload

    func scheduleUpload() {
        guard configuration.autoUpload else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let context = DeviceInfo.snapshot(environment: self.configuration.environment, installId: self.sessions.installId)
            DispatchQueue.global(qos: .utility).async {
                self.uploader.uploadPending(context: context)
            }
        }
    }

    private func observeLifecycle() {
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MatlubCrashZ.log("app will enter foreground", category: "lifecycle")
            self?.scheduleUpload()
            self?.sessions.flush() // resend counts that could not be delivered at launch
        })
        observers.append(nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MatlubCrashZ.log("app did enter background", category: "lifecycle")
        })
    }
}
