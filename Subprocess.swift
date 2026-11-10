import Foundation
import Darwin

/// Runs command-line tools safely:
/// - in their own session (no controlling terminal), so password prompts read stdin and never hang on a terminal,
/// - secrets go through stdin, never the command line where other processes could see them,
/// - stdout can be captured straight into memory (nothing written to disk),
/// - cancelling the Swift task kills the tool.
enum Subprocess {
    struct Result {
        let ok: Bool
        let stdout: Data
        /// Last few KB of stderr
        let stderr: String
    }

    private final class PID: @unchecked Sendable {
        var value: pid_t = 0
        var cancelled = false
        let lock = NSLock()
    }

    static func locate(_ tool: String) -> String? {
        let fm = FileManager.default
        if tool.hasPrefix("/") { return fm.isExecutableFile(atPath: tool) ? tool : nil }
        return ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            .map { $0 + "/" + tool }
            .first { fm.isExecutableFile(atPath: $0) }
    }

    static func run(_ exe: String, _ args: [String], input: String? = nil, captureStdout: Bool = false,
                    onStderrLine: (@Sendable (String) -> Void)? = nil) async -> Result {
        let pid = PID()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                runBlocking(exe, args, input: input, captureStdout: captureStdout, onStderrLine: onStderrLine, pid: pid)
            }.value
        } onCancel: {
            pid.lock.lock(); defer { pid.lock.unlock() }
            pid.cancelled = true
            if pid.value > 0 { kill(pid.value, SIGKILL) }
        }
    }

    /// onStderrLine gets each complete stderr line as it arrives (on the calling thread);
    /// environment entries are added to the inherited environment.
    static func runBlocking(_ exe: String, _ args: [String], input: String? = nil, captureStdout: Bool = false,
                            environment: [String: String] = [:], onStderrLine: ((String) -> Void)? = nil) -> Result {
        runBlocking(exe, args, input: input, captureStdout: captureStdout, environment: environment,
                    onStderrLine: onStderrLine, pid: PID())
    }

    private static func runBlocking(_ exe: String, _ args: [String], input: String?, captureStdout: Bool,
                                    environment: [String: String] = [:], onStderrLine: ((String) -> Void)? = nil,
                                    pid box: PID) -> Result {
        let failed = Result(ok: false, stdout: Data(), stderr: "")
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0 else { return failed }
        guard pipe(&outPipe) == 0 else { close(inPipe[0]); close(inPipe[1]); return failed }
        guard pipe(&errPipe) == 0 else {
            [inPipe[0], inPipe[1], outPipe[0], outPipe[1]].forEach { close($0) }
            return failed
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        if captureStdout {
            posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        } else {
            posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        var attrs: posix_spawnattr_t?
        posix_spawnattr_init(&attrs)
        // CLOEXEC_DEFAULT closes every other descriptor in the child
        posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attrs)
        }

        let argv = ([exe] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var env = ProcessInfo.processInfo.environment
        env.merge(environment) { $1 }
        let envp = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { envp.forEach { free($0) } }
        var child: pid_t = 0
        box.lock.lock()
        let spawned = box.cancelled ? ECANCELED : posix_spawn(&child, exe, &actions, &attrs, argv, envp)
        if spawned == 0 { box.value = child }
        box.lock.unlock()
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard spawned == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            return failed
        }

        // A password is one short line, well under the pipe buffer, so this never blocks
        if let input {
            let line = Array((input + "\n").utf8)
            _ = line.withUnsafeBytes { write(inPipe[1], $0.baseAddress, $0.count) }
        }
        close(inPipe[1])

        // Drain stdout and stderr together so neither pipe fills up and stalls the tool
        var out = Data(), err = Data(), pendingLine = Data()
        var fds = [pollfd(fd: outPipe[0], events: Int16(POLLIN), revents: 0),
                   pollfd(fd: errPipe[0], events: Int16(POLLIN), revents: 0)]
        var buffer = [UInt8](repeating: 0, count: 65536)
        var open = 2
        while open > 0 {
            if poll(&fds, 2, -1) < 0 {
                if errno == EINTR { continue }
                break
            }
            for i in 0..<2 where fds[i].fd >= 0 && fds[i].revents != 0 {
                let n = read(fds[i].fd, &buffer, buffer.count)
                if n > 0 {
                    if i == 0 {
                        out.append(buffer, count: n)
                    } else {
                        err.append(buffer, count: n)
                        if err.count > 16384 { err = err.suffix(8192) }
                        if let onStderrLine {
                            pendingLine.append(buffer, count: n)
                            while let newline = pendingLine.firstIndex(of: UInt8(ascii: "\n")) {
                                onStderrLine(String(decoding: pendingLine[pendingLine.startIndex..<newline], as: UTF8.self))
                                pendingLine = Data(pendingLine[(newline + 1)...])
                            }
                        }
                    }
                } else {
                    close(fds[i].fd)
                    fds[i].fd = -1
                    open -= 1
                }
            }
        }

        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        let ok = (status & 0x7f) == 0 && (status >> 8) & 0xff == 0
        return Result(ok: ok, stdout: out, stderr: String(decoding: err, as: UTF8.self))
    }
}
