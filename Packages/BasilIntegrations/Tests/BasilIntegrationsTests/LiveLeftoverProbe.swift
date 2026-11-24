import Foundation
import Testing
@testable import BasilIntegrations

@Test(.enabled(if: ProcessInfo.processInfo.environment["BASIL_LEFTOVER_PROBE"] != nil))
func liveLeftoverProbe() {
    let path = ProcessInfo.processInfo.environment["BASIL_LEFTOVER_PROBE"]!
    let app = AppIdentity.read(appAt: URL(fileURLWithPath: path))!
    let start = Date()
    let found = AppLeftoverFinder().find(for: app)
    print("PROBE took \(Date().timeIntervalSince(start)) s")
    for f in found { print("PROBE \(f.kind): \(f.url.path) shared=\(f.sharedWith ?? "-") admin=\(f.needsAdmin)") }
}
