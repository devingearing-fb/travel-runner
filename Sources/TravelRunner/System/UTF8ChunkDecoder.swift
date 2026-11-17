import Foundation

/// Turns the chunks of a pipe into text. A pipe can cut a character of two to four
/// bytes between two chunks. The decoder keeps those trailing bytes (three at most)
/// and puts them in front of the next chunk, so the character stays whole. Before,
/// a chunk with a cut character was not valid UTF-8 and was dropped whole.
final class UTF8ChunkDecoder: @unchecked Sendable {
    private let lock = NSLock()
    private var carry = Data()

    /// The text of `chunk`, without the bytes of a character that the next chunk ends.
    /// A byte that is not UTF-8 becomes U+FFFD; the rest of the chunk stays.
    func decode(_ chunk: Data) -> String {
        lock.lock()
        defer { lock.unlock() }
        var bytes = carry
        bytes.append(chunk)
        let cut = Self.completeLength(of: bytes)
        carry = Data(bytes[(bytes.startIndex + cut)...])
        return String(decoding: bytes[bytes.startIndex..<(bytes.startIndex + cut)], as: UTF8.self)
    }

    /// The bytes that are left at the end of the stream, as text.
    func flush() -> String {
        lock.lock()
        defer { lock.unlock() }
        let rest = carry
        carry = Data()
        return String(decoding: rest, as: UTF8.self)
    }

    /// The length of `bytes` without a last character that is not complete yet.
    static func completeLength(of bytes: Data) -> Int {
        let count = bytes.count
        guard count > 0 else { return 0 }
        // A cut character has its lead byte in the last three bytes.
        for back in 1...min(3, count) {
            let byte = bytes[bytes.startIndex + count - back]
            if byte & 0xC0 == 0x80 { continue } // a continuation byte: look further back
            let needed: Int
            switch byte {
            case 0xC0...0xDF: needed = 2
            case 0xE0...0xEF: needed = 3
            case 0xF0...0xF7: needed = 4
            default: needed = 1
            }
            return needed > back ? count - back : count
        }
        return count
    }
}
