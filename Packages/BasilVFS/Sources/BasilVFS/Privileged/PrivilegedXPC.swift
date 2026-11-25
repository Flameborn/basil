import CryptoKit
import Foundation
import Security
import Synchronization

/// Names shared by Basil and its administrator helper.
public enum BasilHelper {
    /// The launchd label and mach service of the helper (Contents/Library/LaunchDaemons/<label>.plist).
    public static let label = "com.flameborn.basil.helper"
    public static let plistName = "com.flameborn.basil.helper.plist"
    public static let appIdentifier = "com.flameborn.basil"
    /// Basil's own authorization right. `system.privilege.admin` is granted to root processes
    /// without a password (allow-root), so the helper could not tell whether the user agreed.
    public static let rightName = "com.flameborn.basil.helper.files"

    /// What a peer must be: `identifier` signed with the same leaf certificate as this process.
    /// Basil is signed with a stable local identity that may have no team (a self-signed
    /// certificate), so a team check would not work; the certificate's hash does. Nil when this
    /// process has no certificate (ad hoc): then nothing is accepted.
    public static func peerRequirement(identifier: String) -> String? {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let leaf = certificates.first else { return nil }
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        let hex = hash.map { String(format: "%02X", $0) }.joined()
        return "identifier \"\(identifier)\" and certificate leaf = H\"\(hex)\""
    }
}

/// The XPC interface: one encoded `PrivilegedRequest` in, one encoded `PrivilegedReply` out.
@objc public protocol BasilHelperXPC {
    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void)
}

// MARK: Basil's side

/// The connection to the helper. The helper must be signed like Basil (`peerRequirement`).
/// The empty AuthorizationRef whose external form goes with `authorize` is kept until `close`,
/// so the rights the user granted stay valid while the operation runs.
public final class PrivilegedXPCClient: PrivilegedTransport, @unchecked Sendable {
    private let connection: NSXPCConnection
    private let authorization: AuthorizationRef?
    private let state = Mutex(false)

    /// Nil when Basil has no certificate to check the helper against.
    public init?() {
        guard let requirement = BasilHelper.peerRequirement(identifier: BasilHelper.label) else { return nil }
        connection = NSXPCConnection(machServiceName: BasilHelper.label, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: BasilHelperXPC.self)
        connection.setCodeSigningRequirement(requirement)
        var ref: AuthorizationRef?
        authorization = AuthorizationCreate(nil, nil, [], &ref) == errAuthorizationSuccess ? ref : nil
        connection.resume()
    }

    deinit {
        if let authorization { AuthorizationFree(authorization, []) }
    }

    /// The external form of the kept AuthorizationRef, for `PrivilegedRequest.authorize`.
    public var externalAuthorization: Data {
        guard let authorization else { return Data() }
        var form = AuthorizationExternalForm()
        guard AuthorizationMakeExternalForm(authorization, &form) == errAuthorizationSuccess else { return Data() }
        return withUnsafeBytes(of: &form) { Data($0) }
    }

    public func send(_ request: PrivilegedRequest) async throws -> PrivilegedReply {
        let data = try PrivilegedCoding.encode(request)
        let reply: Data = try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce(continuation)
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                once.resume(.failure(VFSError.failed("The administrator helper could not be reached: \(error.localizedDescription)")))
            } as? BasilHelperXPC
            guard let proxy else {
                once.resume(.failure(VFSError.failed("The administrator helper could not be reached")))
                return
            }
            proxy.handle(data) { once.resume(.success($0)) }
        }
        return try PrivilegedCoding.decode(PrivilegedReply.self, from: reply)
    }

    public func close() async {
        guard state.withLock({ closed in defer { closed = true }; return !closed }) else { return }
        connection.invalidate()
    }
}

/// Resumes a continuation once: XPC calls either the reply or the error handler, never both,
/// but nothing is lost by checking.
final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Data, any Error>?>

    init(_ continuation: CheckedContinuation<Data, any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ result: Result<Data, any Error>) {
        continuation.withLock { c in
            c?.resume(with: result)
            c = nil
        }
    }
}

// MARK: The helper's side

