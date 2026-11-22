import BasilCore
import Darwin
import Foundation
import Synchronization

/// Runs the bundled 7zz command-line tool. Calls block; callers run them off the cooperative pool.
///
/// Passwords never go on the command line, where other processes can read them: 7zz asks with
/// "Enter password:" and reads one line from standard input, so the password (if any) is written
/// into a pipe. Without one, standard input is closed and 7zz stops instead of waiting.
struct SevenZipTool: Sendable {
    let executable: URL

    /// Options every run gets: UTF-8 console and list files, errors on stderr. Messages go to
    /// stdout only where asked (-bso1): with -so, stdout carries the file data.
    static let common = ["-sccUTF-8", "-scsUTF-8", "-bse2"]

    /// The environment: UTF-8 names, and times in UTC (7zz prints times in the local zone).
    static let environment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["LC_ALL"] = "en_US.UTF-8"
        env["TZ"] = "UTC"
        return env
    }()

    struct Output: Sendable {
        var status: Int32
        var stdout: Data
        var stderr: String
        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
        /// 7zz asked for a password (and got none, or stopped at a wrong one).
        var askedForPassword: Bool { stdoutText.contains("Enter password") || stderr.contains("Enter password") }
        /// The "ERROR: ..." lines of stderr without the prefix, or the whole of stderr.
        var errors: [String] {
            let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            let errors = lines.filter { $0.hasPrefix("ERROR: ") }.map { String($0.dropFirst(7)) }
            if !errors.isEmpty { return errors }
            return lines.filter { !$0.isEmpty && !$0.hasPrefix("System ERROR") }
        }
    }

    /// Runs 7zz to the end and collects its output.
    func run(_ arguments: [String], password: String? = nil) throws -> Output {
        let process = try start(arguments, password: password)
        let stderr = process.drainStderr()
        var stdout = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(process.stdout, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            stdout.append(contentsOf: buffer[0..<n])
        }
        let status = process.wait()
        return Output(status: status, stdout: stdout, stderr: stderr.wait())
    }

    /// Starts 7zz with stdout and stderr on pipes. The caller reads them and waits for the end.
    /// posix_spawn and waitpid, not Process: Process.waitUntilExit depends on run-loop delivery
    /// and hung on the threads these calls run on.
    func start(_ arguments: [String], password: String? = nil) throws -> Running {
        var input: [Int32] = [0, 0], output: [Int32] = [0, 0], errors: [Int32] = [0, 0]
        guard pipe(&input) == 0 else { throw POSIXError(.EMFILE) }
        guard pipe(&output) == 0 else { close(input[0]); close(input[1]); throw POSIXError(.EMFILE) }
        guard pipe(&errors) == 0 else {
            [input[0], input[1], output[0], output[1]].forEach { close($0) }
            throw POSIXError(.EMFILE)
        }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, input[0], 0)
        posix_spawn_file_actions_adddup2(&actions, output[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errors[1], 2)
        // Only 0, 1 and 2 reach 7zz: no other descriptor of Basil leaks into it.
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = [executable.path] + Self.common + arguments
        let env = Self.environment.map { "\($0.key)=\($0.value)" }
        var pid: pid_t = 0
        let result = withCStrings(argv) { cArgv in
            withCStrings(env) { cEnv in
                posix_spawn(&pid, executable.path, &actions, &attributes, cArgv, cEnv)
            }
        }
        close(input[0]); close(output[1]); close(errors[1])
        guard result == 0 else {
            close(input[1]); close(output[0]); close(errors[0])
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .ENOENT)
        }
        // A 7zz that already ended must not take Basil down with SIGPIPE.
        _ = fcntl(input[1], F_SETNOSIGPIPE, 1)
        if let password {
            // A short write into an empty pipe does not block, so this never waits on 7zz.
            let line = Array((password + "\n").utf8)
            _ = line.withUnsafeBytes { Darwin.write(input[1], $0.baseAddress, $0.count) }
        }
        close(input[1])
        return Running(pid: pid, stdout: output[0], stderr: errors[0])
    }

    private func withCStrings<T>(_ strings: [String], _ body: ([UnsafeMutablePointer<CChar>?]) -> T) -> T {
        let pointers = strings.map { strdup($0) } + [nil]
        defer { pointers.forEach { free($0) } }
        return body(pointers)
    }

    /// A started 7zz. `stdout` is the read end of its standard output.
    final class Running: Sendable {
        let pid: pid_t
        let stdout: Int32
        private let stderrFD: Int32
        /// The exit status once reaped, and whether stdout was closed.
        private let state = Mutex<(status: Int32?, stdoutClosed: Bool, stderrTaken: Bool)>((nil, false, false))

        init(pid: pid_t, stdout: Int32, stderr: Int32) {
            self.pid = pid
            self.stdout = stdout
            self.stderrFD = stderr
        }

        deinit {
            stop()
            if !state.withLock({ $0.stderrTaken }) { close(stderrFD) }
        }

        /// Reads stderr on another thread so a chatty 7zz never blocks on a full pipe.
        func drainStderr() -> Collected {
            let collected = Collected()
            let fd = stderrFD
            state.withLock { $0.stderrTaken = true }
            DispatchQueue.global(qos: .utility).async {
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
                    if n < 0, errno == EINTR { continue }
                    if n <= 0 { break }
                    data.append(contentsOf: buffer[0..<n])
                }
                close(fd)
                collected.finish(String(decoding: data, as: UTF8.self))
            }
            return collected
        }

        /// Waits for 7zz to end and returns its exit status (128 + signal when it was killed).
        @discardableResult
        func wait() -> Int32 {
            if let status = state.withLock({ $0.status }) { return status }
            var raw: Int32 = 0
            while waitpid(pid, &raw, 0) < 0, errno == EINTR {}
            let signal = raw & 0x7f
            let status = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
            state.withLock { $0.status = status }
            return status
        }

        /// Stops 7zz (it may be blocked writing to a pipe nobody reads any more) and reaps it.
        func stop() {
            let (status, closed) = state.withLock { s in
                defer { s.stdoutClosed = true }
                return (s.status, s.stdoutClosed)
            }
            if !closed { close(stdout) }
            guard status == nil else { return }
            kill(pid, SIGTERM)
            wait()
        }
    }

    /// Text that arrives on another thread.
    final class Collected: Sendable {
        private let state = Mutex<String?>(nil)
        private let done = DispatchSemaphore(value: 0)

        func finish(_ text: String) {
            state.withLock { $0 = text }
            done.signal()
        }

        func wait() -> String {
            done.wait()
            done.signal() // later waits return at once
            return state.withLock { $0 ?? "" }
        }
    }
}

