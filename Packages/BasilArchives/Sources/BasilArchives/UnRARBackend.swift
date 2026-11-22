import BasilCore
import CUnRAR
import Darwin
import Foundation
import Synchronization

/// Reads RAR archives (RAR 1.5 to 7, solid, multi-volume, encrypted data and names) through the
/// official UnRAR library built from `Vendor/unrar` (decision 2026-11-22). Basil only reads
/// RAR: creating and changing RAR archives is not possible with UnRAR.
///
/// Listing uses RAR_OM_LIST, which reports a file split over volumes once. Data comes from a
/// producer thread per session that tests entries (RAR_TEST) and writes their data into a pipe
/// in archive order, so reading forward through a solid archive decompresses it once. The last
/// piece of each file is held back until UnRAR has checked the file's CRC32 or BLAKE2 hash, so
/// a damaged file (or one decrypted with a wrong password) never reaches its last byte.
public struct UnRARBackend: ArchiveBackend {
    public var name: String { "UnRAR" }

    public init() {}

    public func recognizes(name: String) -> Bool {
        ArchiveNames.suffixes(of: name).contains("rar")
    }

    /// The first volume of a multi-volume set, when `url` is a later one that has it next to
    /// it: "name.part3.rar" -> "name.part1.rar" (same number of digits), "name.r00" -> "name.rar".
    /// Opening a later volume then shows the whole set, like Total Commander.
    static func firstVolume(of url: URL) -> URL {
        let name = url.lastPathComponent
        let folder = url.deletingLastPathComponent()
        var candidates: [String] = []
        if let m = name.wholeMatch(of: /(?i)(.*\.part)(\d+)(\.rar)/), let n = Int(m.2), n > 1 {
            candidates.append(String(m.1) + String(repeating: "0", count: m.2.count - 1) + "1" + String(m.3))
        } else if let m = name.wholeMatch(of: /(.*)\.[r-zR-Z]\d\d/) {
            candidates += [String(m.1) + ".rar", String(m.1) + ".RAR"]
        }
        for candidate in candidates {
            let first = folder.appendingPathComponent(candidate)
            if FileManager.default.fileExists(atPath: first.path) { return first }
        }
        return url
    }

    public func entries(of url: URL, byContent: Bool, password: String?) throws -> [ArchiveEntry]? {
        let url = Self.firstVolume(of: url)
        let archive: RarHandle
        do {
            archive = try RarHandle(url: url, mode: RAR_OM_LIST, password: password)
        } catch RarHandle.OpenFailure.notRar {
            return nil
        }
        var entries: [ArchiveEntry] = []
        var ordinalByPath: [String: Int] = [:]
        var rar4Links: [Int] = []
        while let header = try archive.nextHeader() {
            var entry = header.entry(ordinal: entries.count)
            switch header.redirect {
            case .hardLink(let target), .fileCopy(let target):
                if let source = ordinalByPath[VFSPath.local("/" + target).path], entries[source].kind == .file {
                    entry.dataOrdinal = entries[source].dataOrdinal
                    entry.size = entries[source].size
                }
            case .symlink(nil):
                rar4Links.append(entry.ordinal)
            default:
                break
            }
            ordinalByPath[entry.path] = entry.ordinal
            entries.append(entry)
            try archive.skip()
        }
        if !rar4Links.isEmpty { try readRAR4LinkTargets(&entries, links: rar4Links, url: url, password: password) }
        return entries
    }

