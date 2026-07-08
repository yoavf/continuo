import Foundation

enum NativeFileWriter {
    static func writeAtomically(
        text: String,
        to destination: URL,
        replacingExistingBridgeFile: Bool,
        allowedRoot: URL
    ) throws {
        let fm = FileManager.default
        let destinationPath = canonicalPath(destination)
        let rootPath = canonicalPath(allowedRoot)
        guard destinationPath.hasPrefix(rootPath + "/") || destinationPath == rootPath else {
            throw AgentSyncError.unsafeWrite("Refusing to write outside configured root: \(destination.path)")
        }

        let directory = destination.deletingLastPathComponent()
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)

        if fm.fileExists(atPath: destination.path) && !replacingExistingBridgeFile {
            throw AgentSyncError.unsafeWrite("Refusing to overwrite a file not recorded as bridge-owned: \(destination.path)")
        }

        let tmp = directory.appendingPathComponent(".\(destination.lastPathComponent).agent-sync.tmp")
        if fm.fileExists(atPath: tmp.path) {
            try fm.removeItem(at: tmp)
        }
        try text.write(to: tmp, atomically: true, encoding: .utf8)

        if fm.fileExists(atPath: destination.path) {
            try fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tmp, to: destination)
    }

    /// Canonicalizes a path whether or not it exists yet, by resolving the
    /// deepest existing ancestor and re-appending the rest. Plain
    /// standardization is asymmetric (it strips "/private" only when the full
    /// path exists), which broke prefix containment checks for files about to
    /// be created.
    private static func canonicalPath(_ url: URL) -> String {
        let fm = FileManager.default
        var existing = url.standardizedFileURL
        var tail: [String] = []
        while !fm.fileExists(atPath: existing.path), existing.pathComponents.count > 1 {
            tail.append(existing.lastPathComponent)
            existing = existing.deletingLastPathComponent()
        }
        var resolved = existing.resolvingSymlinksInPath()
        for component in tail.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.path
    }
}
