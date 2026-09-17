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

    // Both hooks *wrap* whatever implementation is installed at the time (ours or another SDK's) and always call
    // it through, instead of exchanging selectors. That keeps the chain intact when Firebase, Mixpanel, Sentry etc.
    // swizzle the same methods before or after us.

    private static var didSwizzleVC = false
    private static func swizzleViewDidAppear() {
        guard !didSwizzleVC, let method = class_getInstanceMethod(UIViewController.self, #selector(UIViewController.viewDidAppear(_:))) else { return }
        didSwizzleVC = true
        typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        let block: @convention(block) (AnyObject, Bool) -> Void = { obj, animated in
            original(obj, #selector(UIViewController.viewDidAppear(_:)), animated)
            if let vc = obj as? UIViewController { AutoBreadcrumbs.recordScreen(vc) }
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    fileprivate static func recordScreen(_ vc: UIViewController) {
        let name = String(describing: type(of: vc))
        // Skip UIKit/SwiftUI plumbing controllers; app controllers are what a person would call "screens".
        let noise = ["UIHostingController", "UINavigationController", "UITabBarController", "UISplitViewController", "_UI", "UIInputWindowController", "UIAlertController", "UIEditingOverlay", "UISystemInputAssist", "UIPageViewController", "PresentationHostingController", "UICompatibilityInputViewController", "UIPredictionViewController", "UIKeyboard"]
        guard !noise.contains(where: { name.hasPrefix($0) }) else { return }
        MatlubCrashZ.log("screen: \(name)", category: "navigation")
    }

    // MARK: network

    private static var didSwizzleTask = false
    private static func swizzleTaskResume() {
        guard !didSwizzleTask, let method = class_getInstanceMethod(URLSessionTask.self, #selector(URLSessionTask.resume)) else { return }
        didSwizzleTask = true
        typealias Fn = @convention(c) (AnyObject, Selector) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Fn.self)
        let block: @convention(block) (AnyObject) -> Void = { obj in
            if let task = obj as? URLSessionTask { AutoBreadcrumbs.recordRequest(task) }
            original(obj, #selector(URLSessionTask.resume))
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    fileprivate static func recordRequest(_ task: URLSessionTask) {
        // Log once per task, on first resume; completion is observed through KVO on `state`.
        guard objc_getAssociatedObject(task, &taskStartKey) == nil, let req = task.originalRequest ?? task.currentRequest, let url = req.url else { return }
        objc_setAssociatedObject(task, &taskStartKey, Date(), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let method = req.httpMethod ?? "GET"
        let short = URLSessionTask.mc_shortURL(url)
        let obs = task.observe(\.state, options: [.new]) { task, _ in
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
        objc_setAssociatedObject(task, &taskObserverKey, obs, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

private var taskStartKey: UInt8 = 0
private var taskObserverKey: UInt8 = 0

extension URLSessionTask {

    /// host + path only: query strings and fragments often carry tokens.
    static func mc_shortURL(_ url: URL) -> String {
        guard let host = url.host else { return url.absoluteString }
        return "\(url.scheme ?? "https")://\(host)\(url.path)"
    }
}
