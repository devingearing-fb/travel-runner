import Foundation

actor ProcessRunner {
    private var processes: [String: Process] = [:]
    private var pids: [String: pid_t] = [:]

    func start(
        service: ServiceDefinition,
        onStdout: @escaping @Sendable ([String]) -> Void,
        onStderr: @escaping @Sendable ([String]) -> Void,
        onTermination: @escaping @Sendable (Int32) -> Void
    ) throws -> Int32 {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        if let cwd = service.resolvedCwd {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", service.cmd.joined(separator: " ")]

        var env = ProcessInfo.processInfo.environment
        if let overrides = service.env {
            for (key, value) in overrides {
                env[key] = value
            }
        }
        process.environment = env
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading
        let stdoutBuffer = TerminalLineBuffer()
        let stderrBuffer = TerminalLineBuffer()

        stdoutHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = stdoutBuffer.feed(text)
            guard !lines.isEmpty else { return }
            onStdout(lines)
        }

        stderrHandle.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = stderrBuffer.feed(text)
            guard !lines.isEmpty else { return }
            onStderr(lines)
        }

        process.terminationHandler = { proc in
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            if let remaining = stdoutBuffer.flush() { onStdout([remaining]) }
            if let remaining = stderrBuffer.flush() { onStderr([remaining]) }
            onTermination(proc.terminationStatus)
        }

        try process.run()
        let pid = process.processIdentifier

        processes[service.id] = process
        pids[service.id] = pid
        return pid
    }

    func stop(serviceID: String) async {
        guard let pid = pids[serviceID] else {
            processes.removeValue(forKey: serviceID)
            return
        }

        // Collect the full descendant tree BEFORE sending any signals.
        // Once the parent receives SIGTERM and dies, its children are
        // reparented to launchd (PID 1) and pgrep -P can't find them.
        let descendants = collectAllDescendants(of: pid)
        let allPids = descendants + [pid]

        for p in allPids {
            kill(p, SIGTERM)
        }

        try? await Task.sleep(for: .seconds(2))

        for p in allPids {
            kill(p, SIGKILL)
        }

        processes.removeValue(forKey: serviceID)
        pids.removeValue(forKey: serviceID)
    }

    func stopAll() async {
        var allPids: [pid_t] = []
        for (_, pid) in pids {
            allPids.append(contentsOf: collectAllDescendants(of: pid))
            allPids.append(pid)
        }

        for p in allPids {
            kill(p, SIGTERM)
        }

        try? await Task.sleep(for: .seconds(2))

        for p in allPids {
            kill(p, SIGKILL)
        }

        processes.removeAll()
        pids.removeAll()
    }

    private func collectAllDescendants(of rootPid: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var queue: [pid_t] = [rootPid]

        while !queue.isEmpty {
            let current = queue.removeFirst()
            let children = directChildren(of: current)
            result.append(contentsOf: children)
            queue.append(contentsOf: children)
        }

        return result
    }

    private func directChildren(of pid: pid_t) -> [pid_t] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(separator: "\n").compactMap {
                pid_t($0.trimmingCharacters(in: .whitespaces))
            }
        } catch {
            return []
        }
    }

    func isRunning(serviceID: String) -> Bool {
        processes[serviceID]?.isRunning ?? false
    }
}
