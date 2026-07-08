import Foundation

/// Resolves a SwiftPM resource bundle in a way that survives being packaged
/// into a `.app`.
///
/// The generated `Bundle.module` for our targets only checks two locations:
/// `Bundle.main.bundleURL/<name>.bundle` (the `.app` root — where the code
/// signature forbids us from putting resources) and a machine-local `.build`
/// path baked in at compile time. In a distributed app neither exists, so
/// `Bundle.module` fatal-errors on launch. Resources are correctly signed
/// under `Contents/Resources`, so look there first and only fall back to
/// `Bundle.module` for `swift run` / test runs (autoclosure, so the possibly
/// fatal accessor is evaluated only if the primary lookup misses).
public func continuoResourceBundle(_ name: String, fallback: @autoclosure () -> Bundle) -> Bundle {
    if let url = Bundle.main.resourceURL?.appendingPathComponent("\(name).bundle"),
       let bundle = Bundle(url: url) {
        return bundle
    }
    return fallback()
}
