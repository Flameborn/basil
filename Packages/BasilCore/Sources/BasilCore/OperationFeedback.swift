import Foundation

/// The kind of a queue operation ("copy", "move", ...). Used to pick the sound and speech for its
/// events. Plugins can register more kinds in `OperationKindCatalog`.
public struct OperationKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }

    public static let copy: OperationKind = "copy"
    public static let move: OperationKind = "move"
    public static let delete: OperationKind = "delete"
    public static let trash: OperationKind = "trash"
    public static let makeDirectory: OperationKind = "mkdir"
    public static let newFile: OperationKind = "newfile"
    public static let rename: OperationKind = "rename"
    public static let testArchive: OperationKind = "testarchive"
    public static let pack: OperationKind = "pack"
    public static let createChecksums: OperationKind = "createchecksums"
    public static let verifyChecksums: OperationKind = "verifychecksums"
    public static let unpack: OperationKind = "unpack"
    public static let split: OperationKind = "split"
    public static let combine: OperationKind = "combine"
    /// F4 on a server: an edited copy put back.
    public static let upload: OperationKind = "upload"
    /// Operations without a kind of their own (for example the debug test operation).
    public static let other: OperationKind = "other"
}

/// Display words for an operation kind.
public struct OperationKindInfo: Sendable, Equatable {
    public var kind: OperationKind
    /// Noun for settings and speech, e.g. "Copy", "Move to Trash".
    public var name: String
    /// Past tense for speech, e.g. "copied", "moved to the Trash".
    public var pastTense: String

    public init(kind: OperationKind, name: String, pastTense: String) {
        self.kind = kind
        self.name = name
        self.pastTense = pastTense
    }
}

/// All operation kinds known to settings and speech, in settings order. Built-in kinds are
/// registered here; plugins add theirs with `register`.
@MainActor
public enum OperationKindCatalog {
    public private(set) static var all: [OperationKindInfo] = [
        OperationKindInfo(kind: .copy, name: "Copy", pastTense: "copied"),
        OperationKindInfo(kind: .move, name: "Move", pastTense: "moved"),
        OperationKindInfo(kind: .delete, name: "Delete", pastTense: "deleted"),
        OperationKindInfo(kind: .trash, name: "Move to Trash", pastTense: "moved to the Trash"),
        OperationKindInfo(kind: .makeDirectory, name: "New Folder", pastTense: "created"),
        OperationKindInfo(kind: .newFile, name: "New File", pastTense: "created"),
        OperationKindInfo(kind: .rename, name: "Rename", pastTense: "renamed"),
        OperationKindInfo(kind: .pack, name: "Pack", pastTense: "packed"),
        OperationKindInfo(kind: .unpack, name: "Unpack", pastTense: "unpacked"),
        OperationKindInfo(kind: .testArchive, name: "Test Archive", pastTense: "tested"),
        OperationKindInfo(kind: .createChecksums, name: "Create Checksums", pastTense: "checksummed"),
        OperationKindInfo(kind: .verifyChecksums, name: "Verify Checksums", pastTense: "verified"),
        OperationKindInfo(kind: .split, name: "Split File", pastTense: "split"),
        OperationKindInfo(kind: .combine, name: "Combine Files", pastTense: "combined"),
        OperationKindInfo(kind: .upload, name: "Upload Edited File", pastTense: "uploaded"),
        OperationKindInfo(kind: .other, name: "Other", pastTense: "done"),
    ]

    public static func register(_ info: OperationKindInfo) {
        if let i = all.firstIndex(where: { $0.kind == info.kind }) { all[i] = info } else { all.append(info) }
    }

    public static func unregister(_ kind: OperationKind) { all.removeAll { $0.kind == kind } }

    public static func info(_ kind: OperationKind) -> OperationKindInfo {
        all.first { $0.kind == kind } ?? OperationKindInfo(kind: kind, name: kind.rawValue.capitalized, pastTense: "done")
    }
}

/// How a queue item ended, or that it is waiting for the user.
public enum QueueOutcome: String, CaseIterable, Codable, Sendable {
    case finished, failed, cancelled
    /// A conflict or a source that keeps changing: the operation waits for an answer.
    case needsDecision

    public var title: String {
        switch self {
        case .finished: "Finished"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        case .needsDecision: "Needs a decision"
        }
    }
}

public enum SoundChoice: Codable, Hashable, Sendable {
    case none
    /// A macOS system sound by name ("Glass", "Basso", ...), from /System/Library/Sounds.
    case system(String)
    /// Any audio file chosen by the user.
    case file(String)

