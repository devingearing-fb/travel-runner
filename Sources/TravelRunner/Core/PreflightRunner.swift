import Foundation

@Observable
@MainActor
final class PreflightCheck: Identifiable {
    nonisolated let id: String
    nonisolated let name: String
    nonisolated let metadata: [String: String]
    var result: PreflightResult = .pending

    nonisolated init(id: String, name: String, metadata: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.metadata = metadata
    }
}

enum PreflightResult: Sendable {
    case pending
    case passed(detail: String)
    case warning(message: String)
    case failed(message: String, fix: String?)

    var isPassed: Bool {
        if case .passed = self { return true }
        return false
    }

    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }
}

struct PreflightRunner: Sendable {
    func allChecks(for services: [ServiceDefinition]) -> [PreflightCheck] {
        var checks: [PreflightCheck] = [
            PreflightCheck(id: "docker", name: ContainerRuntime.detect().displayName),
            PreflightCheck(id: "stripe-auth", name: "Stripe CLI Auth"),
            PreflightCheck(id: "yalc", name: "yalc CLI"),
        ]

        if let portalCwd = services.first(where: { $0.id == "travel-portal" })?.resolvedCwd {
            checks.append(PreflightCheck(
                id: "env-diff",
                name: "Env variables",
                metadata: ["cwd": portalCwd]
            ))
        }

        let ports = Set(services.compactMap { $0.probe?.port })
        for port in ports.sorted() {
            checks.append(PreflightCheck(id: "port-\(port)", name: "Port \(port) available"))
        }

        let cwds = Set(services.compactMap { $0.resolvedCwd })
        for cwd in cwds.sorted() {
            let dirName = URL(fileURLWithPath: cwd).lastPathComponent
            checks.append(PreflightCheck(
                id: "dir-\(dirName)",
                name: "\(dirName) exists",
                metadata: ["path": cwd]
            ))
        }

        return checks
    }

    func run(check: PreflightCheck) async -> PreflightResult {
        switch check.id {
        case "docker":
            let runtime = ContainerRuntime.detect()
            if await shellExitCode("docker ps >/dev/null 2>&1") == 0 {
                return .passed(detail: runtime.displayName)
            }
            _ = await shellExitCode("open -a '\(runtime.appName)'")
            for _ in 0..<10 {
                try? await Task.sleep(for: .seconds(2))
                if await shellExitCode("docker ps >/dev/null 2>&1") == 0 {
                    return .passed(detail: "\(runtime.displayName) — auto-started")
                }
            }
            return .failed(message: "\(runtime.displayName) not responding", fix: "Open \(runtime.appName) manually")

        case "stripe-auth":
            let hasStripe = await shellExitCode("which stripe >/dev/null 2>&1") == 0
            if !hasStripe { return .warning(message: "Not installed — Stripe will be skipped") }
            let ok = await shellExitCode("stripe config --list >/dev/null 2>&1") == 0
            return ok
                ? .passed(detail: "Authenticated")
                : .warning(message: "Not authenticated — Stripe will be skipped")

        case "yalc":
            let ok = await shellExitCode("which yalc") == 0
            return ok
                ? .passed(detail: "Found")
                : .failed(message: "Not installed", fix: "Run: npm i -g yalc")

        case "env-diff":
            let cwd = check.metadata["cwd"] ?? ""
            let examplePath = (cwd as NSString).appendingPathComponent(".env.example")
            let localPath = (cwd as NSString).appendingPathComponent(".env.local")

            guard FileManager.default.fileExists(atPath: examplePath) else {
                return .passed(detail: "No .env.example")
            }
            guard FileManager.default.fileExists(atPath: localPath) else {
                return .warning(message: "No .env.local — copy from .env.example")
            }

            let requiredKeys = extractRequiredEnvKeys(from: examplePath)
            let localKeys = extractEnvKeys(from: localPath)
            let missing = requiredKeys.subtracting(localKeys)

            if missing.isEmpty {
                return .passed(detail: "\(localKeys.count) keys configured")
            } else {
                let sorted = missing.sorted().prefix(5).joined(separator: ", ")
                let suffix = missing.count > 5 ? " (+\(missing.count - 5) more)" : ""
                return .warning(message: "Missing: \(sorted)\(suffix)")
            }

        default:
            if check.id.hasPrefix("port-") {
                let port = Int(check.id.dropFirst(5)) ?? 0
                let available = portAvailable(port)
                if available {
                    return .passed(detail: "Free")
                }
                let pidInfo = await shellOutput("lsof -ti TCP:\(port) -sTCP:LISTEN")
                let pidStr = pidInfo.trimmingCharacters(in: .whitespacesAndNewlines)
                if let pid = Int(pidStr) {
                    let procName = await shellOutput("ps -p \(pid) -o comm=")
                    let name = URL(fileURLWithPath: procName.trimmingCharacters(in: .whitespacesAndNewlines)).lastPathComponent
                    return .failed(
                        message: "Port \(port) in use by \(name.isEmpty ? "unknown" : name) (PID \(pid))",
                        fix: "kill \(pid)"
                    )
                }
                return .failed(message: "Port \(port) in use", fix: "lsof -ti :\(port) | xargs kill")
            }

            if check.id.hasPrefix("dir-") {
                let path = check.metadata["path"] ?? ""
                let exists = FileManager.default.fileExists(atPath: path)
                return exists
                    ? .passed(detail: "Found")
                    : .failed(message: "Directory not found", fix: "Check services.json paths")
            }

            return .passed(detail: "OK")
        }
    }

    private func shellExitCode(_ command: String) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: -1)
            }
        }
    }

    private func extractRequiredEnvKeys(from path: String) -> Set<String> {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var keys = Set<String>()
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if let eqIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && value.isEmpty {
                    keys.insert(key)
                }
            }
        }
        return keys
    }

    private func extractEnvKeys(from path: String) -> Set<String> {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        var keys = Set<String>()
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            if let eqIndex = trimmed.firstIndex(of: "=") {
                let key = String(trimmed[trimmed.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty { keys.insert(key) }
            }
        }
        return keys
    }

    private func shellOutput(_ command: String) async -> String {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do { try process.run() } catch { continuation.resume(returning: "") }
        }
    }

    private func portAvailable(_ port: Int) -> Bool {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
        defer { Darwin.close(sock) }

        var reuseAddr: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = UInt32(INADDR_LOOPBACK).bigEndian

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
