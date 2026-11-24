import BasilCore
import BasilSearch
import Foundation

/// The search index's state in words for Settings ("Status: up to date, 1,234,567 items"), and Rebuild.
@MainActor
@Observable
final class SearchIndexStatus {
    private(set) var text = ""
    @ObservationIgnored let index: FilenameIndex

    init(index: FilenameIndex) {
        self.index = index
        update(index.state)
        index.observe { [weak self] state in
            Task { @MainActor in self?.update(state) }
        }
    }

    func rebuild() {
        let index = index
        Task { await index.rebuild() }
    }

    private func update(_ state: FilenameIndex.State) {
        text = switch state {
        case .off: "Status: off"
        case .loading: "Status: loading"
        case .scanning(let count): "Status: building, \(count.formatted()) items so far"
        case .ready(let count): "Status: up to date, \(count.formatted()) items"
        case .failed(let reason): "Status: could not be built: \(reason)"
        }
    }
}

extension MainWindowController {
    /// At quit: writes the index's unsaved changes (waits up to two seconds). Changes not saved are
    /// replayed from FSEvents at the next start anyway.
    public func saveSearchIndex() {
        guard let index = searchIndex, searchIndexRunning else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await index.saveIfNeeded()
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    /// Starts or stops the index to match Settings (turning it off deletes its file).
    func applySearchIndexSetting() {
        guard let index = searchIndex else { return }
        let on = settings.settings.searchIndex
        guard on != searchIndexRunning else { return }
        searchIndexRunning = on
        Task {
            if on { await index.start() } else { await index.stop(deleting: true) }
        }
    }
}