/// Parses `7zz l -slt -ba` output: one block of "Key = Value" lines per entry, blank line between.
enum SevenZipListing {
    static func entries(_ text: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var fields: [String: String] = [:]
        func flush() {
            if let entry = entry(fields, ordinal: entries.count) { entries.append(entry) }
            fields = [:]
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.isEmpty {
                if !fields.isEmpty { flush() }
                continue
            }
            guard let range = line.range(of: " = ") ?? (line.hasSuffix(" =") ? line.range(of: " =", options: .backwards) : nil)
            else { continue }
            let key = String(line[..<range.lowerBound])
            if key == "Path", !fields.isEmpty { flush() }
            fields[key] = String(line[range.upperBound...])
        }
        if !fields.isEmpty { flush() }
        return entries
    }

    static func entry(_ fields: [String: String], ordinal: Int) -> ArchiveEntry? {
        guard let stored = fields["Path"], !stored.isEmpty else { return nil }
        let attributes = fields["Attributes"] ?? ""
        let parts = attributes.split(separator: " ")
        let flags = parts.first.map(String.init) ?? ""
        let mode = parts.count > 1 ? mode(String(parts[1])) : nil
        var kind: ArchiveEntry.Kind = .file
        if fields["Folder"] == "+" || flags.contains("D") || mode?.type == 0o040000 {
            kind = .directory
        } else if let type = mode?.type {
            kind = switch type {
            case 0o100000: .file
            case 0o120000: .symlink
            default: .other
            }
        }
        let size = fields["Size"].flatMap { Int64($0) }
        return ArchiveEntry(path: VFSPath.local(stored).path, kind: kind,
                            size: kind == .file || kind == .symlink ? (size ?? 0) : nil,
                            modified: fields["Modified"].flatMap(date),
                            permissions: mode?.permissions,
                            isEncrypted: fields["Encrypted"] == "+",
                            ordinal: ordinal, storedName: stored,
                            crc32: fields["CRC"].flatMap { UInt32($0, radix: 16) })
    }

    /// "drwxr-xr-x" or "-rwsr-x--T" -> file type bits and permission bits.
    static func mode(_ text: String) -> (type: UInt32, permissions: UInt16)? {
        let c = Array(text.utf8)
        guard c.count == 10 else { return nil }
        let type: UInt32 = switch c[0] {
        case UInt8(ascii: "d"): 0o040000
        case UInt8(ascii: "l"): 0o120000
        case UInt8(ascii: "-"): 0o100000
        case UInt8(ascii: "c"): 0o020000
        case UInt8(ascii: "b"): 0o060000
        case UInt8(ascii: "p"): 0o010000
        case UInt8(ascii: "s"): 0o140000
        default: 0
        }
        guard type != 0 else { return nil }
        var bits: UInt16 = 0
        let letters: [UInt8] = Array("rwxrwxrwx".utf8)
        for i in 0..<9 {
            let ch = c[i + 1]
            let execute = i % 3 == 2
            if ch == letters[i] || (execute && (ch == UInt8(ascii: "s") || ch == UInt8(ascii: "t"))) {
                bits |= 1 << (8 - i)
            }
        }
        if c[3] == UInt8(ascii: "s") || c[3] == UInt8(ascii: "S") { bits |= 0o4000 }
        if c[6] == UInt8(ascii: "s") || c[6] == UInt8(ascii: "S") { bits |= 0o2000 }
        if c[9] == UInt8(ascii: "t") || c[9] == UInt8(ascii: "T") { bits |= 0o1000 }
        return (type, bits)
    }

    /// "2026-11-22 11:18:39.7712877" in UTC (the tool runs with TZ=UTC).
    static func date(_ text: String) -> timespec? {
        let pieces = text.split(separator: " ")
        guard pieces.count == 2 else { return nil }
        let day = pieces[0].split(separator: "-").compactMap { Int32($0) }
        let timeAndFraction = pieces[1].split(separator: ".", maxSplits: 1)
        let time = timeAndFraction[0].split(separator: ":").compactMap { Int32($0) }
        guard day.count == 3, time.count == 3 else { return nil }
        var t = tm()
        t.tm_year = day[0] - 1900
        t.tm_mon = day[1] - 1
        t.tm_mday = day[2]
        t.tm_hour = time[0]
        t.tm_min = time[1]
        t.tm_sec = time[2]
        let seconds = timegm(&t)
        var nanos = 0
        if timeAndFraction.count == 2 {
            let digits = String(timeAndFraction[1].prefix(9))
            nanos = (Int(digits) ?? 0) * Int(pow(10, Double(9 - digits.count)))
        }
        return timespec(tv_sec: seconds, tv_nsec: nanos)
    }
}
