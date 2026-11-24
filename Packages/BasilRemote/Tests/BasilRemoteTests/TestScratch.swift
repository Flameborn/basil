import Darwin
import Foundation

/// The temporary folder of one test run: every test's own folders go in it, and it is removed
/// when the run exits, so a run leaves nothing behind; a killed run's folder goes at the start of the next run.
enum TestScratch {
    static let url: URL = {
        let temporary = FileManager.default.temporaryDirectory
        // Runs that were killed (atexit did not run) leave theirs: removed once their process is gone.
        for name in (try? FileManager.default.contentsOfDirectory(atPath: temporary.path)) ?? []
        where name.hasPrefix("basil-remote-tests-") {
            if let pid = Int32(name.dropFirst("basil-remote-tests-".count)), kill(pid, 0) != 0, errno == ESRCH {
                try? FileManager.default.removeItem(at: temporary.appendingPathComponent(name))
            }
        }
        let url = temporary.appendingPathComponent("basil-remote-tests-\(getpid())")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        atexit { try? FileManager.default.removeItem(at: TestScratch.url) }
        return url
    }()
}
