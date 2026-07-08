import Foundation

/// Per-model context sizes from models.dev (the open model-metadata database
/// OpenCode itself uses). Fetched at most weekly, distilled into a flat
/// `model → usable input tokens` map cached in the bridge state directory.
/// Lookups fall back to the built-in family table when the catalog is absent.
public enum ModelCatalog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var contexts: [String: Int] = [:]

    private static let sourceURL = URL(string: "https://models.dev/api.json")!
    private static let maxAge: TimeInterval = 7 * 24 * 60 * 60

    public static func cacheURL(stateDirectory: URL) -> URL {
        stateDirectory.appendingPathComponent("model-contexts.json")
    }

    /// Loads the distilled cache into memory, falling back to the snapshot
    /// bundled at build time (models.dev data, MIT licensed). Cheap; call at
    /// startup.
    public static func configure(stateDirectory: URL) {
        if let data = try? Data(contentsOf: cacheURL(stateDirectory: stateDirectory)),
           let map = try? JSONDecoder().decode([String: Int].self, from: data) {
            lock.lock()
            contexts = map
            lock.unlock()
            return
        }
        let bundle = continuoResourceBundle("agent-sync_AgentSyncCore", fallback: .module)
        if let bundled = bundle.url(forResource: "model-contexts", withExtension: "json"),
           let data = try? Data(contentsOf: bundled),
           let map = try? JSONDecoder().decode([String: Int].self, from: data) {
            lock.lock()
            contexts = map
            lock.unlock()
        }
    }

    /// One-shot fetch + distill, used by the build-time snapshot updater.
    public static func fetchDistilled() -> [String: Int]? {
        fetchCatalogData(timeout: 30).flatMap(distill(apiJSON:))
    }

    /// Refreshes from models.dev when the cache is missing or older than a
    /// week, then loads it. Network errors leave the existing cache in place.
    public static func refreshIfStale(stateDirectory: URL) {
        let cache = cacheURL(stateDirectory: stateDirectory)
        if let modified = try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < maxAge {
            configure(stateDirectory: stateDirectory)
            return
        }

        if let fetched = fetchCatalogData(timeout: 15),
           let map = distill(apiJSON: fetched), !map.isEmpty {
            try? FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            if let encoded = try? JSONEncoder().encode(map) {
                try? encoded.write(to: cache, options: [.atomic])
            }
        }
        configure(stateDirectory: stateDirectory)
    }

    /// Blocking GET of the models.dev catalog; nil on any non-200 or timeout.
    private static func fetchCatalogData(timeout: TimeInterval) -> Data? {
        let semaphore = DispatchSemaphore(value: 0)
        var fetched: Data?
        URLSession.shared.dataTask(with: sourceURL) { data, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                fetched = data
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + timeout)
        return fetched
    }

    /// Usable input tokens for a model, matched as "provider/model" or bare
    /// model id. Nil when unknown.
    public static func contextTokens(forModel model: String) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if let exact = contexts[model.lowercased()] {
            return exact
        }
        // opencode-style "provider/model" also matches on the bare model id.
        if let slash = model.firstIndex(of: "/"),
           let bare = contexts[String(model[model.index(after: slash)...]).lowercased()] {
            return bare
        }
        return nil
    }

    /// models.dev api.json → flat map. Uses min(context, input) since some
    /// models cap input below the total window. Bare ids prefer first-party
    /// providers so "claude-sonnet-5" means Anthropic's numbers.
    static func distill(apiJSON: Data) -> [String: Int]? {
        guard let root = try? JSONSerialization.jsonObject(with: apiJSON) as? [String: Any] else {
            return nil
        }
        var map: [String: Int] = [:]
        let firstParty: Set<String> = ["anthropic", "openai"]

        for (provider, value) in root {
            guard let providerObject = value as? [String: Any],
                  let models = providerObject["models"] as? [String: Any] else {
                continue
            }
            for (modelID, modelValue) in models {
                guard let model = modelValue as? [String: Any],
                      let limit = model["limit"] as? [String: Any],
                      let context = limit["context"] as? Int else {
                    continue
                }
                let input = limit["input"] as? Int ?? context
                let usable = min(context, input)
                map["\(provider)/\(modelID)".lowercased()] = usable

                let bareKey = modelID.lowercased()
                if firstParty.contains(provider) || map[bareKey] == nil {
                    map[bareKey] = usable
                }
            }
        }
        return map
    }

    /// Test hook.
    static func setContexts(_ map: [String: Int]) {
        lock.lock()
        contexts = map.reduce(into: [:]) { $0[$1.key.lowercased()] = $1.value }
        lock.unlock()
    }
}
