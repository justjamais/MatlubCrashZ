# Roadmap / open items

Things we know about and may do later. Not scheduled.

- **Tests & CI**: unit tests for `EventStore` (queue, trim, corrupt file), `BreadcrumbBuffer` (capacity, coalesced persistence), `SessionTracker` (pending counts, retry) and a UI test app that crashes on demand; CI currently only builds.
- **Launch cost**: measure `MatlubCrashZ.start` with `os_signpost` (KSCrash install + MetricKit + swizzles run on the main thread). Expected < 30 ms; verify on an iPhone 8-class device.
- **Other platforms**: app extensions, watchOS, macOS, visionOS are not supported (package is iOS-only; `UIKit` is used for lifecycle and screens). Would need `#if canImport(UIKit)` splits and a KSCrash configuration without the watchdog monitor.
- **PII controls**: breadcrumb URL paths and `setUser(email:)` can carry personal data. Add `beforeSend` hook to scrub events, an allow/deny list for hosts in network breadcrumbs, and pair with the server-side "delete everything for user X" endpoint.
- **Session sampling**: `sessionSampleRate` remote flag for very large installs (server would scale counts by 1/rate).
- **Non-fatal stack quality**: `report(_:)` uses `Thread.callStackSymbols` strings; capture a real backtrace via KSCrash's user-reported path so the server can symbolicate it like a crash.
- **Data protection**: reports are written under Application Support with the default protection class; a crash while the device is locked after reboot (before first unlock) may fail to write. Consider `NSFileProtectionCompleteUntilFirstUserAuthentication` explicitly.
