import Darwin
import Foundation
import Synchronization

/// Runs one command line from the pane's command line (TC style) through the chosen shell
/// (the login shell unless Settings names another, such as fish), in a folder, without a terminal: standard input is /dev/null, standard output and
/// error arrive merged, cleaned of terminal escape codes (`TerminalText.clean`).
///
/// posix_spawn in a new session (no controlling terminal; the shell's process group is its
/// own, so Stop reaches everything it started). Pipe reading and waiting happen on threads of
/// their own (see SevenZipTool.thread); the callbacks run on the main actor.
public final class ShellCommand: Sendable {
    public let command: String
    public let folder: URL
    /// The shell's path: `<shell> -l -c <command>` (zsh, bash, fish and nu all take these).
    public let shell: String
    private let state = Mutex<State>(State())

    private struct State {
        var pid: pid_t = 0
        var exited = false
        var stopping = false
    }

    public enum Outcome: Sendable, Equatable {
        case exited(Int32)
        /// Stopped by `stop()` or a signal.
        case stopped
    }

    /// `shell` is a path; nil or empty is the login shell.
    public init(_ command: String, in folder: URL, shell: String? = nil) {
        self.command = command
        self.folder = folder
        let chosen = shell?.trimmingCharacters(in: .whitespaces) ?? ""
        self.shell = chosen.isEmpty ? Self.loginShell : (chosen as NSString).expandingTildeInPath
    }

    /// Shells to offer in Settings: those in /etc/shells plus Homebrew's and MacPorts' (fish is
    /// usually installed there and often not listed), each once, existing and executable.
    public static func installedShells(shellsFile: String = "/etc/shells") -> [String] {
        let listed = ((try? String(contentsOfFile: shellsFile, encoding: .utf8)) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("/") }
        let names = ["fish", "zsh", "bash", "nu", "elvish", "xonsh"]
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"].flatMap { dir in names.map { "\(dir)/\($0)" } }
        var seen = Set<String>()
        return (listed + extra).filter { path in
            access(path, X_OK) == 0 && seen.insert(path).inserted
        }
    }

