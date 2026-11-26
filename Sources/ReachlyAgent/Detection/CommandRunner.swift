import Darwin
import Foundation
import Synchronization

/// Runs a command-line tool with a deadline and keeps what it prints in memory, never on disk or in a log.
/// A tool that cannot start, hangs or prints too much never blocks the caller for longer than the timeout.
///
/// The tool starts in a process group of its own, with only standard input (`/dev/null`), output and error
/// open, so a timeout stops it and every helper it started, and nothing of the app's leaks into it.
public enum CommandRunner {
    public struct Output: Sendable {
        public var exitStatus: Int32
        /// Standard output, plus standard error when it was asked for. At most the run's `outputLimit` bytes.
        public var data: Data
        public var timedOut: Bool
        public var truncated: Bool

        public var succeeded: Bool { !timedOut && exitStatus == 0 }
    }

    /// After the tool exits, how long to wait for the end of its output. A background child that inherited the
    /// pipe keeps it open; the run then ends with what was read.
    static let drainGrace: TimeInterval = 0.5

    /// Nil when the tool could not be started. `environment` nil passes the app's own environment.
    public static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval,
        includeStandardError: Bool = false,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        outputLimit: Int = 1024 * 1024
    ) async -> Output? {
        var pipeEnds: [Int32] = [-1, -1]
        guard pipe(&pipeEnds) == 0 else { return nil }
        let (readEnd, writeEnd) = (pipeEnds[0], pipeEnds[1])
        // Neither end may leak into a tool another thread starts meanwhile; the child gets its copy by dup2.
        _ = fcntl(readEnd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writeEnd, F_SETFD, FD_CLOEXEC)

        let pid = spawn(
            executable, arguments: arguments,
            environment: environment ?? ProcessInfo.processInfo.environment,
            currentDirectory: currentDirectory,
            output: writeEnd, includeStandardError: includeStandardError)
        // The parent's copy of the write end must close, or the end of output never comes.
        close(writeEnd)
        guard let pid else {
            close(readEnd)
            return nil
        }

        let reader = FileHandle(fileDescriptor: readEnd, closeOnDealloc: true)
        let run = Run(limit: outputLimit, reader: reader)
        return await withCheckedContinuation { continuation in
            run.setContinuation(continuation)
            reader.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    run.reachedEndOfOutput()
                } else {
                    run.append(chunk)
                }
            }
            // Reaps the tool on a thread of its own; `waitid` and `waitpid` block until it exits.
            Thread.detachNewThread {
                // Wait for the exit without reaping: while the tool is a zombie its pid, and so its group id,
                // cannot be reused, so a group kill after a timeout reaches only what the tool left behind,
                // such as a helper that ignored SIGTERM.
                var info = siginfo_t()
                var waited: Int32
                repeat { waited = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while waited == -1 && errno == EINTR
                if waited == 0, run.hasTimedOut { kill(-pid, SIGKILL) }
                var status: Int32 = 0
                var result: pid_t
                repeat { result = waitpid(pid, &status, 0) } while result == -1 && errno == EINTR
                run.exited(status: result == pid ? Self.exitCode(status) : -1)
                DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace) {
                    run.reachedEndOfOutput()
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard run.markTimedOutIfRunning() else { return }
                // The tool leads its own group, so a negative pid reaches it and everything it started.
                kill(-pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if run.isRunning { kill(-pid, SIGKILL) }
                }
            }
        }
    }

    /// Starts the tool in a new process group (its pid is the group id) with stdin on `/dev/null`, stdout on
    /// `output`, stderr on `output` or `/dev/null`, every other descriptor closed and default signal handling.
    private static func spawn(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        output: Int32,
        includeStandardError: Bool
    ) -> pid_t? {
        ProcessSpawn.spawn(
            executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory,
            standardInput: .null,
            standardOutput: .descriptor(output),
            standardError: includeStandardError ? .descriptor(output) : .null)
    }

    /// The exit code, or 128 + the signal for a tool a signal ended, as a shell reports it.
    private static func exitCode(_ status: Int32) -> Int32 {
        ProcessSpawn.exitCode(status)
    }

    /// The state one run shares between the pipe reader, the reaper and the timeout.
    private final class Run: Sendable {
        private struct State {
            var data = Data()
            var truncated = false
            var timedOut = false
            var exitStatus: Int32?
            var reachedEnd = false
            var continuation: CheckedContinuation<Output?, Never>?
        }

        private let state = Mutex(State())
        private let limit: Int
        private let reader: FileHandle

        init(limit: Int, reader: FileHandle) {
            self.limit = limit
            self.reader = reader
        }

        /// The tool has not been reaped yet, so its pid and group still belong to it.
        var isRunning: Bool { state.withLock { $0.exitStatus == nil } }

        var hasTimedOut: Bool { state.withLock { $0.timedOut } }

        func setContinuation(_ continuation: CheckedContinuation<Output?, Never>) {
            state.withLock { $0.continuation = continuation }
        }

        func append(_ chunk: Data) {
            state.withLock { state in
                let room = limit - state.data.count
                if chunk.count > room {
                    state.data.append(chunk.prefix(max(room, 0)))
                    state.truncated = true
                } else {
                    state.data.append(chunk)
                }
            }
        }

        func exited(status: Int32) {
            let finished = state.withLock { state -> (CheckedContinuation<Output?, Never>, Output)? in
                state.exitStatus = status
                return Self.take(&state)
            }
            resume(finished)
        }

        func reachedEndOfOutput() {
            let finished = state.withLock { state -> (CheckedContinuation<Output?, Never>, Output)? in
                state.reachedEnd = true
                return Self.take(&state)
            }
            resume(finished)
        }

        /// True when the tool was still running, so the caller should stop it.
        func markTimedOutIfRunning() -> Bool {
            state.withLock { state in
                guard state.exitStatus == nil else { return false }
                state.timedOut = true
                return true
            }
        }

        /// Hands the output over once the tool has exited and its output ended. The buffer moves out, so the
        /// caller holds the only copy.
        private static func take(_ state: inout State) -> (CheckedContinuation<Output?, Never>, Output)? {
            guard let status = state.exitStatus, state.reachedEnd, let continuation = state.continuation else { return nil }
            state.continuation = nil
            let output = Output(exitStatus: status, data: state.data, timedOut: state.timedOut, truncated: state.truncated)
            state.data = Data()
            return (continuation, output)
        }

        private func resume(_ finished: (CheckedContinuation<Output?, Never>, Output)?) {
            guard let (continuation, output) = finished else { return }
            reader.readabilityHandler = nil
            continuation.resume(returning: output)
        }
    }
}
