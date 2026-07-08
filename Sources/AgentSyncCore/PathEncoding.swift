import Foundation

public enum PathEncoding {
    /// Claude Code encodes a project cwd by replacing "/" AND "." with "-"
    /// (verified by letting Claude create a session from a dotted cwd:
    /// /Users/x/.codex/… → -Users-x--codex-…). Dotted-looking folders with
    /// preserved "." exist on disk from an older Claude version, but current
    /// resume resolution only reads the dashed form.
    public static func claudeProjectName(for cwd: String) -> String {
        let encoded = cwd
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ".", with: "-")
        return encoded.isEmpty ? "-unknown" : encoded
    }

    /// Best-effort inverse of claudeProjectName, used only as a display
    /// fallback when a transcript carries no cwd of its own.
    public static func decodeClaudeProjectName(_ folder: String) -> String {
        guard folder.hasPrefix("-") else {
            return folder
        }
        return "/" + folder.dropFirst().replacingOccurrences(of: "-", with: "/")
    }

    static func codexSessionPath(codexHome: URL, sessionID: String, date: Date) -> URL {
        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        let year = String(format: "%04d", components.year ?? 1970)
        let month = String(format: "%02d", components.month ?? 1)
        let day = String(format: "%02d", components.day ?? 1)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
        let timestamp = formatter.string(from: date)

        return codexHome
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(year, isDirectory: true)
            .appendingPathComponent(month, isDirectory: true)
            .appendingPathComponent(day, isDirectory: true)
            .appendingPathComponent("rollout-\(timestamp)-\(sessionID).jsonl")
    }
}
