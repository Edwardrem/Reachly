import Darwin
import Foundation

/// Starts a tool with `posix_spawn` the way Reachly runs every outside program: in a process group of its own
/// (its pid is the group id, so one signal to `-pid` reaches it and everything it started), with only the
/// descriptors given here open, and with signals as a new process expects them, whatever the app blocks or
/// ignores. Shared by `CommandRunner` (short tools with a deadline) and `ACPProcess` (a long-lived agent).
enum ProcessSpawn {
    /// Where one of the child's standard descriptors comes from.
    enum Source {
        /// `/dev/null`, read-only for standard input and write-only for output.
        case null
        /// A descriptor of ours, duplicated onto the child's.
        case descriptor(Int32)
    }

    /// Nil when the tool could not be started (no such file, not executable, a bad working directory).
    static func spawn(
        _ executable: String,
        arguments: [String],
        environment: [String: String],
        currentDirectory: URL?,
        standardInput: Source,
        standardOutput: Source,
        standardError: Source
    ) -> pid_t? {
        var actions = posix_spawn_file_actions_t(bitPattern: 0)
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        add(standardInput, as: STDIN_FILENO, readOnly: true, to: &actions)
        add(standardOutput, as: STDOUT_FILENO, readOnly: false, to: &actions)
        add(standardError, as: STDERR_FILENO, readOnly: false, to: &actions)
        if let currentDirectory {
            guard posix_spawn_file_actions_addchdir_np(&actions, currentDirectory.path) == 0 else { return nil }
        }

        var attributes = posix_spawnattr_t(bitPattern: 0)
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        // A group of its own (0: the child's pid), only the descriptors set up above, and signals as a new
        // process expects them, whatever the app blocks or ignores.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
        posix_spawnattr_setpgroup(&attributes, 0)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        sigdelset(&allSignals, SIGKILL)
        sigdelset(&allSignals, SIGSTOP)
        posix_spawnattr_setsigdefault(&attributes, &allSignals)

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for pointer in argv { free(pointer) }
            for pointer in envp { free(pointer) }
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        return result == 0 ? pid : nil
    }

    private static func add(_ source: Source, as target: Int32, readOnly: Bool, to actions: inout posix_spawn_file_actions_t?) {
        switch source {
        case .null:
            posix_spawn_file_actions_addopen(&actions, target, "/dev/null", readOnly ? O_RDONLY : O_WRONLY, 0)
        case .descriptor(let descriptor):
            posix_spawn_file_actions_adddup2(&actions, descriptor, target)
        }
    }

    /// The exit code, or 128 + the signal for a tool a signal ended, as a shell reports it.
    static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        return signal == 0 ? (status >> 8) & 0xFF : 128 + signal
    }
}
