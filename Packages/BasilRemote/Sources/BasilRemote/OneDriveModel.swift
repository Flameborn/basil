import BasilCore
import BasilVFS
import Foundation

/// One item as Microsoft Graph describes it (a driveItem).
struct GraphItem: Decodable, Sendable, Equatable {
    var id: String
    var name: String?
    var size: Int64?
    var file: FileFacet?
    var folder: FolderFacet?
    /// OneNote notebooks and other packages: folders in practice.
    var package: PackageFacet?
    /// A shared item added to the user's OneDrive ("Add shortcut to My files"): the item lives
    /// in another drive.
    var remoteItem: RemoteItem?
    var fileSystemInfo: FileSystemInfo?
    var createdDateTime: String?
    var lastModifiedDateTime: String?
    var eTag: String?
    /// Changes when the content changes (not on renames or date changes).
    var cTag: String?
    var parentReference: ParentReference?
    var webUrl: String?

    struct FileFacet: Decodable, Sendable, Equatable {
        var mimeType: String?
        var hashes: Hashes?
    }

    struct Hashes: Decodable, Sendable, Equatable {
        var quickXorHash: String?
        var sha1Hash: String?
        var sha256Hash: String?
    }

    struct FolderFacet: Decodable, Sendable, Equatable {
        var childCount: Int?
    }

    struct PackageFacet: Decodable, Sendable, Equatable {
        var type: String?
    }

    struct FileSystemInfo: Decodable, Sendable, Equatable {
        var createdDateTime: String?
        var lastModifiedDateTime: String?
    }

    struct ParentReference: Decodable, Sendable, Equatable {
        var driveId: String?
        var id: String?
    }

    struct RemoteItem: Decodable, Sendable, Equatable {
        var id: String
        var name: String?
        var size: Int64?
        var file: FileFacet?
        var folder: FolderFacet?
        var package: PackageFacet?
        var fileSystemInfo: FileSystemInfo?
        var parentReference: ParentReference?
        var webUrl: String?
    }

    /// What Basil asks for with every item.
    static let select = "id,name,size,file,folder,package,remoteItem,fileSystemInfo,createdDateTime,lastModifiedDateTime,eTag,cTag,parentReference,webUrl"

    var isFolderLike: Bool { folder != nil || package != nil }
    /// The date the user sees: the one the file had on the computer it came from, else
    /// OneDrive's own.
    var modified: Date? {
        (fileSystemInfo?.lastModifiedDateTime ?? lastModifiedDateTime).flatMap(DriveDate.parse)
    }
    var created: Date? { (fileSystemInfo?.createdDateTime ?? createdDateTime).flatMap(DriveDate.parse) }
    /// When OneDrive last changed the item (a new upload changes it).
    var serverModified: Date? { lastModifiedDateTime.flatMap(DriveDate.parse) }
}

/// Where a path of a OneDrive connection leads. "/" is the top of the user's own drive
/// ("My files"); shared folders the user added there are links into other drives.
struct OneDriveRef: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case folder
        case file
        /// A shared folder added to My files: listed as a link to a folder, so opening it shows
        /// the folder but deleting or moving it never reaches the folder's files.
        case folderLink
    }

    var kind: Kind
    /// The item itself, in the drive of the folder that lists it: renamed, moved, deleted.
    var ownDrive: String
    var ownID: String
    /// What the item shows (a link's target): listed, read, copied.
    var contentDrive: String
    var contentID: String
    /// The top of the user's drive: cannot be renamed or deleted.
    var isRoot = false
    /// The item's metadata when it was listed (the target's for a link).
    var content: GraphItem?
    var name: String?

    var isFolderLike: Bool { kind != .file }
    var isLink: Bool { ownID != contentID || ownDrive != contentDrive }

    /// The reference of a listed item; `drive` is the drive of the folder listing it.
    static func of(_ item: GraphItem, drive: String) -> OneDriveRef {
        let own = item.parentReference?.driveId ?? drive
        if let remote = item.remoteItem {
            let target = GraphItem(id: remote.id, name: remote.name ?? item.name, size: remote.size, file: remote.file,
                                   folder: remote.folder, package: remote.package,
                                   fileSystemInfo: remote.fileSystemInfo ?? item.fileSystemInfo,
                                   createdDateTime: item.createdDateTime, lastModifiedDateTime: item.lastModifiedDateTime,
                                   eTag: item.eTag, cTag: item.cTag, parentReference: remote.parentReference,
                                   webUrl: remote.webUrl ?? item.webUrl)
            let folderLike = remote.folder != nil || remote.package != nil
            return OneDriveRef(kind: folderLike ? .folderLink : .file, ownDrive: own, ownID: item.id,
                               contentDrive: remote.parentReference?.driveId ?? own, contentID: remote.id,
                               content: target, name: item.name)
        }
        return OneDriveRef(kind: item.isFolderLike ? .folder : .file, ownDrive: own, ownID: item.id,
                           contentDrive: own, contentID: item.id, content: item, name: item.name)
    }
}

