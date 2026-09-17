import Foundation

extension MatlubCrashZ {
    /// Runtime configuration for the crash reporter.
    public struct Configuration {
        /// Base URL of your crash server, e.g. `https://crash.example.com`.
        public var serverURL: URL
        /// Per-app API key issued by the server panel.
        public var apiKey: String
        /// Free-form environment label ("production", "testflight", "debug").
        public var environment: String
        /// Maximum breadcrumbs kept in memory and attached to reports.
        public var maxBreadcrumbs: Int
        /// Maximum number of pending (not yet uploaded) events kept on disk.
        public var maxPendingEvents: Int
        /// Also subscribe to MetricKit diagnostics (crash / hang / cpu / disk-write).
        public var enableMetricKit: Bool
        /// Install the in-process KSCrash handlers (signal / mach / NSException / C++ / watchdog / termination).
        public var enableKSCrash: Bool
        /// Upload pending events automatically at launch and on foreground.
        public var autoUpload: Bool
        /// Print SDK diagnostics to the console.
        public var debugLogging: Bool
        /// Capture stdout/stderr (print, NSLog) into a rolling file and attach it to crash reports as `console_log`.
        public var captureConsoleLog: Bool
        /// Also report main-thread hangs that recovered on their own (≥250 ms). Noisy; watchdog kills are reported regardless.
        public var reportResolvedHangs: Bool
        /// Mirror `os.Logger` / `os_log` entries of this process into the console log (polled every 10 s).
        public var captureOSLog: Bool
        /// Only these os_log subsystems (prefix match). `nil` = everything except Apple's own.
        public var osLogSubsystems: [String]?
        /// Automatic breadcrumbs: screens (UIKit view controllers), memory warnings, low power, thermal, active/inactive.
        public var autoBreadcrumbs: Bool
        /// Automatic breadcrumbs for URLSession requests (method, host+path, status, duration). Query strings are never recorded.
        public var networkBreadcrumbs: Bool
        /// Fetch server-side overrides (`RemoteConfig`) once per launch and apply them on the next launch.
        public var remoteConfig: Bool

        public init(
            serverURL: URL,
            apiKey: String,
            environment: String = "production",
            maxBreadcrumbs: Int = 100,
            maxPendingEvents: Int = 50,
            enableMetricKit: Bool = true,
            enableKSCrash: Bool = true,
            autoUpload: Bool = true,
            debugLogging: Bool = false,
            captureConsoleLog: Bool = true,
            reportResolvedHangs: Bool = false,
            captureOSLog: Bool = true,
            osLogSubsystems: [String]? = nil,
            autoBreadcrumbs: Bool = true,
            networkBreadcrumbs: Bool = true,
            remoteConfig: Bool = true
        ) {
            self.serverURL = serverURL
            self.apiKey = apiKey
            self.environment = environment
            self.maxBreadcrumbs = maxBreadcrumbs
            self.maxPendingEvents = maxPendingEvents
            self.enableMetricKit = enableMetricKit
            self.enableKSCrash = enableKSCrash
            self.autoUpload = autoUpload
            self.debugLogging = debugLogging
            self.captureConsoleLog = captureConsoleLog
            self.reportResolvedHangs = reportResolvedHangs
            self.captureOSLog = captureOSLog
            self.osLogSubsystems = osLogSubsystems
            self.autoBreadcrumbs = autoBreadcrumbs
            self.networkBreadcrumbs = networkBreadcrumbs
            self.remoteConfig = remoteConfig
        }
    }
}
