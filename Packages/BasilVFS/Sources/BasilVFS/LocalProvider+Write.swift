import BasilCore
import Darwin
import Dispatch
import Foundation
import Synchronization

/// Blocking file I/O runs here, never on the cooperative thread pool.
enum LocalIO {
    static let queue = DispatchQueue(label: "basil.local.io", qos: .userInitiated, attributes: .concurrent)

    static func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}

extension LocalProvider: WritableProvider {
    public func fingerprint(of path: VFSPath) async throws -> FileFingerprint {
        try await LocalIO.run { try Self.fingerprintSync(path) }
    }

    static func fingerprintSync(_ path: VFSPath) throws -> FileFingerprint {
        var st = Darwin.stat()
        guard lstat(path.path, &st) == 0 else { throw posixError(errno, path) }
        return FileFingerprint(st)
    }

    public func metadata(of path: VFSPath) async throws -> FileMetadata {
        try await LocalIO.run {
            var st = Darwin.stat()
            guard lstat(path.path, &st) == 0 else { throw Self.posixError(errno, path) }
            return FileMetadata(
                permissions: UInt16(st.st_mode & 0o7777),
                modified: st.st_mtimespec,
                created: st.st_birthtimespec,
                accessed: st.st_atimespec,
                flags: st.st_flags,
                extendedAttributes: try XAttr.readAll(path),
                acl: XAttr.readACL(path.path)
            )
        }
    }

    public func applyMetadata(_ metadata: FileMetadata, to path: VFSPath) async throws -> [String] {
        try await LocalIO.run {
            var warnings: [String] = []
            let p = path.path
            for attr in metadata.extendedAttributes {
                let r = attr.value.withUnsafeBytes { setxattr(p, attr.name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
                if r != 0 { warnings.append("Could not set extended attribute \(attr.name): \(String(cString: strerror(errno)))") }
            }
            if let acl = metadata.acl, !XAttr.applyACL(acl, link: p) {
                warnings.append("Could not set access control list: \(String(cString: strerror(errno)))")
            }
            if let mode = metadata.permissions, lchmod(p, mode_t(mode)) != 0 {
                warnings.append("Could not set permissions: \(String(cString: strerror(errno)))")
            }
            if !Times.set(metadata, path: p) {
                warnings.append("Could not set dates: \(String(cString: strerror(errno)))")
            }
            if let flags = metadata.flags, flags != 0, lchflags(p, flags) != 0 {
                warnings.append("Could not set file flags: \(String(cString: strerror(errno)))")
            }
            return warnings
        }
    }

    public func volumeIdentifier(of path: VFSPath) async throws -> String? {
        try await LocalIO.run {
            var st = Darwin.stat()
            guard lstat(path.path, &st) == 0 else { throw Self.posixError(errno, path) }
            return "dev:\(st.st_dev)"
        }
    }

    public func openForReading(_ path: VFSPath, bypassCache: Bool) async throws -> any ReadableFile {
        try await LocalIO.run {
            let fd = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw Self.posixError(errno, path) }
            if bypassCache { _ = fcntl(fd, F_NOCACHE, 1) }
            return LocalFile(fd: fd, path: path)
        }
    }

    public func createFile(_ path: VFSPath) async throws -> any WritableFile {
        try await LocalIO.run {
            let fd = open(path.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw Self.writeError(errno, path) }
            return LocalFile(fd: fd, path: path)
        }
    }

    public func rename(_ from: VFSPath, to: VFSPath, replacing: Bool) async throws {
        try await LocalIO.run {
            guard renamex_np(from.path, to.path, replacing ? 0 : UInt32(RENAME_EXCL)) == 0 else {
                var code = errno
                if code == EXDEV { throw VFSError.unsupported("rename across volumes") }
                // smbfs, msdos and exfat have no exclusive rename: check the target first, then
                // rename. A target made in between is replaced, which these volumes cannot prevent.
                if !replacing, code == ENOTSUP || code == EINVAL {
                    var target = Darwin.stat(), source = Darwin.stat()
                    if lstat(to.path, &target) == 0 {
                        // The same item under another case (case-insensitive volume) may be renamed.
                        guard lstat(from.path, &source) == 0, source.st_dev == target.st_dev,
                              source.st_ino == target.st_ino else { throw VFSError.alreadyExists(to) }
                    }
                    if Darwin.rename(from.path, to.path) == 0 { return }
                    code = errno
                }
                throw Self.writeError(code, code == EEXIST ? to : from)
            }
        }
    }

    public func clone(_ from: VFSPath, to: VFSPath) async throws {
        try await LocalIO.run {
            guard clonefile(from.path, to.path, UInt32(CLONE_NOFOLLOW)) == 0 else {
                let code = errno
                if code == ENOTSUP || code == EXDEV { throw VFSError.unsupported("clone on this volume") }
                throw Self.writeError(code, code == EEXIST ? to : from)
            }
        }
    }

    public func remove(_ path: VFSPath) async throws {
        try await LocalIO.run {
            var st = Darwin.stat()
            guard lstat(path.path, &st) == 0 else { throw Self.posixError(errno, path) }
            let r = (st.st_mode & S_IFMT) == S_IFDIR ? rmdir(path.path) : unlink(path.path)
            guard r == 0 else { throw Self.writeError(errno, path) }
        }
    }

    public func trash(_ path: VFSPath) async throws {
        try await LocalIO.run {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path.path), resultingItemURL: nil)
            } catch let error as CocoaError where error.code == .fileNoSuchFile {
                throw VFSError.notFound(path)
            } catch let error as CocoaError where error.code == .fileWriteNoPermission {
                throw VFSError.permissionDenied(path)
            }
        }
    }

    public func makeDirectory(_ path: VFSPath) async throws {
        try await LocalIO.run {
            guard mkdir(path.path, 0o755) == 0 else { throw Self.writeError(errno, path) }
        }
    }

    public func synchronize(_ path: VFSPath) async throws {
        try await LocalIO.run {
            let fd = open(path.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
            guard fd >= 0 else { throw Self.posixError(errno, path) }
            defer { Darwin.close(fd) }
            if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw Self.posixError(errno, path) }
        }
    }

    public func readSymlink(_ path: VFSPath) async throws -> String {
        try await LocalIO.run {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlink(path.path, &buffer, Int(PATH_MAX))
            guard n >= 0 else { throw Self.posixError(errno, path) }
            return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }

    public func createSymlink(_ path: VFSPath, target: String) async throws {
        try await LocalIO.run {
            guard symlink(target, path.path) == 0 else { throw Self.writeError(errno, path) }
        }
    }

    static func writeError(_ code: Int32, _ path: VFSPath) -> VFSError {
        switch code {
        case EEXIST: .alreadyExists(path)
        case ENOTEMPTY: .directoryNotEmpty(path)
        default: posixError(code, path)
        }
    }
}

