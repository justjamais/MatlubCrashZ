import Foundation
import os

enum SDKLog {
    nonisolated(unsafe) static var enabled = false
    private static let logger = Logger(subsystem: "com.matlub.crash", category: "sdk")

    static func info(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        logger.info("\(text, privacy: .public)")
    }

    static func error(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let text = message()
        logger.error("\(text, privacy: .public)")
    }
}
