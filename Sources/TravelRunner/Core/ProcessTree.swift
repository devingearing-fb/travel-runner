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

    static func isAlive(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
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
