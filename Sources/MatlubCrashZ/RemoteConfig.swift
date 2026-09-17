import Foundation

/// Settings the server can change without an app update. Fetched once per launch (after the crash handlers are
/// installed), cached, and applied on the *next* launch so a bad value can never take the SDK down mid-run.
public struct RemoteConfig: Codable, Equatable {
    /// Kill switch: `false` stops capture and uploads entirely (config is still fetched so it can be turned back on).
    public var enabled: Bool?
    public var captureConsoleLog: Bool?
    public var captureOSLog: Bool?
    public var autoBreadcrumbs: Bool?
    public var networkBreadcrumbs: Bool?
    public var maxBreadcrumbs: Int?
    public var reportResolvedHangs: Bool?
    public var enableMetricKit: Bool?
    public var version: Int?

    static let cacheKey = "MatlubCrashZ.remoteConfig"
    static let etagKey = "MatlubCrashZ.remoteConfigETag"

    static func cached() -> RemoteConfig? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode(RemoteConfig.self, from: data)
    }

    static func fetch(configuration: MatlubCrashZ.Configuration) {
        var request = URLRequest(url: configuration.serverURL.appendingPathComponent("api/config"))
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("MatlubCrashZ/\(MatlubCrashZ.sdkVersion)", forHTTPHeaderField: "User-Agent")
        if let etag = UserDefaults.standard.string(forKey: etagKey) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, _ in
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 304 { return }
            guard http.statusCode == 200, let data, (try? JSONDecoder().decode(RemoteConfig.self, from: data)) != nil else { return }
            UserDefaults.standard.set(data, forKey: cacheKey)
            if let etag = http.value(forHTTPHeaderField: "ETag") { UserDefaults.standard.set(etag, forKey: etagKey) }
            SDKLog.info("remote config updated")
        }.resume()
    }
}

extension MatlubCrashZ.Configuration {
    /// Local configuration with the cached remote overrides applied on top.
    func applying(_ remote: RemoteConfig?) -> MatlubCrashZ.Configuration {
        guard let remote else { return self }
        var c = self
        if let v = remote.captureConsoleLog { c.captureConsoleLog = v }
        if let v = remote.captureOSLog { c.captureOSLog = v }
        if let v = remote.autoBreadcrumbs { c.autoBreadcrumbs = v }
        if let v = remote.networkBreadcrumbs { c.networkBreadcrumbs = v }
        if let v = remote.maxBreadcrumbs, v > 0 { c.maxBreadcrumbs = v }
        if let v = remote.reportResolvedHangs { c.reportResolvedHangs = v }
        if let v = remote.enableMetricKit { c.enableMetricKit = v }
        return c
    }
}
