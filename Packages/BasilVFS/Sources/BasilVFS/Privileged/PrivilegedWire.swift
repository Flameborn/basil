import BasilCore
import Darwin
import Foundation

// What Basil and its administrator helper (BasilHelper, a launchd daemon running as root) say to
// each other. Every request is one call of `LocalProvider` run by the helper; paths are plain
// local paths. The messages are property lists (binary), so file data travels as raw bytes.

/// The provider ID of `PrivilegedLocalProvider`: the local disk, reached through the helper.
extension ProviderID {
    public static let localAdministrator = ProviderID("local-admin")
}

extension ProviderLocation {
    public static let localAdministrator = ProviderLocation(provider: .localAdministrator)
}

/// One call to the helper.
public enum PrivilegedRequest: Codable, Sendable {
    /// Asks the user for an administrator password through macOS (the helper shows it), with
    /// `prompt` as the reason. `authorization` is the external form of an empty AuthorizationRef
    /// made by Basil, so the dialog belongs to the user's session. Must succeed before anything
    /// else on a connection.
    case authorize(authorization: Data, prompt: String)
    case list(String)
    case item(String)
    case fingerprint(String)
    case metadata(String)
    case applyMetadata(WireMetadata, String)
    case volumeIdentifier(String)
    case openForReading(String, bypassCache: Bool)
    case read(UInt64, offset: Int64, count: Int)
    case createFile(String)
    case write(UInt64, Data, offset: Int64)
    case truncate(UInt64, length: Int64)
    case synchronizeFile(UInt64)
    case applyToFile(UInt64, WireMetadata)
    case close(UInt64)
    case rename(String, String, replacing: Bool)
    case clone(String, String)
    case remove(String)
    case makeDirectory(String)
    case synchronize(String)
    case readSymlink(String)
    case createSymlink(String, target: String)
    /// Moves an item into `folder` (the user's Trash on its volume) under a free name, making
    /// the folder (mode 700, owned by `owner`) when it is missing. Returns the new path.
    case trash(String, into: String, owner: UInt32)
    /// Removes a file, link or folder with everything in it (links are not followed).
    case removeTree(String)
}

public enum PrivilegedReply: Codable, Sendable {
    case done
    case items([WireItem])
    case item(WireItem)
    case fingerprint(WireFingerprint)
    case metadata(WireMetadata)
    case warnings([String])
    case text(String?)
    case handle(UInt64)
    case data(Data)
    case failure(WireError)
}

/// `FileItem` on the wire (its path as a plain local path).
public struct WireItem: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case file, directory, linkToFile, linkToDirectory, brokenLink, link, other
    }

    var path: String
    var kind: Kind
    var size: Int64?
    var modified: Date?
    var created: Date?
    var permissions: UInt16?
    var isHidden: Bool
    var fileID: UInt64?

    init(_ item: FileItem) {
        path = item.path.path
        kind = switch item.kind {
        case .file: .file
        case .directory: .directory
        case .symlink(target: .file): .linkToFile
        case .symlink(target: .directory): .linkToDirectory
        case .symlink(target: .broken): .brokenLink
        case .symlink(target: .unknown): .link
        case .other: .other
        }
        size = item.size
        modified = item.modified
        created = item.created
        permissions = item.permissions
        isHidden = item.isHidden
        fileID = item.fileID
    }

    func item(in location: ProviderLocation) -> FileItem {
        let kind: FileItem.Kind = switch kind {
        case .file: .file
        case .directory: .directory
        case .linkToFile: .symlink(target: .file)
        case .linkToDirectory: .symlink(target: .directory)
        case .brokenLink: .symlink(target: .broken)
        case .link: .symlink(target: .unknown)
        case .other: .other
        }
        return FileItem(path: VFSPath(location: location, path: path), kind: kind, size: size, modified: modified,
                        created: created, permissions: permissions, isHidden: isHidden, fileID: fileID)
    }
}

public struct WireFingerprint: Codable, Sendable {
    var kind: String
    var size: Int64
    var modifiedNanos: Int64?
    var changedNanos: Int64?
    var fileID: UInt64?
    var device: Int64?

