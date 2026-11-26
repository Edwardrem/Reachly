import Darwin
import Foundation
import Synchronization

/// How an ACP agent ended: its exit status and the end of what it wrote to standard error.
public struct ACPExit: Sendable, Equatable {
    /// The exit code, or 128 + the signal, as a shell reports it. Nil when the transport cannot tell.
    public var status: Int32?
    /// The last lines the agent logged, for the failure row.
    public var standardError: String
    /// Reachly stopped it (Stop that went unanswered, the panel closing, another provider chosen).
    public var wasStopped: Bool

    public init(status: Int32?, standardError: String = "", wasStopped: Bool = false) {
        self.status = status
        self.standardError = standardError
        self.wasStopped = wasStopped
    }
}

/// What a transport delivers, in the order it happened.
public enum ACPTransportEvent: Sendable {
    /// One message line, without its newline.
    case message(Data)
    /// The agent is gone; nothing more will come.
    case closed(ACPExit)
}

/// The byte pipe under an `ACPConnection`: the agent's standard input and output, or a stand-in for tests.
public protocol ACPTransport: AnyObject, Sendable {
    /// Every message line and then `.closed`, once.
    var events: AsyncStream<ACPTransportEvent> { get }
    /// Writes one framed message (it ends in `\n`). Writes go out in the order they were made.
    func send(_ framed: Data)
    /// Stops the agent. `.closed` follows.
    func close()
    /// The reader is done with one `.message` of this many bytes, so the transport can read more. A transport
    /// that buffers without a limit needs nothing here.
    func didHandle(byteCount: Int)
}

extension ACPTransport {
    public func didHandle(byteCount: Int) {}
}

/// An ACP agent running as a child process: JSON-RPC on its standard input and output, its standard error kept
/// in a capped buffer for the error row.
///
/// It starts with `ProcessSpawn`, in a process group of its own, so stopping it takes the whole group: the agent
/// and every helper it started, such as the MCP bridges it runs for its session. Stopping closes its standard
/// input (a well-behaved agent exits on that), sends SIGTERM to the group, and SIGKILL after a grace period.
/// The pid is waited on without being reaped first, so a signal to the group can never reach a reused pid.
public final class ACPProcess: ACPTransport {
    public struct LaunchError: LocalizedError, Equatable {
        public var executable: String
        public var errorDescription: String? { "\(executable) couldn't be started." }
    }

    /// The most of standard error kept, from its end.
    public static let standardErrorLimit = 16 * 1024
    /// After SIGTERM, how long the group has before SIGKILL.
    public static let terminationGrace: TimeInterval = 2

    /// How much the agent may have written that the reader has not handled yet. Past it, the agent's output is
    /// not read until the reader catches up, so its writes wait in the pipe: one that floods Reachly with
    /// updates slows down instead of growing Reachly's memory. A single message may be larger than `bytes`
    /// (up to the framer's 32 MB): it goes through on its own.
    public struct BacklogLimit: Sendable {
        public var messages: Int
        public var bytes: Int

        public init(messages: Int, bytes: Int) {
            self.messages = messages
            self.bytes = bytes
        }

        public static let standard = BacklogLimit(messages: 1024, bytes: 8 << 20)
    }

    public let events: AsyncStream<ACPTransportEvent>
    public let pid: pid_t

    private struct State {
        var standardError = Data()
        var exitStatus: Int32?
        var reachedEndOfOutput = false
        var reachedEndOfErrors = false
        var closedEventSent = false
        var stopRequested = false
        var stdinOpen = true
    }

    private let state = Mutex(State())

    private struct Backlog {
        var messages = 0
        var bytes = 0
        /// The most messages ever waiting at once, for tests.
        var highWater = 0
    }

    private let backlogLimit: BacklogLimit
    private let backlog = Mutex(Backlog())
    /// Signalled when the reader handles a message; the output thread waits on it while the backlog is full. A
    /// reader that goes away closes the transport (`ACPConnection` does so when it is let go), which ends the wait.
    private let roomMade = DispatchSemaphore(value: 0)
    private let continuation: AsyncStream<ACPTransportEvent>.Continuation
    private let stdinDescriptor: Int32
    private let writer = DispatchQueue(label: "io.github.edwardrem.reachly.acp.stdin")