    /// RAR 4 stores a Unix symlink's target as its packed data, which UnRAR hands out only by
    /// creating the link. So the links are extracted into a scratch folder and read back. A
    /// link UnRAR refuses to create (an absolute target, or one leaving the archive) or one
    /// that is encrypted without a password is listed as an item that cannot be copied.
    private func readRAR4LinkTargets(_ entries: inout [ArchiveEntry], links: [Int], url: URL, password: String?) throws {
        let wanted = Set(links.filter { password != nil || !entries[$0].isEncrypted })
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("basil-rar-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        if !wanted.isEmpty, let last = wanted.max() {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let archive = try RarHandle(url: url, mode: RAR_OM_EXTRACT, password: password)
            var ordinal = 0
            while ordinal <= last, let header = try archive.nextHeader() {
                if header.splitBefore {
                    try archive.skip()
                    continue
                }
                if wanted.contains(ordinal) {
                    let code = archive.process(RAR_EXTRACT, into: scratch.path)
                    let linkPath = scratch.path + entries[ordinal].path
                    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                    let n = readlink(linkPath, &buffer, buffer.count - 1)
                    if code == ERAR_SUCCESS, n >= 0 {
                        entries[ordinal].symlinkTarget = String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                    }
                } else {
                    try archive.skip()
                }
                ordinal += 1
            }
        }
        for i in links where entries[i].symlinkTarget == nil {
            entries[i].kind = .other
            entries[i].size = nil
        }
    }

    public func session(for url: URL, byContent: Bool, entries: [ArchiveEntry], password: String?) -> any ArchiveReadSession {
        UnRARSession(url: Self.firstVolume(of: url), entries: entries, password: password)
    }

    /// RAR 5 stores a password check value, so a wrong password fails before any data is
    /// unpacked. RAR 4 has none: the first encrypted file is unpacked and its CRC decides.
    public func checkPassword(_ password: String, url: URL, byContent: Bool, entries: [ArchiveEntry]) throws -> Bool {
        guard let target = entries.first(where: { $0.isEncrypted && $0.kind == .file && $0.dataOrdinal == $0.ordinal && ($0.size ?? 0) > 0 })?.ordinal else {
            return true
        }
        let url = Self.firstVolume(of: url)
        let archive: RarHandle
        do {
            archive = try RarHandle(url: url, mode: RAR_OM_EXTRACT, password: password)
        } catch ArchiveError.wrongPassword {
            return false
        }
        var ordinal = 0
        while let header = try archive.nextHeader() {
            if header.splitBefore {
                try archive.skip()
                continue
            }
            if ordinal == target {
                archive.callbacks.sink = { _ in true }
                let code = archive.process(RAR_TEST)
                archive.callbacks.sink = nil
                if code == ERAR_SUCCESS { return true }
                if code == ERAR_BAD_PASSWORD || code == ERAR_BAD_DATA { return false }
                throw archive.error(code, entry: entries[target])
            }
            try archive.skip()
            ordinal += 1
        }
        throw ArchiveError.damaged("The archive can no longer be read", archive: url.lastPathComponent)
    }

    public func test(_ url: URL, byContent: Bool, password: String?, progress: (Double, String) -> Bool) throws -> [String] {
        guard let entries = try entries(of: url, byContent: byContent, password: password) else {
            throw ArchiveError.damaged("Not a RAR archive", archive: url.lastPathComponent)
        }
        let url = Self.firstVolume(of: url)
        let total = max(1, entries.reduce(Int64(0)) { $0 + (UnRARSession.hasData($1) ? $1.size ?? 0 : 0) })
        var done: Int64 = 0
        var problems: [String] = []
        let archive = try RarHandle(url: url, mode: RAR_OM_EXTRACT, password: password)
        var cancelled = false
        try withoutActuallyEscaping(progress) { progress in
            var ordinal = 0
            while let header = try archive.nextHeader() {
                if header.splitBefore {
                    try archive.skip()
                    continue
                }
                defer { ordinal += 1 }
                guard entries.indices.contains(ordinal), entries[ordinal].kind == .file else {
                    try archive.skip()
                    continue
                }
                let entry = entries[ordinal]
                let name = String(entry.path.dropFirst())
                guard progress(min(1, Double(done) / Double(total)), name) else { throw CancellationError() }
                if entry.isEncrypted, password == nil {
                    problems.append("\(name): encrypted, not tested")
                    do {
                        try archive.skip()
                    } catch {
                        // A solid archive cannot skip encrypted data without its password, so
                        // nothing after this entry can be tested either.
                        for later in entries[(ordinal + 1)...] where later.kind == .file {
                            problems.append("\(later.path.dropFirst()): \(later.isEncrypted ? "encrypted, " : "")not tested")
                        }
                        break
                    }
                    continue
                }
                archive.callbacks.sink = { chunk in
                    done += Int64(chunk.count)
                    if !progress(min(1, Double(done) / Double(total)), name) { cancelled = true }
                    return !cancelled
                }
                let code = archive.process(RAR_TEST)
                archive.callbacks.sink = nil
                if cancelled { throw CancellationError() }
                guard code != ERAR_SUCCESS else { continue }
                let error = archive.error(code, entry: entry)
                switch code {
                case ERAR_BAD_DATA, ERAR_BAD_PASSWORD, ERAR_MISSING_PASSWORD, ERAR_UNKNOWN_FORMAT, ERAR_EREFERENCE:
                    problems.append(RarHandle.problem(error, entry: name))
                default:
                    throw error // a missing volume, no memory, an unreadable archive: nothing after it can be tested
                }
            }
        }
        _ = progress(1, "")
        return problems
    }
}

