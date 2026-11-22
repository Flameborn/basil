import BasilCore
import BasilVFS
import Foundation

/// A part size offered in the split dialog.
public struct SplitPreset: Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    /// Exact bytes; nil for "Custom".
    public let bytes: Int64?
}

/// Part sizes for Files > Split > Split File: media presets and typed sizes ("700 MB").
public enum SplitSizes {
    /// Media sizes are exact (2048-byte sectors), not rounded units.
    public static let presets: [SplitPreset] = [
        SplitPreset(id: "cd650", title: "CD, 650 MB", bytes: 333_000 * 2048),
        SplitPreset(id: "cd700", title: "CD, 700 MB", bytes: 360_000 * 2048),
        SplitPreset(id: "cd800", title: "CD, 800 MB", bytes: 405_000 * 2048),
        SplitPreset(id: "dvd", title: "DVD, 4.7 GB", bytes: 2_295_104 * 2048),
        SplitPreset(id: "dvddl", title: "DVD dual layer, 8.5 GB", bytes: 4_171_712 * 2048),
        SplitPreset(id: "bd", title: "Blu-ray, 25 GB", bytes: 12_219_392 * 2048),
        SplitPreset(id: "bddl", title: "Blu-ray dual layer, 50 GB", bytes: 24_438_784 * 2048),
        SplitPreset(id: "fat32", title: "FAT32 largest file, 4 GB", bytes: 4_294_967_295),
        SplitPreset(id: "custom", title: "Custom size", bytes: nil),
    ]

    public enum ParseError: Error, Equatable, LocalizedError {
        case empty, notANumber, noUnit, unknownUnit(String), tooSmall

        public var errorDescription: String? {
            switch self {
            case .empty: "Type a part size, for example 700 MB."
            case .notANumber: "The part size must start with a number, for example 1.5 GB."
            case .noUnit: "Add a unit after the number: bytes, KB, MB, GB or TB."
            case .unknownUnit(let u): "\(u) is not a unit Basil knows. Use bytes, KB, MB, GB or TB."
            case .tooSmall: "A part must be at least 1 byte."
            }
        }
    }

    /// "512 MB", "1gb", "1.5 GB", "4096 bytes". `decimal` makes KB 1000 bytes instead of 1024.
    public static func parse(_ text: String, decimal: Bool) -> Result<Int64, ParseError> {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return .failure(.empty) }
        let number = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard let value = Double(number.replacingOccurrences(of: ",", with: ".")) else { return .failure(.notANumber) }
        let unit = trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces)
        guard !unit.isEmpty else { return .failure(.noUnit) }
        let power: Double
        switch unit {
        case "b", "byte", "bytes": power = 0
        case "k", "kb", "kib": power = 1
        case "m", "mb", "mib": power = 2
        case "g", "gb", "gib": power = 3
        case "t", "tb", "tib": power = 4
        default: return .failure(.unknownUnit(unit))
        }
        let bytes = (value * pow(decimal ? 1000 : 1024, power)).rounded(.down)
        guard bytes >= 1 else { return .failure(.tooSmall) }
        guard bytes < Double(Int64.max) else { return .failure(.notANumber) }
        return .success(Int64(bytes))
    }
}

/// What a split recorded about the original file: from Basil's SFV (comments plus one line per
/// part) or Total Commander's .crc file (name, size and CRC32 of the whole file).
public struct SplitInfo: Sendable, Equatable {
    public var originalName: String?
    public var size: Int64?
    public var crc32: String?
    /// CRC32 of each part by name.
    public var partCRCs: [String: String] = [:]
    /// The SFV or CRC file it came from.
    public var source: VFSPath?

    public init() {}

    static let marker = "; Split by Basil from "

    /// Basil's SFV: comments `; original-name=`, `; original-size=`, `; original-crc32=`, then
    /// `part CRC` lines.
    static func sfv(originalName: String, size: Int64, crc: String, parts: [(String, String)]) -> String {
        var text = marker + originalName + "\n"
        text += "; original-name=\(originalName)\n; original-size=\(size)\n; original-crc32=\(crc)\n"
        for (name, partCRC) in parts { text += "\(name) \(partCRC)\n" }
        return text
    }

