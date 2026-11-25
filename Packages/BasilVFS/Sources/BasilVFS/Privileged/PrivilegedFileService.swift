import BasilCore
import Foundation

/// The helper's side of one connection: runs each request on `LocalProvider` and keeps the files
/// it opened. Nothing but `authorize` is answered until `authorize` has succeeded; `authorizer`
/// is the check (the helper's asks macOS for the administrator password, tests allow at once).
/// Closing the connection closes its files (`closeAll`).
public actor PrivilegedFileService {
    public typealias Authorizer = @Sendable (_ authorization: Data, _ prompt: String) async throws -> Void

    private let local = LocalProvider()
    private let authorizer: Authorizer
    private var authorized = false
    private var files: [UInt64: any ReadableFile] = [:]
    private var writable: [UInt64: any WritableFile] = [:]
    private var nextHandle: UInt64 = 1

    public init(authorizer: @escaping Authorizer) {
        self.authorizer = authorizer
    }

    /// Encoded request in, encoded reply out (the XPC form).
    public func handle(_ data: Data) async -> Data {
        let reply: PrivilegedReply
        do {
            reply = await handle(try PrivilegedCoding.decode(PrivilegedRequest.self, from: data))
        } catch {
            reply = .failure(.failed("Bad request: \(error.localizedDescription)"))
        }
        return (try? PrivilegedCoding.encode(reply)) ?? Data()
    }

    public func handle(_ request: PrivilegedRequest) async -> PrivilegedReply {
        do {
            if case .authorize(let authorization, let prompt) = request {
                try await authorizer(authorization, prompt)
                authorized = true
                return .done
            }
            guard authorized else { return .failure(.notAuthorized) }
            return try await perform(request)
        } catch {
            return .failure(WireError(error))
        }
    }

    public func closeAll() async {
        for file in files.values { await file.close() }
        for file in writable.values { await file.close() }
        files = [:]
        writable = [:]
    }

    private func perform(_ request: PrivilegedRequest) async throws -> PrivilegedReply {
        switch request {
        case .authorize:
            return .done
        case .list(let path):
            var items: [WireItem] = []
            for try await batch in local.list(.local(path)) { items += batch.map(WireItem.init) }
            return .items(items)
        case .item(let path):
            return .item(WireItem(try await local.item(at: .local(path))))
        case .fingerprint(let path):
            return .fingerprint(WireFingerprint(try await local.fingerprint(of: .local(path))))
        case .metadata(let path):
            return .metadata(WireMetadata(try await local.metadata(of: .local(path))))
        case .applyMetadata(let metadata, let path):
            return .warnings(try await local.applyMetadata(metadata.metadata, to: .local(path)))
        case .volumeIdentifier(let path):
            return .text(try await local.volumeIdentifier(of: .local(path)))
        case .openForReading(let path, let bypassCache):
            let file = try await local.openForReading(.local(path), bypassCache: bypassCache)
            return .handle(keep(file))
        case .read(let handle, let offset, let count):
            guard let file = files[handle] else { throw WireError.failed("The file is no longer open") }
            return .data(try await file.read(at: offset, count: count))
        case .createFile(let path):
            let file = try await local.createFile(.local(path))
            let handle = keep(nil)
            writable[handle] = file
            return .handle(handle)
        case .write(let handle, let data, let offset):
            try await written(handle).write(data, at: offset)
            return .done
        case .truncate(let handle, let length):
            try await written(handle).truncate(to: length)
            return .done
        case .synchronizeFile(let handle):
            try await written(handle).synchronize()
            return .done
        case .applyToFile(let handle, let metadata):
            return .warnings(try await written(handle).apply(metadata.metadata))
        case .close(let handle):
            if let file = files.removeValue(forKey: handle) { await file.close() }
            if let file = writable.removeValue(forKey: handle) { await file.close() }
            return .done
        case .rename(let from, let to, let replacing):
            try await local.rename(.local(from), to: .local(to), replacing: replacing)
            return .done
        case .clone(let from, let to):
            try await local.clone(.local(from), to: .local(to))
            return .done
        case .remove(let path):
            try await local.remove(.local(path))
            return .done
        case .makeDirectory(let path):
            try await local.makeDirectory(.local(path))
            return .done
        case .synchronize(let path):
            try await local.synchronize(.local(path))
            return .done
        case .readSymlink(let path):
            return .text(try await local.readSymlink(.local(path)))
        case .createSymlink(let path, let target):
            try await local.createSymlink(.local(path), target: target)
            return .done
        }
    }

    private func keep(_ file: (any ReadableFile)?) -> UInt64 {
        let handle = nextHandle
        nextHandle += 1
        if let file { files[handle] = file }
        return handle
    }

    private func written(_ handle: UInt64) throws -> any WritableFile {
        guard let file = writable[handle] else { throw WireError.failed("The file is no longer open") }
        return file
    }
}