/// One open archive handle of the UnRAR library. Opened and used on one thread: the library's
/// error state is per thread (Vendor/unrar BasilErrors.cpp), cleared before each call.
final class RarHandle {
    enum OpenFailure: Error { case notRar }

    enum Redirect: Equatable {
        case none
        /// A symlink; nil target for a RAR 4 Unix link, whose target is its data.
        case symlink(String?)
        case hardLink(String)
        case fileCopy(String)
    }

    struct Header {
        var path: String
        var isDirectory: Bool
        var size: Int64
        var modified: timespec?
        var permissions: UInt16?
        var isEncrypted: Bool
        var splitBefore: Bool
        var redirect: Redirect

        func entry(ordinal: Int) -> ArchiveEntry {
            let kind: ArchiveEntry.Kind = switch redirect {
            case .symlink: .symlink
            case _ where isDirectory: .directory
            default: .file
            }
            var target: String?
            if case .symlink(let name) = redirect { target = name }
            return ArchiveEntry(path: VFSPath.local("/" + path).path, kind: kind, size: kind == .file ? size : nil,
                                modified: modified, permissions: permissions, symlinkTarget: target,
                                isEncrypted: isEncrypted, ordinal: ordinal)
        }
    }

    let url: URL
    let callbacks: RarCallbacks
    private let handle: UnsafeMutableRawPointer
    private let header: UnsafeMutablePointer<RARHeaderDataEx>
    private static let nameCapacity = 32768
    private let nameBuffer: UnsafeMutablePointer<wchar_t>
    private let redirectBuffer: UnsafeMutablePointer<wchar_t>

    init(url: URL, mode: Int32, password: String?) throws {
        self.url = url
        callbacks = RarCallbacks(password: password)
        var path = RarHandle.wide(url.path)
        var data = RAROpenArchiveDataEx()
        data.OpenMode = UInt32(mode)
        data.Callback = rarCallback
        data.UserData = Int(bitPattern: Unmanaged.passUnretained(callbacks).toOpaque())
        let opened = path.withUnsafeMutableBufferPointer { buffer -> UnsafeMutableRawPointer? in
            data.ArcNameW = buffer.baseAddress
            return RAROpenArchiveEx(&data)
        }
        guard let opened else {
            let code = Int32(data.OpenResult)
            let archive = url.lastPathComponent
            switch code {
            case ERAR_MISSING_PASSWORD:
                throw ArchiveError.passwordNeeded(archive: archive)
            case ERAR_BAD_PASSWORD:
                throw ArchiveError.wrongPassword(archive: archive)
            case ERAR_BAD_ARCHIVE, ERAR_UNKNOWN_FORMAT, ERAR_BAD_DATA:
                // Encrypted names read with a wrong RAR 4 password look like damaged headers.
                if callbacks.passwordAsked, password != nil { throw ArchiveError.wrongPassword(archive: archive) }
                if code == ERAR_BAD_DATA { throw ArchiveError.damaged("The archive headers are damaged", archive: archive) }
                throw OpenFailure.notRar
            case ERAR_EOPEN:
                throw ArchiveError.damaged("The archive cannot be opened", archive: archive)
            default:
                throw ArchiveError.damaged(Self.message(code), archive: archive)
            }
        }
        handle = opened
        header = .allocate(capacity: 1)
        header.initialize(to: RARHeaderDataEx())
        nameBuffer = .allocate(capacity: Self.nameCapacity)
        redirectBuffer = .allocate(capacity: Self.nameCapacity)
    }