    static func parse(sfv text: String) -> SplitInfo {
        var info = SplitInfo()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(";") {
                let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
                if let v = value(body, "original-name") { info.originalName = v }
                if let v = value(body, "original-size") { info.size = Int64(v) }
                if let v = value(body, "original-crc32") { info.crc32 = v }
                continue
            }
            guard let space = line.lastIndex(of: " ") else { continue }
            let name = line[..<space].trimmingCharacters(in: .whitespaces)
            let crc = line[line.index(after: space)...]
            if crc.count == 8, crc.allSatisfy(\.isHexDigit) { info.partCRCs[name] = String(crc) }
        }
        return info
    }

    /// Total Commander's .crc: `filename=`, `size=`, `crc32=`.
    static func parse(tcCRC text: String) -> SplitInfo {
        var info = SplitInfo()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let v = value(line, "filename") { info.originalName = v }
            if let v = value(line, "size") { info.size = Int64(v) }
            if let v = value(line, "crc32") { info.crc32 = v }
        }
        return info
    }

    private static func value(_ line: String, _ key: String) -> String? {
        guard line.lowercased().hasPrefix(key + "=") else { return nil }
        return String(line.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
    }
}

/// The parts of a split file found next to one of them.
public struct SplitSet: Sendable, Equatable {
    /// "movie.mkv" for movie.mkv.001.
    public var baseName: String
    public var parts: [VFSPath]
    public var info: SplitInfo?
    /// The name the combined file gets: the recorded original name, else the base name.
    public var outputName: String { info?.originalName.flatMap { $0.isEmpty || $0.contains("/") ? nil : $0 } ?? baseName }
}

public enum SplitProblem: LocalizedError, Equatable {
    case notLarger(String)
    case notAPart(String)
    case missingPart(String)
    case damagedPart(String)
    case wrongResult(String)

    public var errorDescription: String? {
        switch self {
        case .notLarger(let name): "\(name) is not larger than one part, so there is nothing to split."
        case .notAPart(let name): "\(name) is not a part of a split file (name.001, name.002, ...)."
        case .missingPart(let name): "The part \(name) is missing."
        case .damagedPart(let name): "\(name) is damaged: its CRC32 does not match the SFV file."
        case .wrongResult(let why): "The combined file is not the original: \(why). It was not kept."
        }
    }
}

/// Writes a small text file through a partial file renamed into place.
func writeSmallFile(_ text: String, to target: VFSPath, provider: any WritableProvider) async throws {
    guard let folder = target.parent else { throw VFSError.notFound(target) }
    let partial = folder.appending(".basil-partial-\(UUID().uuidString.prefix(8))-\(target.name)")
    let file = try await provider.createFile(partial)
    do {
        try await file.write(Data(text.utf8), at: 0)
        _ = try await file.apply(FileMetadata(permissions: 0o644))
        try await file.synchronize()
        await file.close()
        try await provider.rename(partial, to: target, replacing: true)
    } catch {
        await file.close()
        try? await provider.remove(partial)
        throw error
    }
}

/// Files > Split > Split File (Total Commander's Split File): cuts a file into parts
/// "name.ext.001", "name.ext.002", ... of `partSize` bytes in `target`, optionally with
/// "name.ext.sfv" holding each part's CRC32 and the original's name, size and CRC32 (Combine
/// checks against it). Parts are written through partial files; a source that changes while it
/// is split is split again (the unstable-source policy). Older parts with higher numbers from an
/// earlier split are removed, so Combine never joins them.
public struct SplitFileOperation: QueueOperation {
    public let source: VFSPath
    public let target: VFSPath
    public let partSize: Int64
    public let createSFV: Bool
    public let unstableRetries: Int
    let registry: ProviderRegistry

    public init(source: VFSPath, target: VFSPath, partSize: Int64, createSFV: Bool, unstableRetries: Int = 3,
                registry: ProviderRegistry) {
        self.source = source
        self.target = target
        self.partSize = partSize
        self.createSFV = createSFV
        self.unstableRetries = unstableRetries
        self.registry = registry
    }