extension FileFingerprint {
    init(_ st: Darwin.stat) {
        let kind: Kind = switch st.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symlink
        default: .other
        }
        func nanos(_ ts: timespec) -> Int64 { Int64(ts.tv_sec) * 1_000_000_000 + Int64(ts.tv_nsec) }
        self.init(kind: kind, size: Int64(st.st_size), modifiedNanos: nanos(st.st_mtimespec),
                  changedNanos: nanos(st.st_ctimespec), fileID: UInt64(st.st_ino), device: Int64(st.st_dev))
    }
}

/// An open local file. pread/pwrite at explicit offsets are safe from several threads at once.
final class LocalFile: ReadableFile, WritableFile {
    let fd: Int32
    let path: VFSPath
    private let closed = Atomic<Bool>(false)

    init(fd: Int32, path: VFSPath) {
        self.fd = fd
        self.path = path
    }

    deinit {
        if !closed.load(ordering: .relaxed) { Darwin.close(fd) }
    }

    func read(at offset: Int64, count: Int) async throws -> Data {
        let fd = fd, path = path
        return try await LocalIO.run {
            guard count > 0 else { return Data() }
            let buffer = malloc(count)!
            var done = 0
            while done < count {
                let n = pread(fd, buffer + done, count - done, off_t(offset) + off_t(done))
                if n < 0 {
                    if errno == EINTR { continue }
                    let code = errno
                    free(buffer)
                    throw LocalProvider.posixError(code, path)
                }
                if n == 0 { break }
                done += n
            }
            return Data(bytesNoCopy: buffer, count: done, deallocator: .free)
        }
    }