    public var title: String {
        switch self {
        case .none: "None"
        case .system(let name): name
        case .file(let path): (path as NSString).lastPathComponent
        }
    }
}

/// Sound and speech for one event.
public struct EventFeedback: Codable, Equatable, Sendable {
    public var sound: SoundChoice
    public var speak: Bool
    /// Spoken text with placeholders, see `FeedbackText`.
    public var text: String

    public init(sound: SoundChoice, speak: Bool, text: String) {
        self.sound = sound
        self.speak = speak
        self.text = text
    }
}

/// Sound and speech for queue events. `defaults` applies to every operation ("Any operation");
/// `overrides` replaces it for one operation kind and outcome.
public struct FeedbackSettings: Codable, Equatable, Sendable {
    /// Keyed by `QueueOutcome.rawValue`.
    public var defaults: [String: EventFeedback]
    /// Keyed by `OperationKind.rawValue`, then `QueueOutcome.rawValue`.
    public var overrides: [String: [String: EventFeedback]]

    public static let standardDefaults: [QueueOutcome: EventFeedback] = [
        .finished: EventFeedback(sound: .system("Glass"), speak: true, text: "{operation} complete, {done} {verb}"),
        .failed: EventFeedback(sound: .system("Basso"), speak: true, text: "{operation} failed, {count} of {total} {verb}. {reason}"),
        .cancelled: EventFeedback(sound: .none, speak: true, text: "{operation} cancelled, {count} of {total} {verb}"),
        .needsDecision: EventFeedback(sound: .system("Funk"), speak: true, text: "{operation} needs a decision"),
    ]

    public init() {
        defaults = Dictionary(uniqueKeysWithValues: Self.standardDefaults.map { ($0.key.rawValue, $0.value) })
        overrides = [:]
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = FeedbackSettings()
        defaults = try c.decodeIfPresent([String: EventFeedback].self, forKey: .defaults) ?? d.defaults
        overrides = try c.decodeIfPresent([String: [String: EventFeedback]].self, forKey: .overrides) ?? d.overrides
        for (key, value) in d.defaults where defaults[key] == nil { defaults[key] = value }
    }

    /// The feedback that applies to an event: the override for the kind if there is one, else the default.
    public func feedback(for kind: OperationKind, _ outcome: QueueOutcome) -> EventFeedback {
        overrides[kind.rawValue]?[outcome.rawValue]
            ?? defaults[outcome.rawValue]
            ?? Self.standardDefaults[outcome]!
    }

    public func override(for kind: OperationKind, _ outcome: QueueOutcome) -> EventFeedback? {
        overrides[kind.rawValue]?[outcome.rawValue]
    }

    public mutating func setOverride(_ feedback: EventFeedback?, for kind: OperationKind, _ outcome: QueueOutcome) {
        var forKind = overrides[kind.rawValue] ?? [:]
        forKind[outcome.rawValue] = feedback
        overrides[kind.rawValue] = forKind.isEmpty ? nil : forKind
    }
}

/// The values a spoken text can use. Placeholders:
/// {operation} "Copy", {verb} "copied", {done} "2 items", {count} "2", {total} "3 items",
/// {title} the queue item's title, {reason} the error or the question.
public struct FeedbackValues: Sendable, Equatable {
    public var kind: OperationKindInfo
    public var title: String
    public var done: Int
    public var total: Int
    public var reason: String

    public init(kind: OperationKindInfo, title: String, done: Int, total: Int, reason: String = "") {
        self.kind = kind
        self.title = title
        self.done = done
        self.total = total
        self.reason = reason
    }
}

public enum FeedbackText {
    public static let placeholderHelp =
        "{operation} name, {verb} past tense, {done} items done (\"2 items\"), {count} number done, {total} all items, {title} queue entry, {reason} error or question"

    public static func items(_ n: Int) -> String { n == 1 ? "1 item" : "\(n) items" }

    public static func render(_ template: String, _ v: FeedbackValues) -> String {
        let replacements: [(String, String)] = [
            ("{operation}", v.kind.name),
            ("{verb}", v.kind.pastTense),
            ("{done}", items(v.done)),
            ("{count}", String(v.done)),
            ("{total}", items(v.total)),
            ("{title}", v.title),
            ("{reason}", v.reason),
        ]
        var s = template
        for (key, value) in replacements { s = s.replacingOccurrences(of: key, with: value) }
        // An empty {reason} leaves ". " or ", " at the end.
        s = s.trimmingCharacters(in: .whitespaces)
        while let last = s.last, last == "." || last == "," || last == ":" { s.removeLast(); s = s.trimmingCharacters(in: .whitespaces) }
        return s
    }
}