    deinit {
        RARCloseArchive(handle)
        header.deinitialize(count: 1)
        header.deallocate()
        nameBuffer.deallocate()
        redirectBuffer.deallocate()
    }

    /// The next file header, or nil at the end of the archive.
    func nextHeader() throws -> Header? {
        header.pointee = RARHeaderDataEx()
        nameBuffer[0] = 0
        redirectBuffer[0] = 0
        header.pointee.FileNameEx = nameBuffer
        header.pointee.FileNameExSize = UInt32(Self.nameCapacity)
        header.pointee.RedirName = redirectBuffer
        header.pointee.RedirNameSize = UInt32(Self.nameCapacity)
        BasilUnRARClearErrors()
        let code = RARReadHeaderEx(handle, header)
        if code == ERAR_END_ARCHIVE { return nil }
        guard code == ERAR_SUCCESS else {
            if code == ERAR_BAD_PASSWORD || (code == ERAR_BAD_DATA && callbacks.passwordAsked && callbacks.hasPassword) {
                throw ArchiveError.wrongPassword(archive: url.lastPathComponent)
            }
            if code == ERAR_MISSING_PASSWORD { throw ArchiveError.passwordNeeded(archive: url.lastPathComponent) }
            throw error(code, entry: nil)
        }
        let h = header.pointee
        let name = Self.string(nameBuffer)
        let redirectName = Self.string(redirectBuffer)
        let unix = h.HostOS == 3 // the library reports HOST_UNIX (3) or HOST_WIN32 (2)
        var permissions: UInt16?
        var isLinkMode = false
        if unix {
            permissions = UInt16(h.FileAttr & 0o7777)
            isLinkMode = h.FileAttr & 0o170000 == 0o120000
        }
        let redirect: Redirect = switch h.RedirType {
        case 1, 2, 3: .symlink(redirectName.isEmpty ? nil : redirectName.replacingOccurrences(of: "\\", with: "/"))
        case 4: .hardLink(redirectName)
        case 5: .fileCopy(redirectName)
        default: isLinkMode ? .symlink(nil) : .none
        }
        return Header(path: name, isDirectory: h.Flags & UInt32(RHDF_DIRECTORY) != 0,
                      size: Int64(h.UnpSizeHigh) << 32 | Int64(h.UnpSize),
                      modified: Self.time(low: h.MtimeLow, high: h.MtimeHigh),
                      permissions: permissions, isEncrypted: h.Flags & UInt32(RHDF_ENCRYPTED) != 0,
                      splitBefore: h.Flags & UInt32(RHDF_SPLITBEFORE) != 0, redirect: redirect)
    }

    /// Moves past the current entry (in a solid archive this unpacks it, without output).
    func skip() throws {
        BasilUnRARClearErrors()
        let code = RARProcessFileW(handle, RAR_SKIP, nil, nil)
        guard code == ERAR_SUCCESS else { throw error(code, entry: nil) }
    }

    /// RAR_TEST (data goes to `callbacks.sink`) or RAR_EXTRACT into `folder`.
    func process(_ operation: Int32, into folder: String? = nil) -> Int32 {
        BasilUnRARClearErrors()
        guard let folder else { return RARProcessFileW(handle, operation, nil, nil) }
        var path = Self.wide(folder)
        return path.withUnsafeMutableBufferPointer { RARProcessFileW(handle, operation, $0.baseAddress, nil) }
    }

