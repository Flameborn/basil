// BasilOperations
//
// What a copy, move, unpack or upload reports while it runs, for Total Commander's progress
// dialog: totals, the current file, speed and time left. `TransferEstimator` turns byte and file
// counts over active time (pauses and questions left out) into a speed and an estimate.

import BasilCore
import BasilVFS
import Foundation

/// The state of a running transfer, published on the queue item (`QueueItem.transfer`).
public struct TransferProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        /// Adding up sizes before the copy starts.
        case counting
        /// Reading and writing the current file.
        case transferring
        /// The current file changed during its copy and is read again (the secure engine).
        case rereading(attempt: Int)
        /// Reading the written file back (destination verification).
        case verifying
        /// Writing the file's metadata, syncing, committing an upload, renaming it into place.
        case finishing
    }

    public var phase: Phase = .counting
    /// First-pass bytes of every file so far, and the total counted before the copy.
    public var bytesDone: Int64 = 0
    public var bytesTotal: Int64 = 0
    /// Files finished (or skipped) and in total. `filesTotal` is 0 when it was not counted.
    public var filesDone = 0
    public var filesTotal = 0
    /// The file being transferred and where it goes.
    public var source: VFSPath?
    public var destination: VFSPath?
    /// Bytes of the current file read in the current pass, and its size.
    public var fileBytesDone: Int64 = 0
    public var fileBytesTotal: Int64 = 0
    /// Recent speed; nil until enough has been measured.
    public var bytesPerSecond: Double?
    /// Estimated time left; nil until enough has been measured.
    public var secondsLeft: Double?
    /// Time spent working (pauses and questions not counted).
    public var elapsed: Double = 0

    public init() {}

    public var fraction: Double? {
        guard bytesTotal > 0 else { return filesTotal > 0 ? Double(filesDone) / Double(filesTotal) : nil }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }

    public var fileFraction: Double? {
        guard fileBytesTotal > 0 else { return nil }
        return min(1, Double(fileBytesDone) / Double(fileBytesTotal))
    }
}

/// Speed and time left from cumulative counts over active time.
///
/// Speed is the byte rate over the last `speedWindow` seconds. The estimate models the time of a
/// file as `bytes / throughput + overhead`: throughput is the byte rate over the last
/// `estimateWindow` seconds of transferring, and the per-file overhead (opening, creating,
/// metadata, syncing, the round trips of a server) is fitted from the files finished recently.
/// So many small files left after big ones (or the other way round) still get a fair estimate.
public struct TransferEstimator: Sendable {
    public var speedWindow: Double = 3
    public var estimateWindow: Double = 20
    /// Nothing is estimated before this much active time.
    public var warmUp: Double = 1

    private struct Sample { var time: Double; var bytes: Int64 }
    private struct FileSample { var bytes: Int64; var seconds: Double; var finished: Double }

    private var samples: [Sample] = []
    private var files: [FileSample] = []
    private var fileStart: Double?
    private var startTime: Double?

    public init() {}

    /// Cumulative first-pass bytes at active time `time` (seconds).
    public mutating func record(time: Double, bytes: Int64) {
        if startTime == nil { startTime = time }
        if let last = samples.last, last.time == time {
            samples[samples.count - 1].bytes = bytes
        } else {
            samples.append(Sample(time: time, bytes: bytes))
        }
        let keep = time - max(speedWindow, estimateWindow) - 1
        if let cut = samples.firstIndex(where: { $0.time >= keep }), cut > 1 {
            samples.removeFirst(cut - 1)
        }
    }

    public mutating func fileStarted(time: Double) {
        if startTime == nil { startTime = time }
        fileStart = time
    }

    /// A file finished; `bytes` is its size (also when it was cloned or renamed at once).
    public mutating func fileFinished(time: Double, bytes: Int64) {
        guard let start = fileStart else { return }
        fileStart = nil
        files.append(FileSample(bytes: bytes, seconds: max(0, time - start), finished: time))
        if files.count > 200 { files.removeFirst(files.count - 200) }
    }

    /// The sample at or just before `time - window`, or the first one.
    private func windowStart(_ window: Double, at time: Double) -> Sample? {
        samples.last(where: { $0.time <= time - window }) ?? samples.first
    }

