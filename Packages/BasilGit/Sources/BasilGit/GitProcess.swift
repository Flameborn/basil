import Darwin
import Foundation
import Synchronization

/// Runs the git command-line tool. Calls block; callers run them off the cooperative pool
/// (`GitService` does, on its own dispatch queue).
///
/// posix_spawn and waitpid, not Process: Process.waitUntilExit depends on run-loop delivery and
/// hung for 7zz on the threads such calls run on. Only descriptors 0, 1 and 2 reach git.
/// Nothing secret ever goes on argv: logins go through GIT_ASKPASS (see `GitAskPass`).
struct GitProcess: Sendable {
    let executable: URL

    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: String
        var succeeded: Bool { status == 0 }
        var text: String { String(decoding: stdout, as: UTF8.self) }
        /// git's own message, for errors: "fatal: ..." without the prefix, or the whole of stderr.
        var message: String {
            let lines = stderr.split(whereSeparator: \.isNewline).map { String($0) }
            let fatal = lines.filter { $0.hasPrefix("fatal: ") || $0.hasPrefix("error: ") }
                .map { String($0.drop { $0 != " " }.dropFirst()) }
            var text = (fatal.isEmpty ? lines : fatal).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            // Some refusals ("nothing to commit") come on stdout.
            if text.isEmpty { text = self.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            return text.isEmpty ? "git ended with status \(status)" : text
        }
    }

    /// The environment every run gets: never a terminal prompt (git would wait for input that
    /// never comes), plain English messages, no pager, no colours, no optional locks (status
    /// must not take index.lock while the user runs git in a terminal).
    static func environment(extra: [String: String]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_PAGER"] = "cat"
        env["PAGER"] = "cat"
        env["LC_ALL"] = "C.UTF-8"
        env["TERM"] = "dumb"
        // Never an editor: messages come from Basil (commit -F -), merges keep git's message.
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        for (key, value) in extra { env[key] = value }
        return env
    }

    /// Runs git to the end. `input` is written to its standard input (a commit message), which
    /// is closed afterwards.
    /// `started` gets git's process ID (to stop it when the caller is cancelled).
    func run(_ arguments: [String], in directory: URL?, input: Data? = nil,
             environment extra: [String: String] = [:], started: (pid_t) -> Void = { _ in }) throws -> Output {
        var inPipe: [Int32] = [0, 0], outPipe: [Int32] = [0, 0], errPipe: [Int32] = [0, 0]
        guard pipe(&inPipe) == 0 else { throw POSIXError(.EMFILE) }
        guard pipe(&outPipe) == 0 else { close(inPipe[0]); close(inPipe[1]); throw POSIXError(.EMFILE) }
        guard pipe(&errPipe) == 0 else {
            [inPipe[0], inPipe[1], outPipe[0], outPipe[1]].forEach { close($0) }
            throw POSIXError(.EMFILE)
        }
        for fd in inPipe + outPipe + errPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)
        if let directory { posix_spawn_file_actions_addchdir(&actions, directory.path) }
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new session: no controlling terminal, so ssh can never open /dev/tty to ask.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID))

        let argv = [executable.path] + arguments
        let env = Self.environment(extra: extra).map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStrings(argv) { cArgv in
            withCStrings(env) { cEnv in posix_spawn(&pid, executable.path, &actions, &attributes, cArgv, cEnv) }
        }
        close(inPipe[0]); close(outPipe[1]); close(errPipe[1])
        guard result == 0 else {
            close(inPipe[1]); close(outPipe[0]); close(errPipe[0])
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .ENOENT)
        }
        _ = fcntl(inPipe[1], F_SETNOSIGPIPE, 1)
        started(pid)
        // stdin, stdout and stderr each on a thread of its own, so a full pipe never blocks git
        // (or Basil). Threads, not GCD work items: see SevenZipTool.thread.
        let writer = Drain()
        let inputFD = inPipe[1]
        Self.thread {
            if let input {
                input.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let n = Darwin.write(inputFD, raw.baseAddress! + offset, raw.count - offset)
                        if n < 0, errno == EINTR { continue }
                        if n <= 0 { break }
                        offset += n
                    }
                }
            }
            close(inputFD)
            writer.finish(Data())
        }
        let errors = Drain.reading(errPipe[0])
        let output = Drain.reading(outPipe[0])
        let stdout = output.wait()
        let stderr = errors.wait()
        _ = writer.wait()
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
        let signal = raw & 0x7f
        let status = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
        return Output(status: status, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))
    }

    private func withCStrings<T>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> T) -> T {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }

    static func thread(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Bytes collected on another thread.
    final class Drain: Sendable {
        private let state = Mutex<Data?>(nil)
        private let done = DispatchSemaphore(value: 0)

        func finish(_ data: Data) {
            state.withLock { $0 = data }
            done.signal()
        }

        func wait() -> Data {
            done.wait()
            return state.withLock { $0 ?? Data() }
        }

        static func reading(_ fd: Int32) -> Drain {
            let drain = Drain()
            GitProcess.thread {
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 1 << 16)
                while true {
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { break }
                    data.append(contentsOf: buffer[0..<n])
                }
                close(fd)
                drain.finish(data)
            }
            return drain
        }
    }
}
