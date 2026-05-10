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
