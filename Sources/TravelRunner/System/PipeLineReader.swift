import Foundation

/// Reads one pipe of a process into lines, in order. One lock covers every read
/// and the end, so no chunk comes after the last line.
///
/// Foundation can run the termination handler of a process before the
/// readability handler has read the last data. So when the process ends, the
/// reader reads what is left in the pipe itself, and the last lines (the stack
/// trace of a crash, a `##db:status:failed` line) are never lost.
final class PipeLineReader: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let decoder = UTF8ChunkDecoder()
    private let lines = TerminalLineBuffer()
    private let onData: @Sendable () -> Void
    private let onLines: @Sendable ([String]) -> Void
    private let onClose: @Sendable () -> Void
    private var finished = false
    /// Set while a stop of the process tree runs. The grace does not end the
    /// reader then: the owner of the stop calls `finish()` when the tree is gone.
    private var held = false

    /// How long the reader waits for a child process that keeps the pipe open
    /// after the process has ended.
    static let pipeGrace: DispatchTimeInterval = .seconds(1)

    /// - Parameters:
    ///   - onData: called for each chunk read, before its lines.
    ///   - onLines: the complete lines, in order.
    ///   - onClose: called once, after the last line.
    init(
        handle: FileHandle,
        onData: @escaping @Sendable () -> Void = {},
        onLines: @escaping @Sendable ([String]) -> Void,
        onClose: @escaping @Sendable () -> Void = {}
    ) {
        self.handle = handle
        self.onData = onData
        self.onLines = onLines
        self.onClose = onClose
        // A read of an empty pipe returns at once, so the end of the process can
        // read the rest without a wait.
        let fd = handle.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        handle.readabilityHandler = { [weak self] _ in self?.readAvailable() }
    }

    func readAvailable() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if drain() { close() }
    }

    /// The process ended. Reads the rest of the pipe, and ends at the end of the
    /// pipe, or after a short grace.
    func processEnded() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        if drain() {
            close()
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.pipeGrace) { [self] in
            lock.lock()
            defer { lock.unlock() }
            guard !finished, !held else { return }
            _ = drain()
            close()
        }
    }

    /// A stop of the process tree begins. The reader stays open until `finish()`.
    func hold() {
        lock.lock()
        held = true
        lock.unlock()
    }

    /// Reads what is left and ends now.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return }
        _ = drain()
        close()
    }

    /// Reads until the pipe is empty. True at the end of the pipe.
    private func drain() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let fd = handle.fileDescriptor
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count > 0 {
                onData()
                emit(decoder.decode(Data(buffer[0..<count])))
            } else if count == 0 {
                return true
            } else if errno != EINTR {
                return false
            }
        }
    }

    private func emit(_ text: String) {
        let complete = lines.feed(text)
        if !complete.isEmpty { onLines(complete) }
    }

    private func close() {
        finished = true
        handle.readabilityHandler = nil
        emit(decoder.flush())
        if let rest = lines.flush() { onLines([rest]) }
        onClose()
    }
}