    public var kind: OperationKind { .split }
    public var title: String { "Split \(source.name)" }

    /// "movie.mkv.001" for part 1 of `count`.
    public static func partName(_ name: String, _ n: Int, count: Int) -> String {
        let digits = max(3, String(count).count)
        let number = String(n)
        return name + "." + String(repeating: "0", count: max(0, digits - number.count)) + number
    }

    public static func partCount(size: Int64, partSize: Int64) -> Int {
        Int((size + partSize - 1) / partSize)
    }

    public func run(_ context: OperationContext) async throws {
        let src = try registry.writableProvider(for: source.location)
        let dst = try registry.writableProvider(for: target.location)
        var attempts = 0
        while true {
            let before = try await src.fingerprint(of: source)
            guard before.kind == .file else { throw VFSError.unsupported("splitting \(source.name): it is not a file") }
            guard before.size > partSize else { throw SplitProblem.notLarger(source.name) }
            let count = Self.partCount(size: before.size, partSize: partSize)
            let (parts, whole) = try await splitOnce(src, dst, size: before.size, count: count, context: context)
            let after = try await src.fingerprint(of: source)
            if after == before {
                try await finish(dst, size: before.size, crc: whole, parts: parts, context: context)
                return
            }
            attempts += 1
            if attempts <= unstableRetries {
                context.log("\(source.name) changed while it was split, splitting again (attempt \(attempts))")
                try await Task.sleep(for: .milliseconds(500 * attempts))
                continue
            }
            guard case .unstableSource(let decision) = await context.ask(.unstableSource(UnstableSource(path: source, attempts: attempts)))
            else { throw CancellationError() }
            switch decision {
            case .keepRetrying:
                attempts = 0
            case .acceptLatest:
                context.log("Accepted while still changing: \(source.path)")
                try await finish(dst, size: before.size, crc: whole, parts: parts, context: context)
                return
            case .skip:
                context.log("Skipped \(source.path): it kept changing; the parts may not match it")
                return
            case .cancel:
                throw CancellationError()
            }
        }
    }

    /// Writes every part; returns each part's name and CRC32 and the whole file's CRC32.
    private func splitOnce(_ src: any WritableProvider, _ dst: any WritableProvider, size: Int64, count: Int,
                           context: OperationContext) async throws -> ([(String, String)], String) {
        let reader = try await src.openForReading(source, bypassCache: false)
        let chunk = min(src.maxTransferChunkSize ?? 4 << 20, dst.maxTransferChunkSize ?? 4 << 20, 4 << 20)
        let whole = ChecksumAlgorithm.crc32.makeHasher()
        var parts: [(String, String)] = []
        var offset: Int64 = 0
        context.items(done: 0, total: count)
        do {
            for n in 1...count {
                let name = Self.partName(source.name, n, count: count)
                let path = target.appending(name)
                let partial = target.appending(".basil-partial-\(UUID().uuidString.prefix(8))-\(name)")
                let file = try await dst.createFile(partial)
                let hasher = ChecksumAlgorithm.crc32.makeHasher()
                do {
                    var written: Int64 = 0
                    let length = min(partSize, size - offset)
                    while written < length {
                        try await context.checkpoint()
                        let data = try await reader.read(at: offset, count: Int(min(Int64(chunk), length - written)))
                        if data.isEmpty { break } // the source got shorter: the fingerprint check catches it
                        try await file.write(data, at: written)
                        hasher.update(data)
                        whole.update(data)
                        written += Int64(data.count)
                        offset += Int64(data.count)
                        context.progress(Double(offset) / Double(max(size, 1)), "Part \(n) of \(count), \(name)")
                    }
                    _ = try await file.apply(FileMetadata(permissions: 0o644))
                    try await file.synchronize()
                    await file.close()
                    try await dst.rename(partial, to: path, replacing: true)
                } catch {
                    await file.close()
                    try? await dst.remove(partial)
                    throw error
                }
                parts.append((name, hasher.finalize().uppercased()))
                context.items(done: n, total: count)
            }
        } catch {
            await reader.close()
            throw error
        }
        await reader.close()
        return (parts, whole.finalize().uppercased())
    }

