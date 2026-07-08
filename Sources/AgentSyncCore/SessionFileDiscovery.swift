import Foundation

func discoverJSONLSessionFiles(
    under root: URL,
    lookbackDays: Int?,
    maximumSessions: Int?,
    excludingPathComponents excluded: Set<String> = []
) throws -> [URL] {
    let fileManager = FileManager.default
    let cutoff = lookbackDays.map {
        Date().addingTimeInterval(-Double($0) * 24 * 60 * 60)
    }

    let candidates = try fileManager
        .subpathsOfDirectory(atPath: root.path)
        .filter { $0.hasSuffix(".jsonl") }
        .filter { path in
            excluded.isEmpty || !path.split(separator: "/").contains { excluded.contains(String($0)) }
        }
        .compactMap { relativePath -> (url: URL, modifiedAt: Date) in
            let url = root.appendingPathComponent(relativePath)
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            let modifiedAt = values?.contentModificationDate ?? Date.distantPast
            return (url, modifiedAt)
        }
        .filter { candidate in
            guard let cutoff else {
                return true
            }
            return candidate.modifiedAt >= cutoff
        }
        .sorted { lhs, rhs in
            if lhs.modifiedAt == rhs.modifiedAt {
                return lhs.url.path < rhs.url.path
            }
            return lhs.modifiedAt > rhs.modifiedAt
        }

    if let maximumSessions {
        return candidates.prefix(maximumSessions).map(\.url)
    }
    return candidates.map(\.url)
}