    /// The user's login shell (from the user database), else zsh.
    public static var loginShell: String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, access(path, X_OK) == 0 { return path }
        }
        return "/bin/zsh"
    }

    /// The environment of the run: Basil's own, plus no pager, no colours, a dumb terminal.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "dumb"
        env["PAGER"] = "cat"
        env["GIT_PAGER"] = "cat"
        env["NO_COLOR"] = "1"
        env["CLICOLOR"] = nil
        env["CLICOLOR_FORCE"] = nil
        env["PWD"] = nil
        return env
    }

    /// Starts the command. `output` gets cleaned text as it arrives (whole lines, except at the
    /// end or when a line grows long); `finished` is called once the shell has exited.
    public func start(output: @escaping @MainActor @Sendable (String) -> Void,
                      finished: @escaping @MainActor @Sendable (Outcome) -> Void) throws {
        var outPipe: [Int32] = [0, 0]
        guard pipe(&outPipe) == 0 else { throw POSIXError(.EMFILE) }
        for fd in outPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let devNull = open("/dev/null", O_RDONLY | O_CLOEXEC)
        defer { if devNull >= 0 { close(devNull) } }

        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if devNull >= 0 { posix_spawn_file_actions_adddup2(&actions, devNull, 0) }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 2)
        posix_spawn_file_actions_addchdir(&actions, folder.path)
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSID))

        let shell = self.shell
        let argv = [shell, "-l", "-c", command]
        var env = Self.environment()
        env["PWD"] = folder.path
        let envp = env.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = Self.withCStrings(argv) { cArgv in
            Self.withCStrings(envp) { cEnv in posix_spawn(&pid, shell, &actions, &attributes, cArgv, cEnv) }
        }
        close(outPipe[1])
        guard result == 0 else {
            close(outPipe[0])
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .ENOENT)
        }
        state.withLock { $0.pid = pid }
        let child = pid

        let readFD = outPipe[0]
        let readerDone = DispatchSemaphore(value: 0)
        Self.thread {
            var pending = Data()
            var buffer = [UInt8](repeating: 0, count: 1 << 16)
            func deliver(_ data: Data) {
                let text = TerminalText.clean(String(decoding: data, as: UTF8.self))
                guard !text.isEmpty else { return }
                Task { @MainActor in output(text) }
            }
            while true {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                pending.append(contentsOf: buffer[0..<n])
                // Whole lines, so a character split between reads is never cut; long lines anyway.
                if let last = pending.lastIndex(of: UInt8(ascii: "\n")) {
                    deliver(pending[...last])
                    pending = Data(pending[(last + 1)...])
                } else if pending.count > 4096 {
                    deliver(pending)
                    pending = Data()
                }
            }
            if !pending.isEmpty { deliver(pending) }
            close(readFD)
            readerDone.signal()
        }
        Self.thread { [self] in
            var raw: Int32 = 0
            while waitpid(child, &raw, 0) < 0, errno == EINTR {}
            let stopping = self.state.withLock { s -> Bool in
                s.exited = true
                return s.stopping
            }
            // The rest of the output first; a program the shell left running in the background
            // may keep the pipe open, so not for long.
            _ = readerDone.wait(timeout: .now() + 1)
            let signal = raw & 0x7f
            let outcome: Outcome = signal != 0 || stopping ? .stopped : .exited((raw >> 8) & 0xff)
            Task { @MainActor in finished(outcome) }
        }
    }

    /// Stops the command and everything it started: SIGTERM to its process group, SIGKILL
    /// after two seconds if it is still there.
    public func stop() {
        let pid = state.withLock { s -> pid_t in
            guard !s.exited, s.pid > 0 else { return 0 }
            s.stopping = true
            return s.pid
        }
        guard pid > 0 else { return }
        killpg(pid, SIGTERM)
        Self.thread { [self] in
            Thread.sleep(forTimeInterval: 2)
            if !self.state.withLock({ $0.exited }) { killpg(pid, SIGKILL) }
        }
    }

    public var isRunning: Bool { state.withLock { $0.pid > 0 && !$0.exited } }

    private static func withCStrings<T>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> T) -> T {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }

    static func thread(_ body: @escaping @Sendable () -> Void) {
        let thread = Thread(block: body)
        thread.qualityOfService = .userInitiated
        thread.start()
    }
}

/// Turns terminal output into plain text a screen reader can read: escape sequences (colours,
/// cursor moves, window titles) removed, a carriage return starts the line over (progress
/// lines keep only their last state), backspaces delete, other control characters go.
/// `ShellCommand` hands it whole lines, so a sequence is never split between two calls.
public enum TerminalText {
    public static func clean(_ text: String) -> String {
        var out = ""
        var line = ""
        var scalars = text.unicodeScalars[...]
        while let c = scalars.popFirst() {
            switch c {
            case "\u{1B}":
                // CSI: ESC [ parameters, intermediates, final byte. OSC: ESC ] ... BEL or ESC \.
                // Anything else: ESC and one more character.
                guard let next = scalars.first else { break }
                scalars.removeFirst()
                if next == "[" {
                    while let p = scalars.first, (0x20...0x3F).contains(p.value) { scalars.removeFirst() }
                    if let f = scalars.first, (0x40...0x7E).contains(f.value) { scalars.removeFirst() }
                } else if next == "]" {
                    while let p = scalars.popFirst() {
                        if p == "\u{07}" { break }
                        if p == "\u{1B}", scalars.first == "\\" { scalars.removeFirst(); break }
                    }
                }
            case "\r":
                if scalars.first == "\n" { continue }
                line = ""
            case "\n":
                out += line + "\n"
                line = ""
            case "\u{08}":
                if !line.isEmpty { line.removeLast() }
            case "\t":
                line.unicodeScalars.append(c)
            default:
                if c.value < 0x20 || c.value == 0x7F { continue }
                line.unicodeScalars.append(c)
            }
        }
        return out + line
    }
}