    func error(_ code: Int32, entry: ArchiveEntry?) -> ArchiveError {
        let archive = url.lastPathComponent
        let name = entry.map { String($0.path.dropFirst()) }
        switch code {
        case ERAR_BAD_PASSWORD:
            return .wrongPassword(archive: archive)
        case ERAR_MISSING_PASSWORD:
            return name.map { .encrypted(entry: $0) } ?? .passwordNeeded(archive: archive)
        case ERAR_BAD_DATA:
            guard let name else { return .damaged("The archive is damaged", archive: archive) }
            return .damaged(entry!.isEncrypted ? "\(name): wrong password or damaged data" : "\(name): CRC error, the data is damaged",
                            archive: archive)
        case ERAR_EOPEN:
            if let volume = callbacks.missingVolume {
                return .damaged("The next volume \((volume as NSString).lastPathComponent) is missing", archive: archive)
            }
            return .damaged("The archive cannot be opened", archive: archive)
        default:
            let message = Self.message(code)
            return .damaged(name.map { "\($0): \(message)" } ?? message, archive: archive)
        }
    }

    /// A test problem line: "folder/file.bin: CRC error, the data is damaged".
    static func problem(_ error: ArchiveError, entry name: String) -> String {
        switch error {
        case .damaged(let message, _): message.hasPrefix(name + ":") ? message : "\(name): \(message)"
        case .wrongPassword: "\(name): wrong password"
        case .encrypted: "\(name): encrypted, not tested"
        default: "\(name): \(error.localizedDescription)"
        }
    }

    static func message(_ code: Int32) -> String {
        switch code {
        case ERAR_NO_MEMORY: "Not enough memory to unpack"
        case ERAR_BAD_ARCHIVE: "Not a RAR archive"
        case ERAR_UNKNOWN_FORMAT: "Unknown RAR format or method"
        case ERAR_EREAD: "Read error"
        case ERAR_EREFERENCE: "The file it refers to cannot be unpacked"
        case ERAR_LARGE_DICT: "It needs a dictionary larger than 4 GB, which Basil does not unpack"
        case ERAR_ECREATE, ERAR_EWRITE: "A file could not be created"
        default: "UnRAR error \(code)"
        }
    }

    /// Windows FILETIME (100 ns steps since 1601) to a Unix time.
    static func time(low: UInt32, high: UInt32) -> timespec? {
        let ticks = Int64(high) << 32 | Int64(low)
        guard ticks > 0 else { return nil }
        let unix = ticks - 116_444_736_000_000_000
        return timespec(tv_sec: Int(unix / 10_000_000), tv_nsec: Int(unix % 10_000_000) * 100)
    }

    static func wide(_ text: String) -> [wchar_t] {
        text.unicodeScalars.map { wchar_t(bitPattern: $0.value) } + [0]
    }

    static func string(_ pointer: UnsafePointer<wchar_t>) -> String {
        var scalars = String.UnicodeScalarView()
        var p = pointer
        while p.pointee != 0 {
            if let scalar = Unicode.Scalar(UInt32(bitPattern: p.pointee)) { scalars.append(scalar) }
            p += 1
        }
        return String(scalars)
    }
}

/// State the UnRAR callback reaches through its user data. Touched only by the thread that
/// calls into the library for this handle.
final class RarCallbacks {
    private let password: [wchar_t]?
    var hasPassword: Bool { password != nil }
    /// Whether the library asked for a password (the names or the data are encrypted).
    var passwordAsked = false
    /// The volume the library asked for and did not find.
    var missingVolume: String?
    /// Gets each piece of unpacked data during RAR_TEST; false stops unpacking.
    var sink: ((UnsafeRawBufferPointer) -> Bool)?

    init(password: String?) {
        self.password = password.map(RarHandle.wide)
    }

