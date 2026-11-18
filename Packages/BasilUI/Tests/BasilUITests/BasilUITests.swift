import BasilCore
import BasilVFS
import Foundation
import Testing
@testable import BasilUI

/// Large-directory benchmark. Runs only when BASIL_PERF_DIR points at a big directory, e.g.:
///   mkdir -p /tmp/big && (cd /tmp/big && seq 200000 | sed 's/^/file /' | xargs -I{} touch "{}")
///   BASIL_PERF_DIR=/tmp/big swift test -c release --package-path Packages/BasilUI --filter largeDirectory
@MainActor
@Suite struct PaneModelPerformanceTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BASIL_PERF_DIR"] != nil))
    func largeDirectoryLoadsSortsAndFilters() async throws {
        let dir = VFSPath.local(ProcessInfo.processInfo.environment["BASIL_PERF_DIR"]!)
        let registry = ProviderRegistry()
        registry.register(LocalProvider())
        let model = PaneModel(registry: registry, directory: dir)

        func waitForReload(_ action: () -> Void) async -> Duration {
            let clock = ContinuousClock()
            let start = clock.now
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                var resumed = false
                model.onEvent = { event in
                    if case .reloaded = event, !resumed { resumed = true; c.resume() }
                }
                action()
            }
            return clock.now - start
        }

        let load = await waitForReload { model.load(dir) }
        print("PERF load+sort \(model.rows.count) items: \(load)")
        let sort = await waitForReload { model.setSortOrder(ListSortOrder(key: .size, ascending: false), cursor: nil) }
        print("PERF resort by size: \(sort)")
        let filter = await waitForReload { model.setFilter(try? NameFilter("*1234*"), cursor: nil) }
        print("PERF filter: \(filter) -> \(model.rows.count) rows")
        model.stop()
    }
}