    func write(_ data: Data, at offset: Int64) async throws {
        let fd = fd, path = path
        try await LocalIO.run {
            try data.withUnsafeBytes { raw in
                var done = 0
                while done < raw.count {
                    let n = pwrite(fd, raw.baseAddress! + done, raw.count - done, off_t(offset) + off_t(done))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw LocalProvider.posixError(errno, path)
                    }
                    done += n
                }
            }
        }
    }

    func truncate(to length: Int64) async throws {
        let fd = fd, path = path
        try await LocalIO.run {
            guard ftruncate(fd, off_t(length)) == 0 else { throw LocalProvider.posixError(errno, path) }
        }
    }

    func synchronize() async throws {
        let fd = fd, path = path
        try await LocalIO.run {
            // F_FULLFSYNC asks the drive to flush its cache too; fall back to fsync where unsupported.
            if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw LocalProvider.posixError(errno, path) }
        }
    }

    func apply(_ metadata: FileMetadata) async throws -> [String] {
        let fd = fd
        return try await LocalIO.run {
            var warnings: [String] = []
            for attr in metadata.extendedAttributes {
                let r = attr.value.withUnsafeBytes { fsetxattr(fd, attr.name, $0.baseAddress, $0.count, 0, 0) }
                if r != 0 { warnings.append("Could not set extended attribute \(attr.name): \(String(cString: strerror(errno)))") }
            }
            if let acl = metadata.acl, !XAttr.applyACL(acl, fd: fd) {
                warnings.append("Could not set access control list: \(String(cString: strerror(errno)))")
            }
            if let mode = metadata.permissions, fchmod(fd, mode_t(mode)) != 0 {
                warnings.append("Could not set permissions: \(String(cString: strerror(errno)))")
            }
            if !Times.set(metadata, fd: fd) {
                warnings.append("Could not set dates: \(String(cString: strerror(errno)))")
            }
            return warnings
        }
    }

    func close() async {
        if !closed.exchange(true, ordering: .relaxed) { Darwin.close(fd) }
    }
}

enum XAttr {
    static func readAll(_ path: VFSPath) throws -> [FileMetadata.ExtendedAttribute] {
        let p = path.path
        let size = listxattr(p, nil, 0, XATTR_NOFOLLOW)
        if size < 0 { throw LocalProvider.posixError(errno, path) }
        if size == 0 { return [] }
        var names = [CChar](repeating: 0, count: size)
        let got = listxattr(p, &names, size, XATTR_NOFOLLOW)
        if got < 0 { throw LocalProvider.posixError(errno, path) }
        var result: [FileMetadata.ExtendedAttribute] = []
        var start = 0
        for i in 0..<got where names[i] == 0 {
            let name = String(decoding: names[start..<i].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            start = i + 1
            let length = getxattr(p, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard length >= 0 else { continue } // removed meanwhile
            var value = Data(count: length)
            let read = value.withUnsafeMutableBytes { getxattr(p, name, $0.baseAddress, length, 0, XATTR_NOFOLLOW) }
            guard read >= 0 else { continue }
            value.count = read
            result.append(.init(name: name, value: value))
        }
        return result
    }

    static func readACL(_ path: String) -> String? {
        guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else { return nil }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard let text = acl_to_text(acl, nil) else { return nil }
        defer { acl_free(text) }
        return String(cString: text)
    }

    static func applyACL(_ text: String, fd: Int32) -> Bool {
        guard let acl = acl_from_text(text) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return acl_set_fd_np(fd, acl, ACL_TYPE_EXTENDED) == 0
    }

    static func applyACL(_ text: String, link path: String) -> Bool {
        guard let acl = acl_from_text(text) else { return false }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        return acl_set_link_np(path, ACL_TYPE_EXTENDED, acl) == 0
    }
}

/// Sets creation, modification and access dates with setattrlist (which can set the creation date).
enum Times {
    private static func build(_ m: FileMetadata) -> (attrlist, [timespec])? {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        var values: [timespec] = []
        // Values must follow attribute bit order: CRTIME, MODTIME, ACCTIME.
        if let c = m.created { list.commonattr |= attrgroup_t(ATTR_CMN_CRTIME); values.append(c) }
        if let mod = m.modified { list.commonattr |= attrgroup_t(ATTR_CMN_MODTIME); values.append(mod) }
        if let a = m.accessed { list.commonattr |= attrgroup_t(ATTR_CMN_ACCTIME); values.append(a) }
        return values.isEmpty ? nil : (list, values)
    }

    static func set(_ m: FileMetadata, path: String) -> Bool {
        guard var (list, values) = build(m) else { return true }
        return values.withUnsafeMutableBytes {
            setattrlist(path, &list, $0.baseAddress, $0.count, UInt32(FSOPT_NOFOLLOW)) == 0
        }
    }

    static func set(_ m: FileMetadata, fd: Int32) -> Bool {
        guard var (list, values) = build(m) else { return true }
        return values.withUnsafeMutableBytes { fsetattrlist(fd, &list, $0.baseAddress, $0.count, 0) == 0 }
    }
}