    init(_ f: FileFingerprint) {
        kind = switch f.kind {
        case .file: "file"
        case .directory: "directory"
        case .symlink: "symlink"
        case .other: "other"
        }
        size = f.size
        modifiedNanos = f.modifiedNanos
        changedNanos = f.changedNanos
        fileID = f.fileID
        device = f.device
    }

    var fingerprint: FileFingerprint {
        let k: FileFingerprint.Kind = switch kind {
        case "file": .file
        case "directory": .directory
        case "symlink": .symlink
        default: .other
        }
        return FileFingerprint(kind: k, size: size, modifiedNanos: modifiedNanos, changedNanos: changedNanos,
                               fileID: fileID, device: device)
    }
}

public struct WireMetadata: Codable, Sendable {
    struct Time: Codable, Sendable {
        var seconds: Int
        var nanoseconds: Int
        init(_ t: timespec) { seconds = t.tv_sec; nanoseconds = t.tv_nsec }
        var timespec: Darwin.timespec { Darwin.timespec(tv_sec: seconds, tv_nsec: nanoseconds) }
    }

    struct Attribute: Codable, Sendable {
        var name: String
        var value: Data
    }

    var permissions: UInt16?
    var modified: Time?
    var created: Time?
    var accessed: Time?
    var flags: UInt32?
    var attributes: [Attribute]
    var acl: String?

    init(_ m: FileMetadata) {
        permissions = m.permissions
        modified = m.modified.map(Time.init)
        created = m.created.map(Time.init)
        accessed = m.accessed.map(Time.init)
        flags = m.flags
        attributes = m.extendedAttributes.map { Attribute(name: $0.name, value: $0.value) }
        acl = m.acl
    }

    var metadata: FileMetadata {
        FileMetadata(permissions: permissions, modified: modified?.timespec, created: created?.timespec,
                     accessed: accessed?.timespec, flags: flags,
                     extendedAttributes: attributes.map { .init(name: $0.name, value: $0.value) }, acl: acl)
    }
}

/// `VFSError` on the wire, plus the helper's own refusals.
public enum WireError: Codable, Sendable, Error {
    case notFound(String)
    case notADirectory(String)
    case permissionDenied(String)
    case posix(code: Int32, path: String)
    case alreadyExists(String)
    case directoryNotEmpty(String)
    case unsupported(String)
    case failed(String)
    /// The user cancelled the password dialog.
    case declined
    /// A request other than `authorize` on a connection that is not authorized.
    case notAuthorized

    init(_ error: any Error) {
        switch error {
        case let e as WireError: self = e
        case let e as VFSError:
            self = switch e {
            case .notFound(let p): .notFound(p.path)
            case .notADirectory(let p): .notADirectory(p.path)
            case .permissionDenied(let p): .permissionDenied(p.path)
            case .noProvider(let l): .failed("No provider for \(l.provider)")
            case .posix(let code, let p): .posix(code: code, path: p.path)
            case .alreadyExists(let p): .alreadyExists(p.path)
            case .directoryNotEmpty(let p): .directoryNotEmpty(p.path)
            case .unsupported(let what): .unsupported(what)
            case .failed(let message): .failed(message)
            }
        default:
            self = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    /// The error the copy engine and the operations understand. Paths are local paths: that
    /// is what they name, and how the queue log shows them.
    var vfsError: any Error {
        switch self {
        case .notFound(let p): VFSError.notFound(.local(p))
        case .notADirectory(let p): VFSError.notADirectory(.local(p))
        case .permissionDenied(let p): VFSError.permissionDenied(.local(p))
        case .posix(let code, let p): VFSError.posix(code: code, path: .local(p))
        case .alreadyExists(let p): VFSError.alreadyExists(.local(p))
        case .directoryNotEmpty(let p): VFSError.directoryNotEmpty(.local(p))
        case .unsupported(let what): VFSError.unsupported(what)
        case .failed(let message): VFSError.failed(message)
        case .declined: PrivilegedAccessDeclined()
        case .notAuthorized: VFSError.failed("The administrator helper refused: not authorized")
        }
    }
}

/// The administrator password dialog was cancelled.
public struct PrivilegedAccessDeclined: Error, Sendable {
    public init() {}
}

enum PrivilegedCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try PropertyListDecoder().decode(type, from: data)
    }
}
