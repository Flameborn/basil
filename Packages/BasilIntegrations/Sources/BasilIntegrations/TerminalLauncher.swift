import AppKit

/// A terminal that "Open terminal here" (Cmd+Shift+T) can start in a folder. Built-in terminals
/// register in `TerminalCatalog`; plugins can add more the same way.
public struct TerminalApp: Sendable, Identifiable, Hashable {
    public enum Launch: Sendable, Hashable {
        /// Open the folder with the app (the app opens a new window there).
        case openFolder
        /// Run an executable inside the app bundle; `{dir}` in the arguments is the folder path.
        case run(executable: String, arguments: [String])
        /// The user's shell command from Settings; `{dir}` is the quoted folder path.
        case shellCommand
    }

    public let id: String
    public let name: String
    /// Nil for the custom command.
    public let bundleID: String?
    public let launch: Launch

    public init(id: String, name: String, bundleID: String?, launch: Launch) {
        self.id = id
        self.name = name
        self.bundleID = bundleID
        self.launch = launch
    }
}

@MainActor
public enum TerminalCatalog {
    public static let custom = TerminalApp(id: "custom", name: "Custom command", bundleID: nil, launch: .shellCommand)

    public private(set) static var all: [TerminalApp] = [
        TerminalApp(id: "terminal", name: "Terminal", bundleID: "com.apple.Terminal", launch: .openFolder),
        TerminalApp(id: "iterm2", name: "iTerm2", bundleID: "com.googlecode.iterm2", launch: .openFolder),
        TerminalApp(id: "ghostty", name: "Ghostty", bundleID: "com.mitchellh.ghostty", launch: .openFolder),
        TerminalApp(id: "warp", name: "Warp", bundleID: "dev.warp.Warp-Stable", launch: .openFolder),
        TerminalApp(id: "wezterm", name: "WezTerm", bundleID: "com.github.wez.wezterm",
                    launch: .run(executable: "Contents/MacOS/wezterm", arguments: ["start", "--cwd", "{dir}"])),
        TerminalApp(id: "kitty", name: "Kitty", bundleID: "net.kovidgoyal.kitty",
                    launch: .run(executable: "Contents/MacOS/kitty", arguments: ["--single-instance", "--directory", "{dir}"])),
        TerminalApp(id: "alacritty", name: "Alacritty", bundleID: "org.alacritty",
                    launch: .run(executable: "Contents/MacOS/alacritty", arguments: ["--working-directory", "{dir}"])),
        custom,
    ]

    public static func register(_ terminal: TerminalApp) {
        all.removeAll { $0.id == terminal.id }
        all.insert(terminal, at: max(0, all.count - 1))
    }

    public static func terminal(id: String) -> TerminalApp? { all.first { $0.id == id } }

    /// The app bundle of an installed terminal, or nil.
    public static func appURL(_ terminal: TerminalApp) -> URL? {
        terminal.bundleID.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
    }

    /// Terminals that are installed, plus the custom command.
    public static var available: [TerminalApp] {
        all.filter { $0.bundleID == nil || appURL($0) != nil }
    }
}

public enum TerminalLaunchError: LocalizedError {
    case unknownTerminal(String)
    case notInstalled(String)
    case emptyCommand

    public var errorDescription: String? {
        switch self {
        case .unknownTerminal(let id): "Unknown terminal \(id)"
        case .notInstalled(let name): "\(name) is not installed"
        case .emptyCommand: "The custom terminal command is empty. Set it in Settings, Editor and Terminal"
        }
    }
}

@MainActor
public enum TerminalLauncher {
    /// Opens `terminalID` in `folder`. `command` is the custom shell command.
    public static func open(_ folder: URL, terminalID: String, command: String) async throws {
        guard let terminal = TerminalCatalog.terminal(id: terminalID) else {
            throw TerminalLaunchError.unknownTerminal(terminalID)
        }
        switch terminal.launch {
        case .shellCommand:
            let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw TerminalLaunchError.emptyCommand }
            try run(URL(fileURLWithPath: "/bin/sh"), ["-c", expand(text, folder: folder.path)], in: folder)
        case .openFolder:
            guard let app = TerminalCatalog.appURL(terminal) else { throw TerminalLaunchError.notInstalled(terminal.name) }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: configuration)
        case .run(let executable, let arguments):
            guard let app = TerminalCatalog.appURL(terminal) else { throw TerminalLaunchError.notInstalled(terminal.name) }
            try run(app.appendingPathComponent(executable),
                    arguments.map { $0.replacingOccurrences(of: "{dir}", with: folder.path) }, in: folder)
        }
    }

    /// Replaces `{dir}` with the folder path, single-quoted for the shell.
    nonisolated static func expand(_ template: String, folder: String) -> String {
        template.replacingOccurrences(of: "{dir}", with: shellQuoted(folder))
    }

    nonisolated static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func run(_ executable: URL, _ arguments: [String], in folder: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
