import Foundation

/// Splits the bytes an ACP agent writes to standard output into messages, and frames the ones Reachly sends.
///
/// ACP's stdio transport carries one JSON-RPC message per line: UTF-8, delimited by `\n`, and a message must
/// not contain a newline itself (agentclientprotocol.com, Transports › stdio). Output arrives in chunks of any
/// size, so a message may span several chunks and a chunk may end inside a message. A line longer than
/// `maximumLineLength` is dropped up to its newline instead of growing the buffer without end. A trailing `\r`
/// is dropped and blank lines are skipped.
public struct ACPLineFramer: Sendable {
    public static let maximumLineLength = 32 * 1024 * 1024

    private var buffer = Data()
    /// Inside a line that grew past the limit: everything up to its newline is thrown away.
    private var discarding = false
    private let limit: Int
    /// Lines dropped for being too long.
    public private(set) var droppedLines = 0

    public init(maximumLineLength: Int = ACPLineFramer.maximumLineLength) {
        limit = maximumLineLength
    }

    /// Takes the next chunk and returns the complete lines it finished, in order.
    public mutating func append(_ chunk: Data) -> [Data] {
        var lines: [Data] = []
        var start = chunk.startIndex
        while start < chunk.endIndex, let newline = chunk[start...].firstIndex(of: 0x0A) {
            if discarding {
                discarding = false
            } else if buffer.count + (newline - start) > limit {
                droppedLines += 1
            } else {
                buffer.append(chunk[start..<newline])
                if let line = Self.cleaned(buffer) { lines.append(line) }
            }
            buffer = Data()
            start = chunk.index(after: newline)
        }
        if start < chunk.endIndex, !discarding {
            if buffer.count + (chunk.endIndex - start) > limit {
                buffer = Data()
                discarding = true
                droppedLines += 1
            } else {
                buffer.append(chunk[start...])
            }
        }
        return lines
    }

    /// The stream ended: a last message that had no newline after it, if any.
    public mutating func finish() -> Data? {
        defer {
            buffer = Data()
            discarding = false
        }
        guard !discarding else { return nil }
        return Self.cleaned(buffer)
    }

    private static func cleaned(_ line: Data) -> Data? {
        var line = line
        if line.last == 0x0D { line.removeLast() }
        guard line.contains(where: { $0 != 0x20 && $0 != 0x09 }) else { return nil }
        return Data(line)
    }

    /// One message as it goes on the wire: compact JSON, which escapes every newline inside a string, and the
    /// delimiting `\n`.
    public static func frame(_ message: JSONValue) -> Data {
        var data = message.data()
        data.append(0x0A)
        return data
    }
}
