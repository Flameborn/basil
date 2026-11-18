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

    /// Names of the macOS system sounds (Basso, Blow, Glass, ...), sorted.
    public static func systemSoundNames() -> [String] {
        let folders = ["/System/Library/Sounds", "/Library/Sounds",
                       (NSHomeDirectory() as NSString).appendingPathComponent("Library/Sounds")]
        var names = Set<String>()
        for folder in folders {
            for file in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                let ext = (file as NSString).pathExtension.lowercased()
                if ["aiff", "aif", "caf", "wav", "mp3", "m4a"].contains(ext) {
                    names.insert((file as NSString).deletingPathExtension)
                }
            }
        }
        return names.sorted()
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