/// An error answer of Microsoft Graph: {"error": {"code": "itemNotFound", "message": "..."}}.
struct GraphProblem: Sendable {
    var status: Int
    var code: String
    var message: String

    init(_ response: HTTPResponse) {
        status = response.status
        let json = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
        let error = json?["error"] as? [String: Any]
        code = error?["code"] as? String ?? ""
        let text = error?["message"] as? String ?? ""
        message = text.isEmpty
            ? "HTTP \(response.status) \(HTTPURLResponse.localizedString(forStatusCode: response.status))"
            : text
    }
}

/// Graph's path segments: every character but the unreserved ones percent-encoded.
enum GraphPath {
    static func encode(_ name: String) -> String {
        var allowed = CharacterSet()
        allowed.insert(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
    }

    /// A name with characters OneDrive refuses (Windows' forbidden characters); OneDrive's own
    /// answer covers the rest.
    static func problem(with name: String) -> String? {
        if name.rangeOfCharacter(from: CharacterSet(charactersIn: "\"*:<>?/\\|")) != nil {
            return "OneDrive does not allow the characters \" * : < > ? \\ | in names"
        }
        return nil
    }
}

/// QuickXorHash, OneDrive's content hash: every byte is XORed into a 160-bit value at a bit
/// position that moves on by 11 for each byte (wrapping around at 160), then the length is
/// XORed into the last 8 bytes; the 20 bytes are given in Base64.
///
/// The position of byte k depends only on k mod 160, so the bytes are first XORed into 160
/// lanes (8 bytes at a time) and spread out once at the end.
struct QuickXorHash: Sendable {
    private var lanes = [UInt8](repeating: 0, count: 160)
    private(set) var length: UInt64 = 0

    mutating func update(_ data: Data) {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var count = raw.count
            lanes.withUnsafeMutableBufferPointer { lanes in
                var lane = Int(length % 160)
                // Up to the start of a 160-byte block.
                while count > 0, lane != 0 {
                    lanes[lane] ^= pointer.pointee
                    pointer += 1
                    count -= 1
                    lane = (lane + 1) % 160
                }
                // Whole blocks, as 20 words.
                let base = UnsafeMutableRawPointer(lanes.baseAddress!)
                while count >= 160 {
                    let source = UnsafeRawPointer(pointer)
                    for word in 0..<20 {
                        let value = source.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self)
                        let current = base.loadUnaligned(fromByteOffset: word * 8, as: UInt64.self)
                        base.storeBytes(of: current ^ value, toByteOffset: word * 8, as: UInt64.self)
                    }
                    pointer += 160
                    count -= 160
                }
                while count > 0 {
                    lanes[lane] ^= pointer.pointee
                    pointer += 1
                    count -= 1
                    lane += 1
                }
            }
        }
        length += UInt64(data.count)
    }

    /// The 20 bytes of the hash.
    var digest: [UInt8] {
        var result = [UInt8](repeating: 0, count: 20)
        for lane in 0..<160 where lanes[lane] != 0 {
            let bit = (lane * 11) % 160
            let value = UInt16(lanes[lane]) << (bit % 8)
            result[bit / 8] ^= UInt8(value & 0xff)
            result[(bit / 8 + 1) % 20] ^= UInt8(value >> 8)
        }
        for index in 0..<8 { result[12 + index] ^= UInt8((length >> (8 * UInt64(index))) & 0xff) }
        return result
    }

    var base64: String { Data(digest).base64EncodedString() }
}
