import Foundation

struct EnvCompatLayer: Sendable {
    let envFilePaths: [String]

    func write(key: String, value: String) {
        for path in envFilePaths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            do {
                try writeToEnvFile(at: expandedPath, key: key, value: value)
            } catch {
                print("[EnvCompatLayer] Failed to write \(key) to \(path): \(error)")
            }
        }
    }

    /// Writes each pair whose key a file does not set yet. A key that is there keeps
    /// its value, also when the line is `export KEY=…`. Throws when a file cannot be
    /// read or written. Returns the keys it added, in the order of `pairs`.
    @discardableResult
    func addMissing(_ pairs: [(key: String, value: String)]) throws -> [String] {
        var added: [String] = []
        for path in envFilePaths {
            let expandedPath = NSString(string: path).expandingTildeInPath
            let content = FileManager.default.fileExists(atPath: expandedPath)
                ? try String(contentsOfFile: expandedPath, encoding: .utf8) : ""
            let present = Set(content.components(separatedBy: .newlines).compactMap(RunnerEnv.assignedKey))
            for pair in pairs where !present.contains(pair.key) {
                try writeToEnvFile(at: expandedPath, key: pair.key, value: pair.value)
                if !added.contains(pair.key) { added.append(pair.key) }
            }
        }
        return added
    }

    private func writeToEnvFile(at path: String, key: String, value: String) throws {
        let url = URL(fileURLWithPath: path)
        var lines: [String]

        if FileManager.default.fileExists(atPath: path) {
            let content = try String(contentsOf: url, encoding: .utf8)
            lines = content.components(separatedBy: "\n")
        } else {
            lines = []
        }

        let prefix = "\(key)="
        var found = false
        for (index, line) in lines.enumerated() {
            if line.hasPrefix(prefix) {
                lines[index] = "\(key)=\(value)"
                found = true
                break
            }
        }
        if !found {
            if let last = lines.last, last.isEmpty {
                lines.insert("\(key)=\(value)", at: lines.count - 1)
            } else {
                lines.append("\(key)=\(value)")
            }
        }

        let content = lines.joined(separator: "\n")
        try content.write(to: url, atomically: true, encoding: .utf8)
    }
}
