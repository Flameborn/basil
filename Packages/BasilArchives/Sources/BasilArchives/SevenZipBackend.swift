import BasilCore
import Darwin
import Foundation
import zlib

/// Reads 7z archives through the bundled 7zz tool (decision 2026-11-22): listing with
/// `l -slt`, data with `x -so` (one process streams every file from the requested one on, in
/// archive order, so extracting a solid archive decompresses it once), testing with `t`.
public struct SevenZipBackend: ArchiveBackend {
    public var name: String { "7-Zip" }
    let tool: SevenZipTool

    public init(executable: URL) {
        tool = SevenZipTool(executable: executable)
    }

    /// The 7zz inside the app (Contents/MacOS/7zz), if it is there.
    public static func bundled(in bundle: Bundle = .main) -> SevenZipBackend? {
        bundle.url(forAuxiliaryExecutable: "7zz").map(SevenZipBackend.init(executable:))
    }

    static let suffixes: Set<String> = ["7z"]

    public func recognizes(name: String) -> Bool {
        ArchiveNames.suffixes(of: name).contains { Self.suffixes.contains($0) }
    }

    public func entries(of url: URL, byContent: Bool) throws -> [ArchiveEntry]? {
        let output = try tool.run(["l", "-slt", "-ba", "-bso1", "-bsp0", "-t7z", "--", url.path])
        if output.askedForPassword {
            throw ArchiveError.encrypted(entry: url.lastPathComponent)
        }
        if output.status != 0 {
            let errors = output.errors
            if output.stderr.contains("Cannot open the file as") || output.stderr.contains("Is not archive") {
                return nil
            }
            if errors.contains(where: { $0.contains("errno=2") || $0.contains("errno=13") || $0.contains("errno=1 ") }) || output.stdout.isEmpty {
                throw ArchiveError.damaged(errors.first ?? "7-Zip could not read the archive", archive: url.lastPathComponent)
            }
        }
        var entries = SevenZipListing.entries(output.stdoutText)
        try readSymlinkTargets(&entries, of: url)
        return entries
    }

    /// 7z stores a link's target as its data; read all of them in one run.
    private func readSymlinkTargets(_ entries: inout [ArchiveEntry], of url: URL) throws {
        let links = entries.indices.filter { entries[$0].kind == .symlink && !entries[$0].isEncrypted }
        guard !links.isEmpty else { return }
        let session = SevenZipSession(tool: tool, url: url, entries: entries)
        for i in links {
            let data = try session.read(entries[i], at: 0, count: Int(entries[i].size ?? 0))
            entries[i].symlinkTarget = String(decoding: data, as: UTF8.self)
        }
    }

    public func session(for url: URL, byContent: Bool, entries: [ArchiveEntry]) -> any ArchiveReadSession {
        SevenZipSession(tool: tool, url: url, entries: entries)
    }

    public func test(_ url: URL, byContent: Bool, progress: (Double, String) -> Bool) throws -> [String] {
        let running = try tool.start(["t", "-bso1", "-bsp1", "-t7z", "--", url.path])
        let stderr = running.drainStderr()
        let fd = running.stdout
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pending = ""
        var output = ""
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            if n <= 0 { break }
            let text = String(decoding: buffer[0..<n], as: UTF8.self)
            output += text
            pending += text
            // Progress is redrawn with backspaces: "  45% 3 T folder/file.bin".
            let pieces = pending.split(omittingEmptySubsequences: false) { $0 == "\u{8}" || $0 == "\r" || $0 == "\n" }
            pending = String(pieces.last ?? "")
            for piece in pieces.dropLast() {
                if let (fraction, name) = Self.progress(piece), !progress(fraction, name) {
                    running.stop()
                    throw CancellationError()
                }
            }
        }
        let result = SevenZipTool.Output(status: running.wait(), stdout: Data(output.utf8), stderr: stderr.wait())
        _ = progress(1, "")
        if result.askedForPassword { return ["Encrypted files were not tested: passwords are not supported yet"] }
        guard result.status != 0 else { return [] }
        let problems = result.errors.map { line -> String in
            // "CRC Failed : folder/file.bin" -> "folder/file.bin: CRC Failed"
            let parts = line.components(separatedBy: " : ")
            return parts.count == 2 ? "\(parts[1]): \(parts[0])" : line
        }
        if problems.isEmpty { return ["7-Zip reported errors (exit status \(result.status))"] }
        if result.status > 2 { throw ArchiveError.damaged(problems.joined(separator: "; "), archive: url.lastPathComponent) }
        return problems
    }

    static func progress(_ piece: Substring) -> (Double, String)? {
        let text = piece.trimmingCharacters(in: .whitespaces)
        guard let percent = text.firstIndex(of: "%"), let value = Double(text[..<percent]) else { return nil }
        var rest = text[text.index(after: percent)...].split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        if let first = rest.first, Int(first) != nil { rest.removeFirst() }
        if let first = rest.first, first.count == 1, first.first?.isUppercase == true { rest.removeFirst() }
        return (min(1, value / 100), rest.joined(separator: " "))
    }
}

/// Streams entry data out of one `7zz x -so` process. It starts at the requested entry and
/// writes every file after it in archive order, so reading forward costs one decompression;
/// reading an earlier entry (or an earlier offset) starts a new process. Each file's CRC is
/// checked as its last byte is read, because 7zz writes damaged data to stdout all the same.
final class SevenZipSession: ArchiveReadSession {
    private let tool: SevenZipTool
    private let url: URL
    private let entries: [ArchiveEntry]
    private let password: String?