    /// Bytes per second over the last `window` seconds before `time`.
    private func rate(over window: Double, at time: Double) -> Double? {
        guard let last = samples.last, let first = windowStart(window, at: time) else { return nil }
        let seconds = time - first.time
        guard seconds > 0 else { return nil }
        return Double(last.bytes - first.bytes) / seconds
    }

    public func speed(at time: Double) -> Double? {
        guard let start = startTime, time - start >= warmUp else { return nil }
        return rate(over: speedWindow, at: time)
    }

    /// The per-file overhead in seconds: the intercept of a least-squares fit of
    /// `seconds = bytes * k + overhead` over the recent files, never below 0. Nil while there are
    /// too few files or their sizes are too alike to tell bytes and overhead apart (the byte rate
    /// alone then predicts well, because the files left are like the ones done).
    func overhead() -> Double? {
        let recent = files.suffix(50)
        guard recent.count >= 3 else { return nil }
        let n = Double(recent.count)
        let mb = recent.reduce(0.0) { $0 + Double($1.bytes) } / n
        let ms = recent.reduce(0.0) { $0 + $1.seconds } / n
        var sbb = 0.0, sbs = 0.0
        for f in recent {
            let db = Double(f.bytes) - mb
            sbb += db * db
            sbs += db * (f.seconds - ms)
        }
        guard sbb > 0, mb > 0, sqrt(sbb / n) > mb * 0.1 else { return nil }
        let k = sbs / sbb
        guard k > 0 else { return ms } // time does not grow with size: all overhead
        return max(0, ms - k * mb)
    }

    /// Seconds left for `bytesLeft` in `filesLeft` files (the current one counted when unfinished).
    public func secondsLeft(at time: Double, bytesLeft: Int64, filesLeft: Int) -> Double? {
        guard let start = startTime, time - start >= warmUp else { return nil }
        guard bytesLeft > 0 || filesLeft > 0 else { return 0 }
        guard let last = samples.last, let first = windowStart(estimateWindow, at: time) else { return nil }
        let seconds = time - first.time
        let bytes = Double(last.bytes - first.bytes)
        guard seconds > 0 else { return nil }
        let perFile = overhead() ?? 0
        // Time in the window spent on bytes, without the overhead of the files finished in it.
        let finished = Double(files.count { $0.finished > first.time })
        let busy = max(seconds * 0.1, seconds - finished * perFile)
        guard bytes > 0 else { return perFile > 0 ? Double(filesLeft) * perFile : nil }
        let throughput = bytes / busy
        return Double(bytesLeft) / throughput + Double(filesLeft) * perFile
    }
}

extension TransferEstimator {
    /// Time left in words for display and speech: "About 2 minutes 10 seconds left",
    /// "Less than 5 seconds left".
    public static func describe(secondsLeft seconds: Double) -> String {
        if seconds < 5 { return "Less than 5 seconds left" }
        var s = Int(seconds.rounded())
        // Coarser steps for long estimates, so the text does not flicker.
        if s >= 3600 { s = (s / 60) * 60 } else if s >= 600 { s = (s / 10) * 10 }
        let hours = s / 3600, minutes = (s % 3600) / 60, secs = s % 60
        func unit(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        var parts: [String] = []
        if hours > 0 { parts.append(unit(hours, "hour")) }
        if minutes > 0 { parts.append(unit(minutes, "minute")) }
        if secs > 0, hours == 0 { parts.append(unit(secs, "second")) }
        return "About " + parts.joined(separator: " ") + " left"
    }

    /// Elapsed time in words: "1 minute 5 seconds".
    public static func describe(elapsed seconds: Double) -> String {
        let s = Int(seconds.rounded())
        let hours = s / 3600, minutes = (s % 3600) / 60, secs = s % 60
        func unit(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }
        var parts: [String] = []
        if hours > 0 { parts.append(unit(hours, "hour")) }
        if minutes > 0 { parts.append(unit(minutes, "minute")) }
        if hours == 0 { parts.append(unit(secs, "second")) }
        return parts.joined(separator: " ")
    }
}