    func supplyPassword(into buffer: UnsafeMutablePointer<wchar_t>, capacity: Int) -> Int32 {
        passwordAsked = true
        guard let password, capacity > 0, password.count <= capacity else { return -1 }
        for (i, c) in password.enumerated() { buffer[i] = c }
        return 1
    }
}

/// The UnRAR callback (a C function, so it captures nothing).
private let rarCallback: UNRARCALLBACK = { message, userData, p1, p2 in
    guard let raw = UnsafeRawPointer(bitPattern: userData) else { return -1 }
    let state = Unmanaged<RarCallbacks>.fromOpaque(raw).takeUnretainedValue()
    switch message {
    case UCM_PROCESSDATA.rawValue:
        guard let sink = state.sink, let address = UnsafeRawPointer(bitPattern: p1) else { return 1 }
        return sink(UnsafeRawBufferPointer(start: address, count: p2)) ? 1 : -1
    case UCM_NEEDPASSWORDW.rawValue:
        guard let buffer = UnsafeMutablePointer<wchar_t>(bitPattern: p1) else { return -1 }
        return state.supplyPassword(into: buffer, capacity: p2)
    case UCM_NEEDPASSWORD.rawValue:
        state.passwordAsked = true
        return -1 // the wide-character request above already answered
    case UCM_CHANGEVOLUMEW.rawValue:
        if p2 == RAR_VOL_ASK, let name = UnsafePointer<wchar_t>(bitPattern: p1) {
            state.missingVolume = RarHandle.string(name)
            return -1
        }
        return 1
    case UCM_CHANGEVOLUME.rawValue:
        return p2 == RAR_VOL_ASK ? -1 : 1
    case UCM_LARGEDICT.rawValue:
        return 0 // refuse dictionaries over 4 GB (an archive could ask for 64 GB of memory)
    default:
        return 0
    }
}

/// Streams entry data from an `RarProducer` thread. Reading forward costs one pass through the
/// archive; reading an earlier entry (or an earlier offset) starts a new producer.
final class UnRARSession: ArchiveReadSession {
    private let url: URL
    private let entries: [ArchiveEntry]
    private let password: String?
    private var producer: RarProducer?
    /// Ordinals of the entries the producer writes, in order, and the position in that list.
    private var stream: [Int] = []
    private var position = 0
    /// Bytes of `stream[position]` read so far.
    private var consumed: Int64 = 0

    init(url: URL, entries: [ArchiveEntry], password: String?) {
        self.url = url
        self.entries = entries
        self.password = password
    }

    deinit { stop() }

    static func hasData(_ entry: ArchiveEntry) -> Bool {
        entry.kind == .file && entry.dataOrdinal == entry.ordinal && (entry.size ?? 0) > 0
    }

    private func stop() {
        producer?.stop()
        producer = nil
    }

    func read(_ entry: ArchiveEntry, at offset: Int64, count: Int) throws -> Data {
        let target = entry.dataOrdinal
        guard entries.indices.contains(target) else { throw ArchiveError.entryNotFound(entry.path) }
        let size = entries[target].size ?? 0
        if offset >= size { return Data() }
        let ahead = producer != nil && position < stream.count
            && (stream[position] < target || (stream[position] == target && consumed <= offset))
            && stream[position...].contains(target)
        if !ahead { try restart(at: target) }
        while stream[position] != target {
            try skip(Int(entries[stream[position]].size ?? 0) - Int(consumed))
            nextEntry()
        }
        if consumed < offset { try skip(Int(offset - consumed)) }
        let data = try pull(Int(min(Int64(count), size - consumed)))
        if consumed == size { nextEntry() }
        return data
    }

    private func restart(at target: Int) throws {
        stop()
        stream = entries[target...].filter(Self.hasData).map(\.ordinal)
        position = 0
        consumed = 0
        producer = try RarProducer(url: url, password: password, entries: entries, wanted: stream)
    }