    private var running: SevenZipTool.Running?
    private var stderr: SevenZipTool.Collected?
    private var listFile: URL?
    /// Ordinals of the entries the process writes, in order, and the position in that list.
    private var stream: [Int] = []
    private var position = 0
    /// Bytes of `stream[position]` read so far, and their CRC.
    private var consumed: Int64 = 0
    private var crc: uLong = 0

    init(tool: SevenZipTool, url: URL, entries: [ArchiveEntry], password: String? = nil) {
        self.tool = tool
        self.url = url
        self.entries = entries
        self.password = password
    }

    deinit { stop() }

    private func stop() {
        running?.stop()
        running = nil
        if let listFile { unlink(listFile.path) }
        listFile = nil
    }

    private static func hasData(_ entry: ArchiveEntry) -> Bool {
        (entry.kind == .file || entry.kind == .symlink) && entry.storedName != nil
    }

    func read(_ entry: ArchiveEntry, at offset: Int64, count: Int) throws -> Data {
        let target = entry.dataOrdinal
        let size = entries.indices.contains(target) ? entries[target].size ?? 0 : 0
        if offset >= size { return Data() }
        let ahead = running != nil && position < stream.count
            && (stream[position] < target || (stream[position] == target && consumed <= offset))
            && stream[position...].contains(target)
        if !ahead { try restart(at: target) }
        // Skip the rest of the current entry and the ones before the target.
        while stream[position] != target {
            try skip(Int(entries[stream[position]].size ?? 0) - Int(consumed))
            try nextEntry()
        }
        if consumed < offset { try skip(Int(offset - consumed)) }
        let want = Int(min(Int64(count), size - consumed))
        let data = try pull(want)
        if consumed == size { try nextEntry() }
        return data
    }

    private func restart(at target: Int) throws {
        stop()
        guard entries.indices.contains(target), let first = entries[target].storedName else {
            throw ArchiveError.entryNotFound(entries.indices.contains(target) ? entries[target].path : "")
        }
        // Every name from the target on; a name stored twice also brings its earlier copy along.
        var names = Set<String>()
        for entry in entries[target...] where Self.hasData(entry) { names.insert(entry.storedName!) }
        names.insert(first)
        stream = entries.filter { Self.hasData($0) && names.contains($0.storedName!) }.map(\.ordinal)
        position = stream.firstIndex(of: target) ?? 0
        let list = FileManager.default.temporaryDirectory.appendingPathComponent("basil-7z-\(UUID().uuidString).txt")
        try Data(names.sorted().joined(separator: "\n").utf8).write(to: list)
        listFile = list
        let process = try tool.start(["x", "-so", "-snl", "-spd", "-y", "-bsp0", "-t7z", "-i@" + list.path, "--", url.path],
                                     password: password)
        running = process
        stderr = process.drainStderr()
        // The process writes from the start of the stream: skip entries before the target.
        let start = position
        position = 0
        consumed = 0
        crc = crc32(0, nil, 0)
        while position < start {
            try skip(Int(entries[stream[position]].size ?? 0))
            try nextEntry()
        }
    }

    /// Checks the finished entry's CRC and moves on to the next one in the stream.
    private func nextEntry() throws {
        let entry = entries[stream[position]]
        if let expected = entry.crc32, consumed == (entry.size ?? 0), UInt32(crc) != expected {
            stop()
            throw ArchiveError.damaged(dataError(for: entry), archive: url.lastPathComponent)
        }
        position += 1
        consumed = 0
        crc = crc32(0, nil, 0)
        if position >= stream.count { stop() }
    }

    private func dataError(for entry: ArchiveEntry) -> String {
        let name = String(entry.path.dropFirst())
        return entry.isEncrypted ? "\(name): wrong password or damaged data" : "\(name): CRC error, the data is damaged"
    }

    private func skip(_ count: Int) throws {
        var left = count
        while left > 0 {
            let chunk = try pull(min(left, 1 << 20))
            left -= chunk.count
        }
    }

    /// Reads exactly `count` bytes of the current entry from the process.
    private func pull(_ count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        guard let running else { throw ArchiveError.damaged("7-Zip stopped", archive: url.lastPathComponent) }
        let fd = running.stdout
        var out = Data(count: count)
        var filled = 0
        out.withUnsafeMutableBytes { raw in
            while filled < count {
                let n = Darwin.read(fd, raw.baseAddress! + filled, count - filled)
                if n < 0, errno == EINTR { continue }
                if n <= 0 { break }
                filled += n
            }
            crc = crc32(crc, raw.baseAddress!.assumingMemoryBound(to: Bytef.self), uInt(filled))
        }
        consumed += Int64(filled)
        if filled < count {
            // The stream ended early: 7zz failed. Its stderr says why.
            let output = SevenZipTool.Output(status: running.wait(), stdout: Data(), stderr: stderr?.wait() ?? "")
            let entry = entries[stream[position]]
            stop()
            if output.askedForPassword { throw ArchiveError.encrypted(entry: String(entry.path.dropFirst())) }
            throw ArchiveError.damaged(output.errors.first ?? dataError(for: entry), archive: url.lastPathComponent)
        }
        return out
    }
}
