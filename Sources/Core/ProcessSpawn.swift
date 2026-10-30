import Foundation

// posix_spawn with the three things Foundation.Process cannot do: the child leads its OWN PROCESS GROUP (so cancelling means `killpg`, which reaches every
// grandchild at once, even one spawned a microsecond ago that a `ps` scan would miss), every other descriptor is closed in the child (POSIX_SPAWN_CLOEXEC_DEFAULT:
// a tool never inherits the app's files or sockets), and all signals start at their defaults (an app that ignores SIGPIPE does not hand that to ffmpeg).

enum ProcessSpawn {
    struct Spawned: Sendable {
        var pid: pid_t
    }

    /// Starts `executable` with stdin from /dev/null and stdout / stderr on the given descriptors. The child's pid is also its process group id.
    static func spawn(_ executable: URL, _ arguments: [String], environment: [String: String], workingDirectory: URL?, stdout: Int32, stderr: Int32,
                      background: Bool) throws -> Spawned {
        var attr: posix_spawnattr_t? = nil
        guard posix_spawnattr_init(&attr) == 0 else { throw SpawnError.errno(ENOMEM) }
        defer { posix_spawnattr_destroy(&attr) }
        var fileActions: posix_spawn_file_actions_t? = nil
        guard posix_spawn_file_actions_init(&fileActions) == 0 else { throw SpawnError.errno(ENOMEM) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }

        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attr, Int16(truncatingIfNeeded: flags))
        posix_spawnattr_setpgroup(&attr, 0)
        var all = sigset_t(); sigfillset(&all)
        posix_spawnattr_setsigdefault(&attr, &all)
        var none = sigset_t(); sigemptyset(&none)
        posix_spawnattr_setsigmask(&attr, &none)
        if background { posix_spawnattr_set_qos_class_np(&attr, QOS_CLASS_UTILITY) }

        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fileActions, stdout, 1)
        posix_spawn_file_actions_adddup2(&fileActions, stderr, 2)
        if let wd = workingDirectory { posix_spawn_file_actions_addchdir(&fileActions, wd.path) }

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { for p in argv { free(p) }; for p in envp { free(p) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &fileActions, &attr, &argv, &envp)
        guard rc == 0 else { throw SpawnError.errno(rc) }
        return Spawned(pid: pid)
    }

    enum SpawnError: Error {
        case errno(Int32)
        var reason: String {
            switch self { case .errno(let e): return String(cString: strerror(e)) }
        }
    }

    /// Blocks a background thread until `pid` has exited and been REAPED (no zombie is ever left behind), then calls `done` with the Foundation-style status:
    /// the exit code, or the signal number when the child was killed by a signal.
    static func reap(_ pid: pid_t, done: @escaping @Sendable (Int32) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            var r: pid_t
            repeat { r = waitpid(pid, &status, 0) } while r == -1 && errno == EINTR
            if r == -1 { done(-1); return }
            // WIFEXITED / WIFSIGNALED are macros: decode by hand (the low 7 bits are the signal, 0 = a normal exit).
            let sig = status & 0x7f
            done(sig == 0 ? (status >> 8) & 0xff : sig)
        }
    }
}
