import Foundation
import KSCrashRecording

/// Installs the in-process crash handlers and drains reports written by a previous run.
final class KSCrashCollector {
    private let kscrash = KSCrash.shared

    func install(appName: String, captureConsoleLog: Bool, reportResolvedHangs: Bool) throws {
        let config = KSCrashConfiguration()
        // Everything that is safe on real users' devices: mach, signal, C++, NSException,
        // zombie is excluded (too expensive), plus termination (OOM / watchdog kills) and watchdog (hangs).
        config.monitors = [.productionSafe, .termination, .watchdog]
        config.enableSwiftAsyncStackTraces = true
        config.enableQueueNameSearch = true
        config.enableMemoryIntrospection = false
        config.addConsoleLogToReport = false // KSCrash only captures its own logger here; app output is captured by ConsoleCapture
        config.enableHangReporting = reportResolvedHangs
        config.enableCPUExceptionReporting = true

        let storeConfig = CrashReportStoreConfiguration()
        storeConfig.appName = appName
        storeConfig.maxReportCount = 20
        config.reportStoreConfiguration = storeConfig

        try kscrash.install(with: config)
    }

    var crashedLastLaunch: Bool { kscrash.crashedLastLaunch }

    func setUserInfo(_ value: String?, forKey key: String) {
        kscrash.setUserInfo(value, forKey: key)
    }

    /// Returns every stored report as a raw dictionary and removes it from KSCrash's store.
    func drainReports() -> [[String: Any]] {
        guard let store = kscrash.reportStore else { return [] }
        var reports: [[String: Any]] = []
        for id in store.reportIDs {
            let reportID = id.int64Value
            if let report = store.report(for: reportID) {
                reports.append(report.value)
            }
            store.deleteReport(with: reportID)
        }
        return reports
    }

    func reportError(name: String, reason: String?, stack: [String]?) {
        kscrash.reportUserException(name, reason: reason, language: "swift", lineOfCode: nil,
                                    stackTrace: stack, logAllThreads: true, terminateProgram: false)
    }
}
