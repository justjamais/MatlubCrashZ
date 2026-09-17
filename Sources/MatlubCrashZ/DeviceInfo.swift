import Foundation
import UIKit

enum DeviceInfo {
    /// Hardware identifier such as "iPhone16,2".
    static var modelIdentifier: String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
    }

    static var systemVersion: String { UIDevice.current.systemVersion }
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?" }
    static var appBuild: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?" }
    static var bundleId: String { Bundle.main.bundleIdentifier ?? "?" }
    static var executableName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String ?? "?" }
    static var appName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "?"
    }

    /// Snapshot of app + device state taken at upload time (not at crash time).
    @MainActor
    static func snapshot(environment: String, installId: String) -> [String: Any] {
        let device = UIDevice.current
        let pi = ProcessInfo.processInfo
        var disk: [String: Any] = [:]
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory()) {
            disk["free"] = (attrs[.systemFreeSize] as? NSNumber)?.int64Value
            disk["total"] = (attrs[.systemSize] as? NSNumber)?.int64Value
        }
        return [
            "app": [
                "bundleId": bundleId,
                "name": appName,
                "executable": executableName,
                "version": appVersion,
                "build": appBuild,
                "environment": environment,
            ],
            "device": [
                "installId": installId,
                "model": modelIdentifier,
                "systemName": device.systemName,
                "systemVersion": device.systemVersion,
                "locale": Locale.current.identifier,
                "timezone": TimeZone.current.identifier,
                "physicalMemory": pi.physicalMemory,
                "lowPowerMode": pi.isLowPowerModeEnabled,
                "disk": disk,
            ],
            "sdk": ["name": "MatlubCrashZ", "version": MatlubCrashZ.sdkVersion],
        ]
    }
}