    private func finish(_ dst: any WritableProvider, size: Int64, crc: String, parts: [(String, String)],
                        context: OperationContext) async throws {
        let sfv = target.appending(source.name + ".sfv")
        if createSFV {
            try await writeSmallFile(SplitInfo.sfv(originalName: source.name, size: size, crc: crc, parts: parts), to: sfv, provider: dst)
            context.log("Wrote \(sfv.name)")
        }
        // Leftovers of an earlier split into more parts, or its SFV that no longer matches.
        var n = parts.count + 1
        while true {
            var found = false
            for digits in Set([3, String(parts.count).count, String(n).count]) where digits >= 3 {
                let number = String(n)
                let stale = target.appending(source.name + "." + String(repeating: "0", count: max(0, digits - number.count)) + number)
                if (try? await dst.fingerprint(of: stale)) != nil {
                    try await dst.remove(stale)
                    context.log("Removed \(stale.name), left over from an earlier split")
                    found = true
                }
            }
            guard found else { break }
            n += 1
        }
        if !createSFV, (try? await dst.fingerprint(of: sfv)) != nil,
           let old = try? await readText(sfv, provider: dst), old.hasPrefix(SplitInfo.marker) {
            try await dst.remove(sfv)
            context.log("Removed \(sfv.name), left over from an earlier split")
        }
        context.log("Split \(source.name) into \(parts.count) parts of up to \(partSize) bytes, CRC32 \(crc)")
        context.progress(1, "\(parts.count) parts")
    }
}

func readText(_ path: VFSPath, provider: any WritableProvider, limit: Int = 16 << 20) async throws -> String {
    let file = try await provider.openForReading(path, bypassCache: false)
    var data = Data()
    while data.count < limit {
        let chunk = try await file.read(at: Int64(data.count), count: 1 << 20)
        if chunk.isEmpty { break }
        data += chunk
    }
    await file.close()
    return String(decoding: data, as: UTF8.self)
}

/// Files > Split > Combine Files (Total Commander's Combine Files): joins name.001, name.002, ...
/// into one file. With Basil's SFV each part is checked while it is read and the result against
/// the original's size and CRC32; Total Commander's .crc checks the result. A result that does
/// not match is removed. Written through a partial file renamed into place.
public struct CombineFilesOperation: QueueOperation {
    public let set: SplitSet
    /// The file to create.
    public let destination: VFSPath
    let registry: ProviderRegistry

    public init(set: SplitSet, destination: VFSPath, registry: ProviderRegistry) {
        self.set = set
        self.destination = destination
        self.registry = registry
    }

    public var kind: OperationKind { .combine }
    public var title: String { "Combine \(set.parts.count) parts into \(destination.name)" }

