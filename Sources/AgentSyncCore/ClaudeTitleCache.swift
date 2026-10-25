import Foundation

/// Keeps repeated picker refreshes from streaming unchanged transcripts.
/// A cached entry also represents a successful scan that found no title.
final class ClaudeTitleCache: @unchecked Sendable {
    private struct Stamp: Equatable {
        let modifiedAt: Date
        let size: Int
        let sessionID: String
    }

    private struct Entry {
        let stamp: Stamp
        let title: String?
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let capacity: Int

    init(capacity: Int = 512) {
        self.capacity = max(1, capacity)
    }

    func title(for url: URL, sessionID: String, load: () throws -> String?) throws -> String? {
        func stamp() throws -> Stamp? {
            // Use a fresh URL so resource-value caching cannot hide a change.
            let values = try URL(fileURLWithPath: url.path).resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            guard let modifiedAt = values.contentModificationDate, let size = values.fileSize else {
                return nil
            }
            return Stamp(modifiedAt: modifiedAt, size: size, sessionID: sessionID)
        }

        let before = try stamp()
        if let before, let cached = lock.withLock({ entries[url.path] }), cached.stamp == before {
            return cached.title
        }
        let title = try load()
        // Never cache a failed read or a result from a file changing mid-scan.
        if let before, before == (try stamp()) {
            lock.withLock {
                if entries[url.path] == nil, entries.count >= capacity {
                    entries.removeAll(keepingCapacity: true)
                }
                entries[url.path] = Entry(stamp: before, title: title)
            }
        }
        return title
    }
}
