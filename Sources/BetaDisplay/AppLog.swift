import Foundation
import os

/// Low-volume operational log.
///
/// The unified log is the only place where a later investigation can see why
/// an auto-start did or did not keep the saved transfer table installed, so
/// the launch, login-item, and recovery paths report there. Messages stay
/// short and free of user content.
enum AppLog {
    private static let subsystem = "io.github.ysdj.betadisplay"

    static let launch = Logger(subsystem: subsystem, category: "launch")
    static let lut = Logger(subsystem: subsystem, category: "lut")
    static let recovery = Logger(subsystem: subsystem, category: "recovery")

    static func describe(_ lut: DisplayLUT) -> String {
        String(
            format: "max %.4f/%.4f/%.4f",
            Double(lut.red.last ?? 0),
            Double(lut.green.last ?? 0),
            Double(lut.blue.last ?? 0)
        )
    }
}

extension Bundle {
    var betaDisplayVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    var betaDisplayBuild: String {
        object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}