    /// The split set `member` (any part, or the .sfv / .crc file) belongs to.
    public static func parts(of member: VFSPath, registry: ProviderRegistry) async throws -> SplitSet {
        guard let folder = member.parent else { throw SplitProblem.notAPart(member.name) }
        let provider = try registry.writableProvider(for: member.location)
        var base: String
        if let m = member.name.wholeMatch(of: /(.+)\.(\d{3,})/) {
            base = String(m.1)
        } else if let m = member.name.wholeMatch(of: /(?i)(.+)\.(sfv|crc)/) {
            base = String(m.1)
        } else {
            throw SplitProblem.notAPart(member.name)
        }
        var names: [String] = []
        for try await batch in provider.list(folder) { names += batch.filter { $0.kind == .file }.map(\.name) }
        let numbered = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix(base + "."), let n = Int(name.dropFirst(base.count + 1)),
                  name.dropFirst(base.count + 1).allSatisfy(\.isNumber) else { return nil }
            return (n, name)
        }.sorted { $0.0 < $1.0 }
        var info: SplitInfo?
        if names.contains(base + ".sfv") {
            let path = folder.appending(base + ".sfv")
            var parsed = SplitInfo.parse(sfv: try await readText(path, provider: provider))
            parsed.source = path
            info = parsed
        } else if names.contains(base + ".crc") {
            let path = folder.appending(base + ".crc")
            var parsed = SplitInfo.parse(tcCRC: try await readText(path, provider: provider))
            parsed.source = path
            info = parsed
        }
        guard let first = numbered.first else { throw SplitProblem.notAPart(member.name) }
        guard first.0 == 1 else { throw SplitProblem.missingPart(SplitFileOperation.partName(base, 1, count: 1)) }
        var parts: [VFSPath] = []
        for (i, (n, name)) in numbered.enumerated() {
            guard n == i + 1 else {
                throw SplitProblem.missingPart(SplitFileOperation.partName(base, i + 1, count: numbered.count))
            }
            parts.append(folder.appending(name))
        }
        if let listed = info?.partCRCs.keys {
            for name in listed.sorted() where !names.contains(name) { throw SplitProblem.missingPart(name) }
            parts = parts.filter { listed.isEmpty || listed.contains($0.name) }
        }
        return SplitSet(baseName: base, parts: parts, info: info)
    }

    public func run(_ context: OperationContext) async throws {
        let dst = try registry.writableProvider(for: destination.location)
        guard let folder = destination.parent else { throw VFSError.notFound(destination) }
        var total: Int64 = 0
        for part in set.parts { total += try await registry.writableProvider(for: part.location).fingerprint(of: part).size }
        if let info = set.info, let size = info.size, size != total {
            throw SplitProblem.wrongResult("the parts add up to \(total) bytes, but \(info.source?.name ?? "the SFV file") says \(size)")
        }
        if let source = set.info?.source { context.log("Checking against \(source.name)") }
        else { context.log("No SFV or CRC file next to the parts: the result cannot be checked") }

        let partial = folder.appending(".basil-partial-\(UUID().uuidString.prefix(8))-\(destination.name)")
        let file = try await dst.createFile(partial)
        let whole = ChecksumAlgorithm.crc32.makeHasher()
        var offset: Int64 = 0
        context.items(done: 0, total: set.parts.count)
        do {
            for (n, part) in set.parts.enumerated() {
                let src = try registry.writableProvider(for: part.location)
                let reader = try await src.openForReading(part, bypassCache: false)
                let chunk = min(src.maxTransferChunkSize ?? 4 << 20, dst.maxTransferChunkSize ?? 4 << 20, 4 << 20)
                let hasher = ChecksumAlgorithm.crc32.makeHasher()
                var read: Int64 = 0
                do {
                    while true {
                        try await context.checkpoint()
                        let data = try await reader.read(at: read, count: chunk)
                        if data.isEmpty { break }
                        try await file.write(data, at: offset)
                        hasher.update(data)
                        whole.update(data)
                        read += Int64(data.count)
                        offset += Int64(data.count)
                        context.progress(Double(offset) / Double(max(total, 1)), "Part \(n + 1) of \(set.parts.count), \(part.name)")
                    }
                } catch {
                    await reader.close()
                    throw error
                }
                await reader.close()
                if let expected = set.info?.partCRCs[part.name],
                   expected.caseInsensitiveCompare(hasher.finalize()) != .orderedSame {
                    throw SplitProblem.damagedPart(part.name)
                }
                context.items(done: n + 1, total: set.parts.count)
            }
            let crc = whole.finalize().uppercased()
            if let info = set.info {
                if let size = info.size, size != offset { throw SplitProblem.wrongResult("it has \(offset) bytes instead of \(size)") }
                if let expected = info.crc32, expected.caseInsensitiveCompare(crc) != .orderedSame {
                    throw SplitProblem.wrongResult("its CRC32 is \(crc) instead of \(expected.uppercased())")
                }
            }
            _ = try await file.apply(FileMetadata(permissions: 0o644))
            try await file.synchronize()
            await file.close()
            try await dst.rename(partial, to: destination, replacing: true)
            context.log("Combined \(set.parts.count) parts into \(destination.path), \(offset) bytes, CRC32 \(crc)"
                        + (set.info?.crc32 != nil ? " (matches)" : ""))
        } catch {
            await file.close()
            try? await dst.remove(partial)
            throw error
        }
        context.progress(1, destination.name)
    }
}
