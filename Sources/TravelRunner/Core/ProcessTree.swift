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

    /// The wait between SIGTERM and SIGKILL of a stop.
    static let defaultGrace: Duration = .seconds(2)

    /// Sends SIGTERM, then SIGKILL to what is still alive after `grace`. It returns
    /// when the processes are gone, so the caller can start them again. A cancelled
    /// task does not cut the wait short: a stop must finish.
    static func terminate(_ pids: [pid_t], grace: Duration = defaultGrace) async {
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

    /// The parents of `pid`, nearest first, up to launchd.
    static func ancestors(of pid: pid_t) -> [pid_t] {
        ancestors(of: pid, parents: parentTable())
    }

    /// The same walk over a given table of pid to parent pid.
    static func ancestors(of pid: pid_t, parents: [pid_t: pid_t]) -> [pid_t] {
        var result: [pid_t] = []
        var seen: Set<pid_t> = [pid]
        var current = pid
        while let parent = parents[current], parent > 0, seen.insert(parent).inserted {
            result.append(parent)
            current = parent
        }
        return result
    }

    /// What the system says about one process. Nil when it has no such process,
    /// or does not show it to this user.
    static func facts(of pid: pid_t) -> ProcessFacts? {
        guard let startTime = startTime(of: pid) else { return nil }
        return ProcessFacts(pid: pid, startTime: startTime, cwd: cwd(of: pid), arguments: arguments(of: pid))
    }

    /// The processes of this user whose working directory is `folder`.
    static func processes(in folder: String) -> [ProcessFacts] {
        let count = proc_listpids(UInt32(PROC_UID_ONLY), UInt32(getuid()), nil, 0)
        guard count > 0 else { return [] }
        // New processes can start between the two calls.
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.stride + 32)
        let bytes = proc_listpids(
            UInt32(PROC_UID_ONLY), UInt32(getuid()), &pids, Int32(pids.count * MemoryLayout<pid_t>.stride)
        )
        guard bytes > 0 else { return [] }
        let folder = PortOwner.realPath(folder)
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.stride)
            .filter { $0 > 0 && cwd(of: $0) == folder }
            .compactMap { facts(of: $0) }
    }

    /// The start of the process in microseconds since 1970.
    private static func startTime(of pid: pid_t) -> Int64? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0, size > 0,
              info.kp_proc.p_pid == pid else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec)
    }

    private static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
        return path.isEmpty ? nil : path
    }

    /// The arguments of the process, from `KERN_PROCARGS2`. A process can change
    /// them (`next-server` does). Empty when the system does not give them.
    private static func arguments(of pid: pid_t) -> [String] {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        return parseArguments(Array(buffer.prefix(size)))
    }

    /// Reads a `KERN_PROCARGS2` buffer: the argument count, the path of the
    /// executable, padding, then the arguments, each ended by a zero byte.
    static func parseArguments(_ buffer: [UInt8]) -> [String] {
        guard buffer.count > 4 else { return [] }
        let argc = buffer.prefix(4).withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var index = 4
        // The executable path, then the zero bytes after it.
        while index < buffer.count, buffer[index] != 0 { index += 1 }
        while index < buffer.count, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < buffer.count {
            let start = index
            while index < buffer.count, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
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
