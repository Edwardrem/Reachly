import Foundation
import Synchronization

/// Runs a command-line tool with a deadline and keeps what it prints in memory, never on disk or in a log.
/// A tool that cannot start, hangs or prints too much never blocks the caller for longer than the timeout.
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

    /// Nil when the tool could not be started.
    public static func run(
        _ executable: String,
        arguments: [String],
        timeout: TimeInterval,
        includeStandardError: Bool = false,
        environment: [String: String]? = nil,
        currentDirectory: URL? = nil,
        outputLimit: Int = 1024 * 1024
    ) async -> Output? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = includeStandardError ? pipe : FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        let run = Run(limit: outputLimit, reader: pipe.fileHandleForReading)
        let output = await withCheckedContinuation { continuation in
            run.setContinuation(continuation)
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    run.reachedEndOfOutput()
                } else {
                    run.append(chunk)
                }
            }
            process.terminationHandler = { finished in
                run.exited(status: finished.terminationStatus)
                DispatchQueue.global().asyncAfter(deadline: .now() + drainGrace) {
                    run.reachedEndOfOutput()
                }
            }
            do {
                try process.run()
            } catch {
                run.failedToStart()
                return
            }
            // Process closes its own copy of the pipe's write end once the tool is launched, so the end of
            // output arrives when the tool (and anything it left holding the pipe) is gone.
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                guard run.markTimedOutIfRunning() else { return }
                kill(pid, SIGTERM)
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if run.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        // The Process must outlive the run: it delivers the termination handler.
        withExtendedLifetime(process) {}
        return output
    }

    /// The state one run shares between the pipe reader, the termination handler and the timeout.
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

        var isRunning: Bool { state.withLock { $0.exitStatus == nil && $0.continuation != nil } }

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
                guard state.exitStatus == nil, state.continuation != nil else { return false }
                state.timedOut = true
                return true
            }
        }

        func failedToStart() {
            let continuation = state.withLock { state -> CheckedContinuation<Output?, Never>? in
                defer { state.continuation = nil }
                return state.continuation
            }
            reader.readabilityHandler = nil
            continuation?.resume(returning: nil)
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
