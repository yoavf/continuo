import Foundation

enum LineJSON {
    static func readObjects(from url: URL) throws -> [[String: JSONValue]] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var objects: [[String: JSONValue]] = []

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else {
                continue
            }
            let data = Data(line.utf8)
            let foundationValue: Any
            do {
                foundationValue = try JSONSerialization.jsonObject(with: data)
            } catch {
                continue
            }

            let value: JSONValue
            do {
                value = try JSONValue.foundation(foundationValue)
            } catch {
                continue
            }

            if case .object(let object) = value {
                objects.append(object)
            }
        }
        return objects
    }

    static func renderObjects(_ objects: [[String: JSONValue]]) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines: [String] = []
        for object in objects {
            let data = try encoder.encode(JSONValue.object(object))
            guard let line = String(data: data, encoding: .utf8) else {
                throw AgentSyncError.encodingFailed("Could not encode JSONL line.")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