    /// Starts `executable` with `arguments` in `currentDirectory`. Throws when it cannot be started.
    public init(executable: String, arguments: [String], environment: [String: String], currentDirectory: URL?, backlogLimit: BacklogLimit = .standard) throws {
        self.backlogLimit = backlogLimit
        func makePipe() -> (read: Int32, write: Int32)? {
            var ends: [Int32] = [-1, -1]
            guard pipe(&ends) == 0 else { return nil }
            // No end may leak into a tool another thread starts meanwhile; the child gets its copies by dup2.
            _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
            return (ends[0], ends[1])
        }
        guard let input = makePipe() else { throw LaunchError(executable: executable) }
        guard let output = makePipe() else {
            Darwin.close(input.read); Darwin.close(input.write)
            throw LaunchError(executable: executable)
        }
        guard let errors = makePipe() else {
            Darwin.close(input.read); Darwin.close(input.write); Darwin.close(output.read); Darwin.close(output.write)
            throw LaunchError(executable: executable)
        }
        let spawned = ProcessSpawn.spawn(
            executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory,
            standardInput: .descriptor(input.read),
            standardOutput: .descriptor(output.write),
            standardError: .descriptor(errors.write))
        // The child has its copies; the parent's must close, or the end of output never comes.
        Darwin.close(input.read)
        Darwin.close(output.write)
        Darwin.close(errors.write)
        guard let spawned else {
            Darwin.close(input.write); Darwin.close(output.read); Darwin.close(errors.read)
            throw LaunchError(executable: executable)
        }
        pid = spawned
        stdinDescriptor = input.write
        // A write after the agent has gone must fail with EPIPE, not raise SIGPIPE in the app.
        _ = fcntl(input.write, F_SETNOSIGPIPE, 1)
        // Unbounded here, because dropping a message would break JSON-RPC; `backlogLimit` bounds it instead.
        (events, continuation) = AsyncStream.makeStream(of: ACPTransportEvent.self, bufferingPolicy: .unbounded)

        let outputDescriptor = output.read
        let errorDescriptor = errors.read
        Thread.detachNewThread { [self] in readOutput(outputDescriptor) }
        Thread.detachNewThread { [self] in readStandardError(errorDescriptor) }
        Thread.detachNewThread { [self] in reap() }
    }

    deinit {
        // Only reached once every reader thread has finished, so the agent has exited and was reaped.
        closeStandardInput()
    }

    public func send(_ framed: Data) {
        writer.async { [self] in
            guard state.withLock({ $0.stdinOpen }) else { return }
            framed.withUnsafeBytes { buffer in
                guard var pointer = buffer.baseAddress else { return }
                var remaining = buffer.count
                while remaining > 0 {
                    let written = write(stdinDescriptor, pointer, remaining)
                    if written < 0 {
                        if errno == EINTR { continue }
                        // EPIPE: the agent is gone; the reaper reports it.
                        return
                    }
                    remaining -= written
                    pointer += written
                }
            }
        }
    }

    public func didHandle(byteCount: Int) {
        backlog.withLock { backlog in
            backlog.messages = max(0, backlog.messages - 1)
            backlog.bytes = max(0, backlog.bytes - byteCount)
        }
        roomMade.signal()
    }

    /// The most messages that were ever waiting for the reader at once.
    public var backlogHighWater: Int { backlog.withLock { $0.highWater } }

