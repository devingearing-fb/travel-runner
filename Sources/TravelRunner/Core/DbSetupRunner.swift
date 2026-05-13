import Foundation

/// Thread-safe one-shot guard for continuation resumption.
private final class CompletionGuard: @unchecked Sendable {
    private var completed = false
    private let lock = NSLock()

    /// Attempt to claim the one-shot. Returns `true` exactly once.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if completed { return false }
        completed = true
        return true
    }
}

actor DbSetupRunner {
    private let portalCwd: String
    private let logStore: LogStore
    private var currentProcess: Process?
    private var cancelled = false

    init(portalCwd: String, logStore: LogStore) {
        self.portalCwd = portalCwd
        self.logStore = logStore
    }

    func run(pipeline: DbSetupPipeline, from startStepId: String? = nil) async {
        cancelled = false

        await MainActor.run {
            pipeline.isRunning = true
            pipeline.startedAt = .now
            pipeline.completedAt = nil
        }

        let steps = await MainActor.run { pipeline.steps }
        let startIndex: Int
        if let startId = startStepId {
            startIndex = steps.firstIndex(where: { $0.id == startId }) ?? 0
        } else {
            startIndex = 0
        }

        // Mark steps before startIndex as skipped (preserve already-passed ones)
        for i in 0..<startIndex {
            let step = steps[i]
            await MainActor.run {
                if step.status != .passed { step.status = .skipped }
            }
        }

        // If retrying from reset-database, force re-run of subsequent data steps
        if let startId = startStepId, startId == "reset-database" {
            let resetDependents: Set<String> = ["load-hotels", "copy-event-data", "verify-data"]
            for step in steps where resetDependents.contains(step.id) {
                await MainActor.run { step.status = .pending }
            }
        }

        for i in startIndex..<steps.count {
            if cancelled { break }
            let step = steps[i]
            let status = await MainActor.run { step.status }
            if status == .skipped { continue }

            let success = await executeStep(step)

            if !success && !step.isOptional {
                break
            }
        }

        await MainActor.run {
            pipeline.isRunning = false
            pipeline.completedAt = .now
        }
    }

    func cancel() {
        cancelled = true
        currentProcess?.terminate()
    }

    // MARK: - Step Execution

    func executeStepPublic(_ step: DbSetupStep) async -> Bool {
        await executeStep(step)
    }

    private func executeStep(_ step: DbSetupStep) async -> Bool {
        await MainActor.run {
            step.status = .running
            step.startedAt = .now
            step.logEntries = []
            step.errorMessage = nil
            step.recoveryGuidance = nil
            step.healthResult = nil
            step.progress = nil
            step.progressLabel = nil
        }

        let command = step.command
        let timeout = step.timeoutSeconds
        let cwd = self.portalCwd
        let logStore = self.logStore
        let stepID = step.id

        let (exitCode, timedOut) = await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, Bool), Never>) in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            let guard_ = CompletionGuard()

            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                for line in lines {
                    if line.hasPrefix("##db:") {
                        let payload = String(line.dropFirst(5))
                        Task { @MainActor in
                            Self.parseProtocolLine(payload, step: step)
                        }
                    } else {
                        let entry = LogEntry(stream: .stdout, text: line)
                        Task { @MainActor in
                            step.logEntries.append(entry)
                        }
                        Task {
                            await logStore.append(serviceID: "db-setup-\(stepID)", entry: entry)
                        }
                    }
                }
            }

            process.terminationHandler = { proc in
                pipe.fileHandleForReading.readabilityHandler = nil
                if guard_.claim() {
                    continuation.resume(returning: (proc.terminationStatus, false))
                }
            }

            self.currentProcess = process

            do {
                try process.run()
            } catch {
                continuation.resume(returning: (-1, false))
                return
            }

            // Timeout watchdog
            Task {
                try? await Task.sleep(for: .seconds(timeout))
                if guard_.claim() {
                    process.terminate()
                    continuation.resume(returning: (-1, true))
                }
            }
        }

        currentProcess = nil

        if timedOut {
            await MainActor.run {
                step.status = .timedOut
                step.completedAt = .now
                step.errorMessage = "Timed out after \(step.timeoutSeconds)s"
                step.recoveryGuidance = "The step took too long. Check if the process is stuck."
            }
            return false
        }

        if exitCode != 0 {
            let stepId = step.id
            let output = await MainActor.run { step.logEntries.map(\.text) }
            let (msg, guidance) = Self.parseError(stepId: stepId, output: output, exitCode: exitCode)
            await MainActor.run {
                step.status = .failed
                step.completedAt = .now
                if step.errorMessage == nil {
                    step.errorMessage = msg
                    step.recoveryGuidance = guidance
                }
            }
            return false
        }

        // Run health check if defined
        if let healthCmd = step.healthCheckCommand {
            await MainActor.run { step.status = .healthCheck }

            let healthOk = await runHealthCheck(healthCmd)

            if !healthOk {
                await MainActor.run {
                    step.status = .failed
                    step.completedAt = .now
                    if step.errorMessage == nil {
                        step.errorMessage = "Health check failed after successful execution"
                        step.recoveryGuidance = "The step ran but the expected result was not found. Check the output."
                    }
                }
                return false
            }
        }

        await MainActor.run {
            step.status = .passed
            step.completedAt = .now
        }
        return true
    }

    // MARK: - Protocol Line Parser

    @MainActor
    private static func parseProtocolLine(_ payload: String, step: DbSetupStep) {
        let parts = payload.split(separator: ":", maxSplits: 2).map(String.init)
        guard let type = parts.first else { return }

        switch type {
        case "status":
            let value = parts.count > 1 ? parts[1] : ""
            if value.hasPrefix("failed") {
                let message = parts.count > 2
                    ? parts[2]
                    : (value.count > 7 ? String(value.dropFirst(7)) : "Unknown error")
                step.errorMessage = message
            }

        case "progress":
            if parts.count > 1, let pct = Double(parts[1]) {
                step.progress = pct
                if parts.count > 2 {
                    step.progressLabel = parts[2]
                }
            }

        case "health":
            let result = parts.count > 1 ? parts[1] : ""
            let detail = parts.count > 2 ? parts[2] : ""
            if result == "pass" {
                step.healthResult = detail
            } else {
                step.healthResult = nil
                step.errorMessage = "Health check: \(detail)"
            }

        default:
            break
        }
    }

    // MARK: - Error Diagnostics

    private nonisolated static func parseError(
        stepId: String, output: [String], exitCode: Int32
    ) -> (message: String, guidance: String) {
        let combined = output.joined(separator: "\n").lowercased()

        switch stepId {
        case "reset-database":
            if let migLine = output.first(where: {
                $0.contains("Applying migration") && $0.lowercased().contains("error")
            }) {
                let filename = migLine.split(separator: " ")
                    .first(where: { $0.hasSuffix(".sql") })
                    .map(String.init) ?? "unknown"
                if combined.contains("violates foreign key") {
                    return ("Migration \(filename): FK constraint violation",
                            "Pull latest fb-travel-data and retry")
                }
                if combined.contains("already exists") {
                    return ("Migration \(filename): object already exists",
                            "Run npx supabase stop && npx supabase start for a clean slate")
                }
                return ("Migration \(filename) failed",
                        "Check migration file for errors. Pull latest fb-travel-data.")
            }
            if combined.contains("could not connect") {
                return ("Database connection refused",
                        "Re-run from Start Supabase step")
            }

        case "load-hotels":
            if combined.contains("no such file") {
                return ("Hotel dump file not found",
                        "Run full setup to fetch hotel data from remote")
            }

        case "copy-event-data":
            if combined.contains("urlerror") || combined.contains("connection refused") {
                return ("Cannot reach remote Supabase API",
                        "Check internet connection")
            }
            if combined.contains("401") || combined.contains("403") {
                return ("Authentication failed",
                        "Check JWT secret in .env.local")
            }

        case "start-supabase":
            if combined.contains("port") && combined.contains("already in use") {
                return ("Port already in use",
                        "Another Supabase instance may be running. Run npx supabase stop first.")
            }

        default:
            break
        }

        let lastLine = output.last(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) ?? "Unknown error"
        return ("Exit code \(exitCode): \(String(lastLine.prefix(100)))",
                "Check the full output for details")
    }

    // MARK: - Health Check

    private func runHealthCheck(_ command: String) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-l", "-c", command]
            process.currentDirectoryURL = URL(fileURLWithPath: portalCwd)
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { proc in
                continuation.resume(returning: proc.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
