import Foundation
import UIKit
import ObjectiveC

/// Breadcrumbs the app gets for free: screens (UIKit view controllers), network requests, memory warnings,
/// low-power mode, thermal state, foreground/background.
final class AutoBreadcrumbs {
    private var observers: [NSObjectProtocol] = []
    private let network: Bool
    private let screens: Bool

    init(network: Bool, screens: Bool) {
        self.network = network
        self.screens = screens
    }

    func start() {
        let nc = NotificationCenter.default
        let pi = ProcessInfo.processInfo
        observers.append(nc.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { _ in
            MatlubCrashZ.log("memory warning", category: "system", level: "warning")
        })
        observers.append(nc.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
            MatlubCrashZ.log("low power mode \(pi.isLowPowerModeEnabled ? "on" : "off")", category: "system")
        })
        observers.append(nc.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
            let s: String
            switch pi.thermalState { case .nominal: s = "nominal"; case .fair: s = "fair"; case .serious: s = "serious"; case .critical: s = "critical"; @unknown default: s = "?" }
            MatlubCrashZ.log("thermal state \(s)", category: "system", level: pi.thermalState == .critical || pi.thermalState == .serious ? "warning" : "info")
        })
        observers.append(nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MatlubCrashZ.log("app did become active", category: "lifecycle")
        })
        observers.append(nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { _ in
            MatlubCrashZ.log("app will resign active", category: "lifecycle")
        })
        if screens { Self.swizzleViewDidAppear() }
        if network { Self.swizzleTaskResume() }
    }

    deinit { observers.forEach { NotificationCenter.default.removeObserver($0) } }

    // MARK: screens (UIKit; SwiftUI screens use the `.crashScreen("Name")` modifier)

    private static var didSwizzleVC = false
    private static func swizzleViewDidAppear() {
        guard !didSwizzleVC else { return }
        didSwizzleVC = true
        let cls = UIViewController.self
        let sel = #selector(UIViewController.viewDidAppear(_:))
        let swz = #selector(UIViewController.mc_viewDidAppear(_:))
        guard let m1 = class_getInstanceMethod(cls, sel), let m2 = class_getInstanceMethod(cls, swz) else { return }
        method_exchangeImplementations(m1, m2)
    }

    // MARK: network

    private static var didSwizzleTask = false
    private static func swizzleTaskResume() {
        guard !didSwizzleTask else { return }
        didSwizzleTask = true
        let cls = URLSessionTask.self
        guard let m1 = class_getInstanceMethod(cls, #selector(URLSessionTask.resume)),
              let m2 = class_getInstanceMethod(cls, #selector(URLSessionTask.mc_resume)) else { return }
        method_exchangeImplementations(m1, m2)
    }
}

extension UIViewController {
    @objc func mc_viewDidAppear(_ animated: Bool) {
        mc_viewDidAppear(animated) // calls the original
        let name = String(describing: type(of: self))
        // Skip UIKit/SwiftUI plumbing controllers; app controllers are what a person would call "screens".
        let noise = ["UIHostingController", "UINavigationController", "UITabBarController", "UISplitViewController", "_UI", "UIInputWindowController", "UIAlertController", "UIEditingOverlay", "UISystemInputAssist", "UIPageViewController", "PresentationHostingController", "UICompatibilityInputViewController", "UIPredictionViewController", "UIKeyboard"]
        guard !noise.contains(where: { name.hasPrefix($0) }) else { return }
        MatlubCrashZ.log("screen: \(name)", category: "navigation")
    }
}

private var taskStartKey: UInt8 = 0
private var taskObserverKey: UInt8 = 0

extension URLSessionTask {
    @objc func mc_resume() {
        // Log once per task, on first resume.
        if objc_getAssociatedObject(self, &taskStartKey) == nil, let req = originalRequest ?? currentRequest, let url = req.url {
            objc_setAssociatedObject(self, &taskStartKey, Date(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            let method = req.httpMethod ?? "GET"
            let short = Self.mc_shortURL(url)
            let obs = observe(\.state, options: [.new]) { task, _ in
                guard task.state == .completed || task.state == .canceling else { return }
                let started = objc_getAssociatedObject(task, &taskStartKey) as? Date ?? Date()
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                let status = (task.response as? HTTPURLResponse)?.statusCode
                let level = task.error != nil || (status ?? 0) >= 400 ? "error" : "info"
                var data: [String: String] = ["ms": String(ms)]
                if let status { data["status"] = String(status) }
                if let err = task.error { data["error"] = err.localizedDescription }
                MatlubCrashZ.log("\(method) \(short)", category: "http", level: level, data: data)
                objc_setAssociatedObject(task, &taskObserverKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            }
            objc_setAssociatedObject(self, &taskObserverKey, obs, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        mc_resume()
    }

    /// host + path only: query strings and fragments often carry tokens.
    static func mc_shortURL(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return "\(url.scheme ?? "https")://\(host)\(url.path)"
    }
}
