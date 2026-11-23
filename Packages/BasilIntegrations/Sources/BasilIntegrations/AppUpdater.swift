import CryptoKit
import Darwin
import Foundation
import Security

// Basil's own updater: the newest GitHub release of the repository, its DMG (made by
// scripts/release.sh), checked by size, by GitHub's SHA-256 digest of the asset and by the
// code signature of the app inside, which must satisfy the running app's designated
// requirement (same identifier, same signing certificate). The new app is copied next to
// the installed one and swapped in with one atomic rename.

/// A version like "0.2.1" (a leading "v" is ignored). Compared part by part, missing parts are 0.
public struct AppVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        var text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        let pieces = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !pieces.isEmpty else { return nil }
        var parts: [Int] = []
        for piece in pieces {
            guard !piece.isEmpty, piece.allSatisfy(\.isASCII), let number = Int(piece), number >= 0 else { return nil }
            parts.append(number)
        }
        self.parts = parts
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: AppVersion, b: AppVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: AppVersion, b: AppVersion) -> Bool { !(a < b) && !(b < a) }

    public func hash(into hasher: inout Hasher) {
        var trimmed = parts
        while trimmed.last == 0 { trimmed.removeLast() }
        hasher.combine(trimmed)
    }

    /// The running app's CFBundleShortVersionString.
    public static var running: AppVersion? {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String).flatMap(AppVersion.init)
    }
}

/// A release that has a DMG to install.
public struct AvailableUpdate: Sendable, Equatable {
    public var version: AppVersion
    /// The release's title ("Basil 0.2.0").
    public var title: String
    /// The release notes (the changelog entries, Markdown).
    public var notes: String
    /// The release's page on GitHub.
    public var page: URL?
    public var dmg: URL
    public var dmgName: String
    public var dmgSize: Int
    /// The asset's SHA-256 as GitHub reports it (lowercase hex), when it does.
    public var sha256: String?

    public init(version: AppVersion, title: String, notes: String, page: URL?, dmg: URL, dmgName: String,
                dmgSize: Int, sha256: String?) {
        self.version = version
        self.title = title
        self.notes = notes
        self.page = page
        self.dmg = dmg
        self.dmgName = dmgName
        self.dmgSize = dmgSize
        self.sha256 = sha256
    }

    /// Release notes as plain text: Markdown list markers and headings become words and lines.
    public var plainNotes: String {
        notes.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var line = String(line)
                while line.hasPrefix("#") { line.removeFirst() }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") { return String(trimmed.dropFirst(2)) }
                return trimmed
            }
            .joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum UpdateError: Error, LocalizedError, Equatable {
    case server(Int)
    case badAnswer
    case sizeMismatch(expected: Int, got: Int)
    case digestMismatch
    case mountFailed(String)
    case noApp
    case wrongApp(String)
    case signature(String)
    case notWritable(String)
    case installFailed(String)

    public var errorDescription: String? {
        switch self {
        case .server(let status): "GitHub answered with status \(status)."
        case .badAnswer: "GitHub's answer could not be read."
        case .sizeMismatch(let expected, let got): "The download has \(got) bytes instead of \(expected)."
        case .digestMismatch: "The download does not match GitHub's checksum."
        case .mountFailed(let reason): "The disk image could not be opened: \(reason)"
        case .noApp: "The disk image holds no Basil.app."
        case .wrongApp(let reason): "The disk image holds a different app: \(reason)"
        case .signature(let reason): "The new app is not signed like this one, so it was not installed. \(reason)"
        case .notWritable(let folder): "Basil can't write to \(folder). Install the update from the DMG by hand."
        case .installFailed(let reason): "The new version could not be put in place: \(reason)"
        }
    }
}

/// Where releases are looked up: GitHub's REST API for one repository.
public struct UpdateFeed: Sendable {
    public var owner: String
    public var repository: String
    /// https://api.github.com, replaceable for tests.
    public var api: URL

    public static let basil = UpdateFeed(owner: "Flameborn", repository: "basil")

    public init(owner: String, repository: String, api: URL = URL(string: "https://api.github.com")!) {
        self.owner = owner
        self.repository = repository
        self.api = api
    }

    /// The latest release (GitHub's "latest": no drafts, no pre-releases).
    public var latestURL: URL {
        api.appendingPathComponent("repos").appendingPathComponent(owner)
            .appendingPathComponent(repository).appendingPathComponent("releases").appendingPathComponent("latest")
    }

