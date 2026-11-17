import Foundation

/// The child processes of a process, read from the process table of the system.
enum ProcessTree {
    /// Every process below `root`, nearest first. It does not contain `root`.
    static func descendants(of root: pid_t) -> [pid_t] {
        descendants(of: root, parents: parentTable())
    }

    /// The same walk over a given table of pid to parent pid.
    static func descendants(of root: pid_t, parents: [pid_t: pid_t]) -> [pid_t] {
        var children: [pid_t: [pid_t]] = [:]
        for (pid, parent) in parents where pid != parent {
            children[parent, default: []].append(pid)
        }
        var result: [pid_t] = []
        var seen: Set<pid_t> = [root]
        var queue = [root]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for child in (children[current] ?? []).sorted() where seen.insert(child).inserted {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    /// `root` and every process below it, children first. Read the tree before the
    /// first signal: a child of a dead parent moves to launchd.
    static func tree(of root: pid_t) -> [pid_t] {
        descendants(of: root) + [root]
    }

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    /// Sends SIGTERM, then SIGKILL to what is still alive after `grace`. It returns
    /// when the processes are gone, so the caller can start them again. A cancelled
    /// task does not cut the wait short: a stop must finish.
    static func terminate(_ pids: [pid_t], grace: Duration = .seconds(2)) async {
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        if await waitUntilGone(pids, timeout: grace) { return }
        for pid in pids where isAlive(pid) { kill(pid, SIGKILL) }
        _ = await waitUntilGone(pids, timeout: .seconds(1))
    }

    /// `terminate` for a caller that cannot wait on a task: the app as it quits.
    static func terminateNow(_ pids: [pid_t], grace: Duration = .seconds(1)) {
        guard !pids.isEmpty else { return }
        for pid in pids { kill(pid, SIGTERM) }
        let deadline = ContinuousClock.now + grace
        while pids.contains(where: isAlive), ContinuousClock.now < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        for pid in pids where isAlive(pid) { kill(pid, SIGKILL) }
    }

    private static func waitUntilGone(_ pids: [pid_t], timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            if !pids.contains(where: isAlive) { return true }
            if ContinuousClock.now >= deadline { return false }
            await pause(milliseconds: 50)
        }
    }

    private static func pause(milliseconds: Int) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(milliseconds)) {
                continuation.resume()
            }
        }
    }

    /// The parent of each process. Empty when the system does not give the table.
    private static func parentTable() -> [pid_t: pid_t] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&name, UInt32(name.count), nil, &size, nil, 0) == 0 else { return [:] }
        // New processes can start between the two calls.
        let capacity = size / MemoryLayout<kinfo_proc>.stride + 32
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        size = capacity * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&name, UInt32(name.count), &processes, &size, nil, 0) == 0 else { return [:] }
        var table: [pid_t: pid_t] = [:]
        for process in processes.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            table[process.kp_proc.p_pid] = process.kp_eproc.e_ppid
        }
        return table
    }
}
