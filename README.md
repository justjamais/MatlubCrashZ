# MatlubCrashZ

Self-hosted crash reporting SDK for iOS (Swift, iOS 16+). Pairs with the [CrashMatlub server](https://crash.matlubapps.com).

- **In-process crash capture** via [KSCrash](https://github.com/kstenerud/KSCrash): Mach exceptions, signals, NSException, C++ exceptions, main-thread watchdog, OS terminations (memory pressure, thermal, CPU).
- **MetricKit** diagnostics as an independent second source (crash, hang, CPU / disk-write exceptions).
- Breadcrumbs, user identity, custom keys, non-fatal errors.
- stdout/stderr console capture attached to the crash of the same launch.
- Session counting for crash-free sessions / users (one tiny request per launch, batched when offline).
- Reports are written to disk while the app dies and uploaded on the next launch. No third-party services.

## Install

Xcode → File → *Add Package Dependencies…* → paste the repository URL → *Up to Next Major* from `1.0.0`.
Or in `Package.swift`:

```swift
.package(url: "https://github.com/justjamais/MatlubCrashZ.git", from: "1.0.0")
```

## Setup

Start it before anything else so early crashes are caught too:

```swift
import SwiftUI
import MatlubCrashZ

@main
struct MyApp: App {
    init() {
        MatlubCrashZ.start(.init(
            serverURL: URL(string: "https://crash.matlubapps.com")!,
            apiKey: "<your app's API key>"
        ))
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

With an `AppDelegate`, put the same call as the first line of `application(_:didFinishLaunchingWithOptions:)`.

Optional:

```swift
MatlubCrashZ.log("opened checkout", category: "nav")      // breadcrumb (last 100 are attached to every report)
MatlubCrashZ.setUser(id: user.id, email: user.email)
MatlubCrashZ.setValue("Checkout", forKey: "screen")       // custom key on every report
MatlubCrashZ.report(error, context: "payment")            // non-fatal
MatlubCrashZ.crashedLastLaunch                            // Bool
MatlubCrashZ.flush()                                      // upload pending reports now
```

SwiftUI screens: `HomeView().crashScreen("Home")` records a navigation breadcrumb on every appearance
(UIKit view controllers are recorded automatically).

`Configuration` options: `environment`, `maxBreadcrumbs`, `maxPendingEvents`, `enableMetricKit`, `enableKSCrash`,
`autoUpload`, `debugLogging`, `captureConsoleLog`, `reportResolvedHangs`, `captureOSLog`, `osLogSubsystems`,
`autoBreadcrumbs`, `networkBreadcrumbs`, `remoteConfig`.

## What is collected automatically

- **Breadcrumbs**: UIKit screen appearances, `URLSession` requests (method, host + path, status, duration — never query
  strings or bodies), memory warnings, low-power mode, thermal state, active/inactive/background transitions.
- **Console log**: `print` / `NSLog` / `printf` (stdout & stderr tee) and `os.Logger` / `os_log` entries of the process
  (polled every 10 s), attached to the crash of the same launch.
- **Sessions**: one launch = one session, reported in a single request after launch.

## Remote configuration

Once per launch the SDK fetches `GET /api/config` and caches it; the values apply on the *next* launch. From the panel's
Setup page you can turn features on/off per app without shipping an update, including an `enabled` kill switch.
Set `remoteConfig: false` to opt out.

## dSYMs

Release builds need *DWARF with dSYM File*. Add a *Run Script* build phase (after *Embed Frameworks*) that uploads the
archive's dSYMs — the server's setup page generates the exact script with your API key. Symbols can also be uploaded later
from the panel; matching events are re-symbolicated automatically.

## Testing

Crash handlers do not run while the Xcode debugger is attached. Run the app from the home screen, trigger a crash
(`fatalError("test")`), relaunch — the report appears in the panel within seconds. MetricKit diagnostics are only delivered
on real devices, usually on the next launch.

## Notes

- Do not run another crash reporter (Crashlytics, Sentry) in the same app; the handlers override each other.
- `os.Logger` output is not captured by the console log (it never reaches stdout); use `MatlubCrashZ.log` for it.
- Minimum iOS 16, Swift 5.9 / Xcode 15+.

MIT License.
