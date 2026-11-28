import AppKit
import AVFoundation
import BasilCore

/// Plays the sound and speaks the text configured for an event. Speech goes to VoiceOver as an
/// announcement when VoiceOver is running; otherwise the system voice speaks it.
@MainActor
public final class EventFeedbackPlayer {
    private let synthesizer = AVSpeechSynthesizer()
    /// Kept alive while playing (NSSound stops when released).
    private var playing: [NSSound] = []

    public init() {}

    private static var alertFolders: [URL] {
        ["/System/Library/Sounds", "/Library/Sounds",
         (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds")]
            .map { URL(fileURLWithPath: $0) }
    }

    /// Names of the macOS alert sounds (Basso, Blow, Glass, ...), sorted.
    public static func systemSoundNames() -> [String] {
        alertSoundNames(in: alertFolders)
    }

    /// Alert sounds plus the CoreAudio system sounds, including Finder's operation sounds.
    public static func availableSounds() -> [SoundChoice] {
        availableSounds(alertFolders: alertFolders, systemFolder: URL(fileURLWithPath: SystemSoundFiles.directory))
    }

    static func availableSounds(alertFolders: [URL], systemFolder: URL) -> [SoundChoice] {
        let alerts = alertSoundNames(in: alertFolders).map(SoundChoice.system)
        let files = soundFiles(in: systemFolder, recursively: true).map { SoundChoice.file($0.path) }
        return (alerts + files).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func alertSoundNames(in folders: [URL]) -> [String] {
        Set(folders.flatMap { soundFiles(in: $0, recursively: false) }
            .map { $0.deletingPathExtension().lastPathComponent }).sorted()
    }

    private static func soundFiles(in folder: URL, recursively: Bool) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        let files: [URL]
        if recursively {
            files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants])?.allObjects as? [URL] ?? []
        } else {
            files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])) ?? []
        }
        return files.filter {
            ["aiff", "aif", "caf", "wav", "mp3", "m4a"].contains($0.pathExtension.lowercased())
                && (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
    }

    public func play(_ sound: SoundChoice) {
        let player: NSSound?
        switch sound {
        case .none: return
        case .system(let name): player = NSSound(named: NSSound.Name(name))
        case .file(let path): player = NSSound(contentsOfFile: path, byReference: true)
        }
        guard let player else { return }
        playing.removeAll { !$0.isPlaying }
        playing.append(player)
        player.play()
    }

    public func speak(_ text: String) {
        guard !text.isEmpty else { return }
        if NSWorkspace.shared.isVoiceOverEnabled {
            // The app, not a window: announcements must be heard whichever window is key.
            NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
        } else {
            synthesizer.speak(AVSpeechUtterance(string: text))
        }
    }

    public func perform(_ feedback: EventFeedback, values: FeedbackValues) {
        play(feedback.sound)
        if feedback.speak { speak(FeedbackText.render(feedback.text, values)) }
    }
}
