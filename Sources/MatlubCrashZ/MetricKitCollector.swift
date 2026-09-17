import Foundation
import MetricKit

/// Receives Apple's own diagnostics (delivered at the next launch after a crash/hang).
/// They are an independent second source: even if our in-process handler was never reached,
/// the OS still knows the app died and why.
final class MetricKitCollector: NSObject, MXMetricManagerSubscriber {
    private let onDiagnostic: (_ kind: String, _ json: [String: Any]) -> Void

    init(onDiagnostic: @escaping (_ kind: String, _ json: [String: Any]) -> Void) {
        self.onDiagnostic = onDiagnostic
        super.init()
        MXMetricManager.shared.add(self)
    }

    deinit {
        MXMetricManager.shared.remove(self)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        let iso = ISO8601DateFormatter()
        for payload in payloads {
            let window: [String: Any] = [
                "timeStampBegin": iso.string(from: payload.timeStampBegin),
                "timeStampEnd": iso.string(from: payload.timeStampEnd),
            ]
            payload.crashDiagnostics?.forEach { emit("crash", $0, window) }
            payload.hangDiagnostics?.forEach { emit("hang", $0, window) }
            payload.cpuExceptionDiagnostics?.forEach { emit("cpuException", $0, window) }
            payload.diskWriteExceptionDiagnostics?.forEach { emit("diskWriteException", $0, window) }
            payload.appLaunchDiagnostics?.forEach { emit("appLaunch", $0, window) }
        }
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        // Aggregate metrics are not needed for crash tracking.
    }

    private func emit(_ kind: String, _ diagnostic: MXDiagnostic, _ window: [String: Any]) {
        let data = diagnostic.jsonRepresentation()
        guard var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            SDKLog.error("MetricKit diagnostic is not a JSON object")
            return
        }
        obj["_payloadWindow"] = window
        onDiagnostic(kind, obj)
    }
}
