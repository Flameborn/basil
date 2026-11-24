// F4 on a server: the edited local copy goes back over the file it was downloaded from.

import BasilCore
import BasilVFS
import Foundation
import Synchronization

/// Uploads an edited local copy over the server file it came from. When the server's file
/// changed since the download (`downloaded` no longer matches), it asks first
/// (`QueuePrompt.changedOnServer`); declining cancels the item and leaves the server alone.
public struct UploadEditedCopyOperation: QueueOperation {
    /// The local copy that was edited.
    public let copy: VFSPath
    /// The file on the server.
    public let destination: VFSPath
    /// The server file's fingerprint when the copy was downloaded or last uploaded.
    public let downloaded: FileFingerprint?
    /// The connection's name for titles and questions, e.g. "alice@example.com".
    public let server: String
    /// The server file's fingerprint after the upload, for the next check.
    public let result = UploadResult()
    let registry: ProviderRegistry
    let options: SecureCopyOptions

    public init(copy: VFSPath, destination: VFSPath, downloaded: FileFingerprint?, server: String,
                registry: ProviderRegistry, options: SecureCopyOptions) {
        self.copy = copy
        self.destination = destination
        self.downloaded = downloaded
        self.server = server
        self.registry = registry
        var options = options
        options.replaceExisting = true
        self.options = options
    }

    public var kind: OperationKind { .upload }
    public var title: String { "Upload \(destination.name) to \(server)" }

    /// Whether the server's file is not the one that was downloaded. Only what servers report
    /// reliably is compared: kind, size, modification time and the file ID (a revision or ETag
    /// on most services).
    public static func changed(_ then: FileFingerprint, _ now: FileFingerprint) -> Bool {
        then.kind != now.kind || then.size != now.size || then.modifiedNanos != now.modifiedNanos || then.fileID != now.fileID
    }

    public func run(_ context: OperationContext) async throws {
        let dst = try registry.writableProvider(for: destination.location)
        let src = try registry.writableProvider(for: copy.location)
        context.items(done: 0, total: 1)
        context.progress(nil, "Checking \(destination.name)")
        try await context.checkpoint()
        let now = try? await dst.fingerprint(of: destination)
        if let now, now.kind == .directory { throw VFSError.alreadyExists(destination) }
        if let then = downloaded, let now, Self.changed(then, now) {
            context.log("\(destination.path) changed on the server since it was opened (then: \(then), now: \(now))")
            let question = ChangedOnServer(path: destination, server: server, then: then, now: now)
            guard case .changedOnServer(replace: true) = await context.ask(.changedOnServer(question)) else {
                context.log("Not uploaded: the server's version was kept")
                throw CancellationError()
            }
            context.log("Replacing the server's version with the edited copy")
        } else if downloaded != nil, now == nil {
            context.log("\(destination.path) is no longer on the server; uploading it again")
        }

        let size = (try? await src.fingerprint(of: copy).size) ?? 0
        let errors = ItemErrorPolicy(context: context, action: "upload")
        let monitor = QueueTransferMonitor(context: context, registry: registry, totalBytes: size, errors: errors)
        let engine = SecureCopyEngine(registry: registry, options: options, monitor: monitor)
        context.log(options.secure ? "Secure mode" : "Total Commander style mode")
        monitor.setLabel(destination.name)
        var summary = TransferSummary()
        let uploaded = try await errors.run(copy) {
            summary = try await engine.transfer(copy, to: destination, mode: .copy)
        }
        guard uploaded, summary.failed.isEmpty, summary.skipped.isEmpty, summary.files == 1 else {
            throw VFSError.failed("\(destination.name) was not uploaded")
        }
        for p in summary.acceptedUnstable { context.log("Accepted while still changing: \(p.path)") }
        result.set(try? await dst.fingerprint(of: destination))
        context.items(done: 1, total: 1)
        context.progress(1, "\(destination.name) uploaded")
    }
}

/// The server file's fingerprint once an upload has finished.
public final class UploadResult: Sendable {
    private let value = Mutex<FileFingerprint?>(nil)
    public init() {}
    public var fingerprint: FileFingerprint? { value.withLock { $0 } }
    func set(_ fingerprint: FileFingerprint?) { value.withLock { $0 = fingerprint } }
}