/// The helper's listener: accepts connections only from Basil signed like the helper, one
/// `PrivilegedFileService` per connection (its files closed when the connection goes).
/// `onIdle` is called when the last connection has been gone for `idleTime`.
public final class PrivilegedHelperListener: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let clientRequirement: String
    private let connections = Mutex(0)
    private let generation = Mutex(0)
    private let idleTime: Duration
    private let onIdle: @Sendable () -> Void

    public init?(idleTime: Duration = .seconds(120), onIdle: @escaping @Sendable () -> Void) {
        guard let requirement = BasilHelper.peerRequirement(identifier: BasilHelper.appIdentifier) else { return nil }
        listener = NSXPCListener(machServiceName: BasilHelper.label)
        clientRequirement = requirement
        self.idleTime = idleTime
        self.onIdle = onIdle
        super.init()
        listener.delegate = self
    }

    public func resume() {
        listener.resume()
        scheduleIdleCheck()
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.setCodeSigningRequirement(clientRequirement)
        connection.exportedInterface = NSXPCInterface(with: BasilHelperXPC.self)
        let service = PrivilegedFileService(authorizer: HelperAuthorization.check)
        connection.exportedObject = HelperConnection(service: service)
        connections.withLock { $0 += 1 }
        connection.invalidationHandler = { [weak self] in
            Task { await service.closeAll() }
            self?.connections.withLock { $0 -= 1 }
            self?.scheduleIdleCheck()
        }
        connection.resume()
        return true
    }

    private func scheduleIdleCheck() {
        let mine = generation.withLock { $0 += 1; return $0 }
        Task { [weak self, idleTime] in
            try? await Task.sleep(for: idleTime)
            guard let self, generation.withLock({ $0 }) == mine, connections.withLock({ $0 }) == 0 else { return }
            onIdle()
        }
    }
}

final class HelperConnection: NSObject, BasilHelperXPC, @unchecked Sendable {
    let service: PrivilegedFileService

    init(service: PrivilegedFileService) {
        self.service = service
    }

    func handle(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
        Task { reply(await service.handle(request)) }
    }
}

/// The helper's password check: Basil's right, defined by the helper itself (admin group,
/// never granted to root on its own, never shared, no timeout), asked with the user's
/// AuthorizationRef so macOS shows its dialog in the user's session.
public enum HelperAuthorization {
    static var definition: [String: Any] { [
        "class": "user", "group": "admin", "allow-root": false, "authenticate-user": true,
        "session-owner": false, "shared": false, "timeout": 0, "tries": 10000, "version": 1,
    ] }

    /// Defines the right, or puts it back when someone defined it differently (anyone may add a
    /// right, so a weaker one could have been added first). False when that failed: then
    /// every authorization is refused.
    @discardableResult
    public static func ensureRight() -> Bool {
        if isSafe(currentDefinition()) { return true }
        var root: AuthorizationRef?
        guard AuthorizationCreate(nil, nil, [], &root) == errAuthorizationSuccess, let root else { return false }
        defer { AuthorizationFree(root, []) }
        _ = AuthorizationRightSet(root, BasilHelper.rightName, definition as CFDictionary,
                                  "Basil wants to change files that need an administrator." as CFString, nil, nil)
        return isSafe(currentDefinition())
    }

    static func currentDefinition() -> [String: Any]? {
        var current: CFDictionary?
        guard AuthorizationRightGet(BasilHelper.rightName, &current) == errAuthorizationSuccess else { return nil }
        return current as? [String: Any]
    }

    static func isSafe(_ d: [String: Any]?) -> Bool {
        guard let d else { return false }
        return d["class"] as? String == "user" && d["group"] as? String == "admin"
            && (d["allow-root"] as? Bool ?? false) == false && (d["shared"] as? Bool ?? false) == false
            && (d["session-owner"] as? Bool ?? false) == false && d["rule"] == nil && d["k-of-n"] == nil
    }

    /// Asks for the right with the user's external authorization (shows the password dialog).
    /// Throws `WireError.declined` when the user cancelled.
    @Sendable public static func check(_ external: Data, prompt: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try checkNow(external, prompt: prompt) })
            }
        }
    }

    static func checkNow(_ external: Data, prompt: String) throws {
        guard ensureRight() else { throw WireError.failed("The administrator right could not be set up") }
        guard external.count == MemoryLayout<AuthorizationExternalForm>.size else { throw WireError.notAuthorized }
        var form = AuthorizationExternalForm()
        withUnsafeMutableBytes(of: &form) { _ = external.copyBytes(to: $0) }
        var ref: AuthorizationRef?
        guard AuthorizationCreateFromExternalForm(&form, &ref) == errAuthorizationSuccess, let ref else {
            throw WireError.notAuthorized
        }
        defer { AuthorizationFree(ref, []) }
        let text = String(prompt.prefix(300))
        let status: OSStatus = BasilHelper.rightName.withCString { name in
            text.withCString { promptText in
                kAuthorizationEnvironmentPrompt.withCString { promptKey in
                    var right = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
                    var item = AuthorizationItem(name: promptKey, valueLength: strlen(promptText),
                                                 value: UnsafeMutableRawPointer(mutating: promptText), flags: 0)
                    return withUnsafeMutablePointer(to: &right) { rightPointer in
                        withUnsafeMutablePointer(to: &item) { itemPointer in
                            var rights = AuthorizationRights(count: 1, items: rightPointer)
                            var environment = AuthorizationEnvironment(count: 1, items: itemPointer)
                            return AuthorizationCopyRights(ref, &rights, &environment, [.extendRights, .interactionAllowed], nil)
                        }
                    }
                }
            }
        }
        switch status {
        case errAuthorizationSuccess: return
        case errAuthorizationCanceled: throw WireError.declined
        default: throw WireError.notAuthorized
        }
    }
}
