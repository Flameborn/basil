import AppKit
import BasilCore
import BasilIntegrations
import BasilVFS

// MARK: - Command line bar (Left or Right in a pane)

/// The pane's command line, like Total Commander's: an edit field that pops up under the list.
/// Return runs the command in the pane's folder (`MainWindowController.runCommandLine`),
/// Escape or Tab go back to the list, Up and Down walk through earlier commands, Ctrl+Return
/// inserts the cursor item's name and Ctrl+Shift+Return its full path.
@MainActor
final class CommandLineBar: ThemedBox, NSTextFieldDelegate {
    var onRun: ((String) -> Void)?
    var onClose: (() -> Void)?
    /// The cursor item's name (false) or full path (true), quoted for the shell when needed.
    var cursorText: ((Bool) -> String?)?

    private let label = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private var history: CommandHistory
    /// Where Up and Down are in the history; nil while editing a new command.
    private var historyIndex: Int?
    private var draft = ""

    var isEditing: Bool { !isHidden && field.currentEditor() != nil && window?.firstResponder == field.currentEditor() }

    init(defaults: UserDefaults) {
        history = CommandHistory(defaults: defaults)
        super.init(frame: .zero)
        fillColor = Theme.barBackground

        label.font = Theme.barFont
        label.textColor = Theme.barText
        label.lineBreakMode = .byTruncatingHead
        label.setAccessibilityElement(false)
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        field.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.delegate = self
        field.placeholderString = "A shell command, or cd and a folder"
        field.setAccessibilityIdentifier("commandLine.field")
        field.setAccessibilityHelp("Return runs the command. Escape goes back to the list. Up and Down go through earlier commands. "
            + "Control Return inserts the cursor item's name, Control Shift Return its path.")
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [label, field])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.4),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Command line")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the bar for `folder` (its name, as spoken and shown) and puts the focus in the field.
    func show(folder: String) {
        label.stringValue = "Command in \(folder):"
        field.setAccessibilityLabel("Command in \(folder)")
        isHidden = false
        window?.makeFirstResponder(field)
    }

    private func finish() {
        historyIndex = nil
        onClose?()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                finish()
                return true
            }
            history.add(text)
            field.stringValue = ""
            historyIndex = nil
            onRun?(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            finish()
            return true
        case #selector(NSResponder.moveUp(_:)):
            stepHistory(older: true)
            return true
        case #selector(NSResponder.moveDown(_:)):
            stepHistory(older: false)
            return true
        default:
            return false
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        // Typing leaves the history: Up starts again from the newest command.
        historyIndex = nil
    }

    private func stepHistory(older: Bool) {
        let items = history.items
        guard !items.isEmpty else {
            NSSound.beep()
            return
        }
        let next: Int?
        switch (historyIndex, older) {
        case (nil, true):
            draft = field.stringValue
            next = items.count - 1
        case (nil, false):
            NSSound.beep()
            return
        case (let i?, true):
            guard i > 0 else {
                NSSound.beep()
                return
            }
            next = i - 1
        case (let i?, false):
            next = i + 1 < items.count ? i + 1 : nil
        }
        historyIndex = next
        setText(next.map { items[$0] } ?? draft)
    }

    private func setText(_ text: String) {
        field.stringValue = text
        if let editor = field.currentEditor() {
            editor.selectedRange = NSRange(location: (text as NSString).length, length: 0)
        }
        // VoiceOver does not read a value that changed without typing.
        announce(text.isEmpty ? "Empty" : text)
    }

    /// Ctrl+Return and Ctrl+Shift+Return while the field is being edited (Ctrl chords come
    /// through key equivalents first).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard isEditing, event.type == .keyDown, event.keyCode == 36 || event.keyCode == 76,
              flags == .control || flags == [.control, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        guard let text = cursorText?(flags.contains(.shift)), let editor = field.currentEditor() as? NSTextView else {
            NSSound.beep()
            return true
        }
        editor.insertText(text + " ", replacementRange: editor.selectedRange())
        announce(text)
        return true
    }

    private func announce(_ message: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Single quotes around text the shell would split or expand.
    nonisolated static func shellQuoted(_ text: String) -> String {
        let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-+/@%,:=")
        if !text.isEmpty, text.unicodeScalars.allSatisfy(plain.contains) { return text }
        return "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The last 50 commands, newest last, shared by both panes and kept between launches.
struct CommandHistory {
    static let key = "commandLine.history"
    static let limit = 50
    let defaults: UserDefaults

    var items: [String] { defaults.stringArray(forKey: Self.key) ?? [] }

    func add(_ command: String) {
        var list = items.filter { $0 != command }
        list.append(command)
        defaults.set(Array(list.suffix(Self.limit)), forKey: Self.key)
    }
}

// MARK: - Running a command line

/// What a typed command line means.
enum CommandLineAction: Equatable {
    /// "cd", "cd ~", "cd folder": change the pane's folder (nil target: the home folder).
    case changeDirectory(String?)
    case run(String)

    init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed == "cd" {
            self = .changeDirectory(nil)
            return
        }
        guard trimmed.hasPrefix("cd ") || trimmed.hasPrefix("cd\t") else {
            self = .run(trimmed)
            return
        }
        var target = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
        // Several words or shell syntax are for the shell ("cd a && make").
        let special = CharacterSet(charactersIn: ";&|<>$`*?()")
        if let quote = target.first, quote == "'" || quote == "\"", target.count >= 2, target.last == quote {
            target = String(target.dropFirst().dropLast())
        } else if target.unicodeScalars.contains(where: special.contains) {
            self = .run(trimmed)
            return
        } else {
            target = target.replacingOccurrences(of: "\\ ", with: " ")
        }
        self = .changeDirectory(target.isEmpty || target == "~" ? nil : target)
    }
}

extension MainWindowController {
    /// Return in a pane's command line.
    func runCommandLine(_ text: String, in pane: PaneViewController) {
        let directory = pane.model.directory
        switch CommandLineAction(text) {
        case .changeDirectory(let target):
            let home = VFSPath.local(FileManager.default.homeDirectoryForCurrentUser.path)
            guard let destination = target.map({ resolve($0, relativeTo: directory) }) ?? home else { return }
            pane.hideCommandLine()
            pane.navigate(to: destination)
        case .run(let command):
            guard let local = providers.localPath(of: directory) else {
                pane.report("Commands run only in folders on this Mac or on mounted shares")
                return
            }
            pane.hideCommandLine()
            CommandOutputWindowController.run(command, in: URL(fileURLWithPath: local.path, isDirectory: true),
                                              folderName: pane.commandLineFolderName,
                                              announce: { [weak self] in self?.announce($0) },
                                              finished: { [weak self] in self?.commandLineFinished(in: directory) })
        }
    }

    /// Local folders are watched; the reread also covers folders on mounted shares and the Git column.
    private func commandLineFinished(in directory: VFSPath) {
        for pane in [left, right] where pane.model.directory == directory {
            pane.model.reload(cursor: pane.cursorPath)
            pane.refreshAnnotations(after: .zero)
        }
    }
}