    private func nextEntry() {
        position += 1
        consumed = 0
        if position >= stream.count { stop() }
    }

    private func skip(_ count: Int) throws {
        var left = count
        while left > 0 { left -= try pull(min(left, 1 << 20)).count }
    }

    private func pull(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        guard let producer else { throw ArchiveError.damaged("UnRAR stopped", archive: url.lastPathComponent) }
        var out = Data(count: count)
        var filled = 0
        out.withUnsafeMutableBytes { raw in
            while filled < count {
                let n = Darwin.read(producer.output, raw.baseAddress! + filled, count - filled)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                filled += n
            }
        }
        consumed += Int64(filled)
        if filled < count {
            let entry = entries[stream[position]]
            let error = producer.finish()
            stop()
            throw error ?? ArchiveError.damaged("\(entry.path.dropFirst()): the data ended early", archive: url.lastPathComponent)
        }
        return out
    }
}

/// A thread that opens the archive, tests the wanted entries in archive order and writes their
/// data into a pipe; `output` is the reading end. It stops at the first error (kept for
/// `finish`) or when the reading end is closed.
final class RarProducer: @unchecked Sendable {
    let output: Int32
    private let input: Int32
    private let stopped = Atomic<Bool>(false)
    private let outputClosed = Mutex(false)
    private let failure = Mutex<ArchiveError?>(nil)
    private let done = DispatchSemaphore(value: 0)

    init(url: URL, password: String?, entries: [ArchiveEntry], wanted: [Int]) throws {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ArchiveError.damaged("No pipe for UnRAR", archive: url.lastPathComponent) }
        output = fds[0]
        input = fds[1]
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(input, F_SETNOSIGPIPE, 1) // a closed reading end fails the write instead of killing the app
        SevenZipTool.thread { [self] in
            UTF8Locale.use()
            if let error = produce(url: url, password: password, entries: entries, wanted: wanted) {
                failure.withLock { $0 = error }
            }
            close(input)
            done.signal()
        }
    }

    deinit {
        stop()
    }

    /// Closes the reading end; the thread stops at its next write or entry.
    func stop() {
        stopped.store(true, ordering: .relaxed)
        outputClosed.withLock { closed in
            if !closed { close(output) }
            closed = true
        }
    }

    /// Waits for the thread to end and returns what stopped it, if it failed.
    func finish() -> ArchiveError? {
        done.wait()
        done.signal()
        return failure.withLock { $0 }
    }

    private func produce(url: URL, password: String?, entries: [ArchiveEntry], wanted: [Int]) -> ArchiveError? {
        guard let last = wanted.last else { return nil }
        let wantedSet = Set(wanted)
        do {
            let archive = try RarHandle(url: url, mode: RAR_OM_EXTRACT, password: password)
            var ordinal = 0
            while ordinal <= last, !stopped.load(ordering: .relaxed), let header = try archive.nextHeader() {
                if header.splitBefore {
                    try archive.skip()
                    continue
                }
                defer { ordinal += 1 }
                guard wantedSet.contains(ordinal) else {
                    try archive.skip()
                    continue
                }
                // Hold the latest piece back until the library has checked the whole file.
                var held: Data?
                var writeFailed = false
                archive.callbacks.sink = { [input] chunk in
                    if let previous = held, !Self.write(previous, to: input) {
                        writeFailed = true
                        return false
                    }
                    held = Data(chunk)
                    return true
                }
                let code = archive.process(RAR_TEST)
                archive.callbacks.sink = nil
                if writeFailed || stopped.load(ordering: .relaxed) { return nil }
                guard code == ERAR_SUCCESS else { return archive.error(code, entry: entries[ordinal]) }
                if let held, !Self.write(held, to: input) { return nil }
            }
            return nil
        } catch let error as ArchiveError {
            return error
        } catch {
            return .damaged(error.localizedDescription, archive: url.lastPathComponent)
        }
    }

    private static func write(_ data: Data, to fd: Int32) -> Bool {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
    }
}