    /// The latest release with a DMG, or nil when the repository has none.
    public func latest(session: URLSession = .shared) async throws -> AvailableUpdate? {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Basil-updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil } // no release yet
        guard status == 200 else { throw UpdateError.server(status) }
        return try Self.parse(data)
    }

    /// Reads a release object of GitHub's API. Drafts and pre-releases give nil, so do
    /// releases without a DMG or with a tag that is not a version.
    public static func parse(_ data: Data) throws -> AvailableUpdate? {
        struct Release: Decodable {
            var tag_name: String
            var name: String?
            var body: String?
            var html_url: URL?
            var draft: Bool?
            var prerelease: Bool?
            var assets: [Asset]
        }
        struct Asset: Decodable {
            var name: String
            var browser_download_url: URL
            var size: Int
            var digest: String?
        }
        let release: Release
        do { release = try JSONDecoder().decode(Release.self, from: data) } catch { throw UpdateError.badAnswer }
        guard release.draft != true, release.prerelease != true,
              let version = AppVersion(release.tag_name) else { return nil }
        let dmgs = release.assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        guard let asset = dmgs.first(where: { $0.name == "Basil-\(version).dmg" }) ?? dmgs.first else { return nil }
        var sha256: String?
        if let digest = asset.digest, digest.lowercased().hasPrefix("sha256:") {
            sha256 = String(digest.dropFirst("sha256:".count)).lowercased()
        }
        return AvailableUpdate(version: version, title: release.name ?? "Basil \(version)", notes: release.body ?? "",
                               page: release.html_url, dmg: asset.browser_download_url, dmgName: asset.name,
                               dmgSize: asset.size, sha256: sha256)
    }
}

/// Downloads, checks and installs an update over the installed app.
public struct UpdateInstaller: Sendable {
    /// The app bundle to replace (the running one).
    public var installedApp: URL
    /// Scratch folder for the download and the mounted image.
    public var scratch: URL
    /// The requirement the new app's signature must satisfy, as text. Nil: the running app's
    /// designated requirement.
    public var requirement: String?
    /// The bundle identifier the new app must have.
    public var bundleID: String

    public init(installedApp: URL = Bundle.main.bundleURL,
                scratch: URL = FileManager.default.temporaryDirectory.appendingPathComponent("Basil update", isDirectory: true),
                requirement: String? = nil,
                bundleID: String = Bundle.main.bundleIdentifier ?? "com.flameborn.basil") {
        self.installedApp = installedApp
        self.scratch = scratch
        self.requirement = requirement
        self.bundleID = bundleID
    }

