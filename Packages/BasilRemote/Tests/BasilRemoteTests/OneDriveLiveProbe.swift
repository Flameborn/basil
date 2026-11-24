import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Testing
@testable import BasilRemote

private final class ProbeMonitor: TransferMonitor {
    func checkpoint() async throws { try Task.checkCancellation() }
    func log(_ message: String) { print("log: \(message)") }
    func transferred(bytes: Int64) {}
    func decide(_ source: UnstableSource) async -> UnstableSourceDecision { .acceptLatest }
}

/// Against a real OneDrive account, skipped unless BASIL_ONEDRIVE_LIVE (the saved user ID) and
/// BASIL_ONEDRIVE_CLIENT_ID are set. Uses Basil's own Keychain sign-in (saving the rotated
/// refresh token back), lists, and with BASIL_ONEDRIVE_COPY copies that path to a local folder.
/// Changes nothing on the server.
@Test(.enabled(if: ProcessInfo.processInfo.environment["BASIL_ONEDRIVE_LIVE"] != nil))
func oneDriveLiveProbe() async throws {
    let env = ProcessInfo.processInfo.environment
    let connector = OneDriveConnector(clientID: env["BASIL_ONEDRIVE_CLIENT_ID"]!, secrets: Keychain.remoteSecrets)
    let registry = ProviderRegistry()
    registry.register(LocalProvider())
    registry.register(connector: connector)
    let start = try await registry.connect(RemoteTarget(service: .oneDrive, host: env["BASIL_ONEDRIVE_LIVE"]!, path: "/"),
                                           prompts: TestPrompts())
    let provider = try #require(try registry.provider(for: start.location))
    func walk(_ path: VFSPath, depth: Int) async throws {
        var items: [FileItem] = []
        for try await batch in provider.list(path) { items += batch }
        for item in items.sorted(by: { $0.name < $1.name }) {
            print(String(repeating: "  ", count: depth) + "\(item.name) \(item.kind) \(item.size)")
            if depth < 2, case .directory = item.kind { try await walk(item.path, depth: depth + 1) }
        }
    }
    if let copy = env["BASIL_ONEDRIVE_COPY"] {
        let source = VFSPath(location: start.location, path: copy)
        let folder = TestScratch.url.appendingPathComponent("basil-onedrive-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await walk(source, depth: 0)
        let engine = SecureCopyEngine(registry: registry, options: SecureCopyOptions(secure: true), monitor: ProbeMonitor())
        let result = try await engine.transfer(source, to: .local(folder.appendingPathComponent(source.name).path), mode: .copy)
        print("result: \(result)")
        let out = Process()
        out.executableURL = URL(fileURLWithPath: "/bin/ls")
        out.arguments = ["-laR", folder.path]
        try out.run(); out.waitUntilExit()
    } else {
        try await walk(start, depth: 0)
    }
}