    public func close() {
        let first = state.withLock { state -> Bool in
            defer { state.stopRequested = true }
            return !state.stopRequested && state.exitStatus == nil
        }
        guard first else { return }
        // Queued after any pending write, so a last `session/cancel` still goes out first.
        writer.async { [self] in closeStandardInput() }
        if signalGroup(SIGTERM) {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.terminationGrace) { [self] in
                _ = signalGroup(SIGKILL)
            }
        }
    }

    /// The end of standard error so far, as text.
    public var standardErrorTail: String {
        let data = state.withLock { $0.standardError }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Threads

    private func readOutput(_ descriptor: Int32) {
        var framer = ACPLineFramer()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            for line in framer.append(Data(chunk[0..<count])) {
                deliver(line)
            }
        }
        if let last = framer.finish() { deliver(last) }
        Darwin.close(descriptor)
        state.withLock { $0.reachedEndOfOutput = true }
        if !finishIfDone() {
            // Output usually ends because the agent is exiting. One still running a moment later closed its
            // output and can no longer answer, so it is stopped.
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                if state.withLock({ $0.exitStatus == nil }) { close() }
            }
        }
    }

    /// Hands one message to the reader, first waiting while the backlog is full, unless the agent is being
    /// stopped.
    private func deliver(_ line: Data) {
        while true {
            let full = backlog.withLock { backlog in
                backlog.messages > 0
                    && (backlog.messages >= backlogLimit.messages || backlog.bytes + line.count > backlogLimit.bytes)
            }
            if !full || state.withLock({ $0.stopRequested }) { break }
            _ = roomMade.wait(timeout: .now() + .milliseconds(100))
        }
        backlog.withLock { backlog in
            backlog.messages += 1
            backlog.bytes += line.count
            backlog.highWater = max(backlog.highWater, backlog.messages)
        }
        continuation.yield(.message(line))
    }

    private func readStandardError(_ descriptor: Int32) {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            state.withLock { state in
                state.standardError.append(contentsOf: chunk[0..<count])
                if state.standardError.count > Self.standardErrorLimit {
                    state.standardError = Data(state.standardError.suffix(Self.standardErrorLimit))
                }
            }
        }
        Darwin.close(descriptor)
        state.withLock { $0.reachedEndOfErrors = true }
        finishIfDone()
    }

    private func reap() {
        // Wait for the exit without reaping: while the agent is a zombie its pid, and so its group id, cannot be
        // reused, so the group kill below reaches only what it left behind, such as an MCP bridge it started.
        var info = siginfo_t()
        var waited: Int32
        repeat { waited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while waited == -1 && errno == EINTR
        if waited == 0 { kill(-pid, SIGKILL) }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
        let code = result == pid ? ProcessSpawn.exitCode(status) : -1
        state.withLock { $0.exitStatus = code }
        if !finishIfDone() {
            // A helper that inherited the output can keep it open; give the last lines a moment, then end.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [self] in sendClosed() }
        }
    }

    /// Reports the end once the agent has exited and both of its outputs have been read to the end, so the
    /// last messages and the last lines it logged are in. False while one of them is still open.
    @discardableResult
    private func finishIfDone() -> Bool {
        let done = state.withLock { $0.exitStatus != nil && $0.reachedEndOfOutput && $0.reachedEndOfErrors }
        if done { sendClosed() }
        return done
    }

    private func sendClosed() {
        let exit = state.withLock { state -> ACPExit? in
            guard !state.closedEventSent, let status = state.exitStatus else { return nil }
            state.closedEventSent = true
            return ACPExit(status: status, standardError: String(decoding: state.standardError, as: UTF8.self), wasStopped: state.stopRequested)
        }
        guard let exit else { return }
        writer.async { [self] in closeStandardInput() }
        continuation.yield(.closed(exit))
        continuation.finish()
    }

    /// Runs on the writer queue (or in deinit), so it never races a write.
    private func closeStandardInput() {
        let open = state.withLock { state -> Bool in
            defer { state.stdinOpen = false }
            return state.stdinOpen
        }
        if open { Darwin.close(stdinDescriptor) }
    }

    /// Signals the agent's group while its pid still belongs to it. False once it has been reaped.
    private func signalGroup(_ signal: Int32) -> Bool {
        state.withLock { state in
            guard state.exitStatus == nil else { return false }
            kill(-pid, signal)
            return true
        }
    }
}