    /// Downloads the DMG into the scratch folder and checks its size and digest.
    /// `progress` gets the fraction done, on any thread.
    public func download(_ update: AvailableUpdate, session: URLSession? = nil,
                         progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> URL {
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let target = scratch.appendingPathComponent(update.dmgName.isEmpty ? "Basil.dmg" : update.dmgName)
        try await Downloader.download(update.dmg, to: target, expectedSize: update.dmgSize,
                                      configuration: session?.configuration, progress: progress)
        try Self.check(target, size: update.dmgSize, sha256: update.sha256)
        return target
    }

    /// The file has `size` bytes and, when given, that SHA-256.
    public static func check(_ file: URL, size: Int, sha256: String?) throws {
        let got = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? -1
        guard got == size else { throw UpdateError.sizeMismatch(expected: size, got: got) }
        guard let sha256 else { return }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard hex == sha256.lowercased() else { throw UpdateError.digestMismatch }
    }

    /// Mounts the DMG, copies its app next to the installed one (a hidden name in the same
    /// folder, so the swap is one rename on one volume), unmounts it, and checks the copy:
    /// bundle identifier, version and signature. Returns the staged copy.
    public func stage(_ dmg: URL, version: AppVersion) throws -> URL {
        let folder = installedApp.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: folder.path) else { throw UpdateError.notWritable(folder.path) }
        let mount = scratch.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = try Self.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen",
                                                       "-mountpoint", mount.path])
        guard attach.status == 0 else { throw UpdateError.mountFailed(attach.output.trimmingCharacters(in: .whitespacesAndNewlines)) }
        defer {
            if (try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]))?.status != 0 {
                _ = try? Self.run("/usr/bin/hdiutil", ["detach", mount.path, "-force", "-quiet"])
            }
            try? FileManager.default.removeItem(at: mount)
        }
        let apps = ((try? FileManager.default.contentsOfDirectory(atPath: mount.path)) ?? [])
            .filter { $0.hasSuffix(".app") }.sorted()
        guard let name = apps.first(where: { $0 == installedApp.lastPathComponent }) ?? apps.first(where: { $0 == "Basil.app" }) ?? apps.first
        else { throw UpdateError.noApp }
        let source = mount.appendingPathComponent(name, isDirectory: true)

        let staged = folder.appendingPathComponent(".Basil-update-\(UUID().uuidString).app", isDirectory: true)
        // ditto keeps signatures, extended attributes and permissions; --noqtn adds no quarantine.
        let copy = try Self.run("/usr/bin/ditto", ["--noqtn", source.path, staged.path])
        guard copy.status == 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError.installFailed(copy.output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        do {
            try verify(staged, version: version)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// The app at `url` has this installer's bundle identifier, the expected version and a valid
    /// signature that satisfies the requirement.
    public func verify(_ url: URL, version: AppVersion) throws {
        guard let bundle = Bundle(url: url), let info = bundle.infoDictionary else { throw UpdateError.noApp }
        let id = info["CFBundleIdentifier"] as? String ?? ""
        guard id == bundleID else { throw UpdateError.wrongApp("identifier \(id), expected \(bundleID)") }
        let shown = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        guard shown == version else {
            throw UpdateError.wrongApp("version \(shown?.description ?? "unknown"), expected \(version)")
        }
        try Self.checkSignature(of: url, requirement: requirement)
    }

    /// Swaps the staged app with the installed one in one rename, then removes the old copy.
    public func install(_ staged: URL) throws {
        let result = staged.path.withCString { from in
            installedApp.path.withCString { to in renamex_np(from, to, UInt32(RENAME_SWAP)) }
        }
        guard result == 0 else {
            let reason = String(cString: strerror(errno))
            try? FileManager.default.removeItem(at: staged)
            throw UpdateError.installFailed(reason)
        }
        // `staged` now holds the old version.
        try? FileManager.default.removeItem(at: staged)
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Signature

    /// Strict validation of the whole bundle (nested code too) against `requirement`, or the
    /// running app's designated requirement when nil.
    public static func checkSignature(of url: URL, requirement text: String?) throws {
        var requirement: SecRequirement?
        if let text {
            guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else {
                throw UpdateError.signature("The requirement could not be read.")
            }
        } else {
            var me: SecCode?
            var mine: SecStaticCode?
            guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
                  SecCodeCopyStaticCode(me, [], &mine) == errSecSuccess, let mine,
                  SecCodeCopyDesignatedRequirement(mine, [], &requirement) == errSecSuccess else {
                throw UpdateError.signature("This copy of Basil has no usable signature.")
            }
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.signature("The new app could not be read.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        var errors: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(code, flags, requirement, &errors)
        guard status == errSecSuccess else {
            let reason = (errors?.takeRetainedValue()).map { CFErrorCopyDescription($0) as String }
                ?? (SecCopyErrorMessageString(status, nil) as String?) ?? "Status \(status)."
            throw UpdateError.signature(reason)
        }
    }

    // MARK: - Relaunch

    /// Starts a shell that waits until this process has quit, then opens `app`. Call it once
    /// quitting is certain (applicationWillTerminate).
    public static func relaunchAfterQuit(_ app: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
                             "sh", String(getpid()), app.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    // MARK: - Tools

    struct RunResult { var status: Int32; var output: String }

    /// Runs a tool and waits, with stdout and stderr together. Blocking: call off the main thread.
    static func run(_ tool: String, _ arguments: [String]) throws -> RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return RunResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// One download to a file with progress, on its own URLSession.
private final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let target: URL
    private let expectedSize: Int
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var moveError: (any Error)?

    private init(target: URL, expectedSize: Int, progress: @escaping @Sendable (Double) -> Void) {
        self.target = target
        self.expectedSize = expectedSize
        self.progress = progress
    }

    static func download(_ url: URL, to target: URL, expectedSize: Int, configuration: URLSessionConfiguration?,
                         progress: @escaping @Sendable (Double) -> Void) async throws {
        let delegate = Downloader(target: target, expectedSize: expectedSize, progress: progress)
        let configuration = configuration ?? .ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("Basil-updater", forHTTPHeaderField: "User-Agent")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                delegate.lock.withLock { delegate.continuation = continuation }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? Double(totalBytesExpectedToWrite) : Double(max(expectedSize, 1))
        progress(min(1, Double(totalBytesWritten) / total))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at `location` is removed once this returns, so it is moved now.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            guard status == 200 else { throw UpdateError.server(status) }
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: location, to: target)
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        if let error = error ?? lock.withLock({ moveError }) {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
