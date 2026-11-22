import AppKit
import BasilCore
import BasilVFS
import SwiftUI
import Synchronization

// Remote connections in the window: Cmd+K's connection manager (saved connections and Quick
// Connect), the questions a connection asks (host keys, passwords, passphrases), connecting,
// and Disconnect. The services themselves (SFTP, FTP, FTPS) are `RemoteConnector`s in the
// registry; the editor shows each one's logins and options as the connector describes them.

// MARK: Questions

/// The window's answers to connection questions: NSAlert sheets, with secrets read from and
/// saved to the Keychain (`secrets`).
final class RemotePromptsUI: RemotePrompts, @unchecked Sendable {
    private weak var controller: MainWindowController?
    private let secrets: any SecretStore

    @MainActor init(controller: MainWindowController, secrets: any SecretStore) {
        self.controller = controller
        self.secrets = secrets
    }

    func hostKey(_ question: HostKeyQuestion) async -> HostKeyAnswer {
        await MainActor.run { controller }?.askHostKey(question) ?? .cancel
    }

    func certificate(_ question: CertificateQuestion) async -> HostKeyAnswer {
        await MainActor.run { controller }?.askCertificate(question) ?? .cancel
    }

    /// Keychain keys whose stored secret was just handed out (only touched from one connection's
    /// login at a time).
    private let fromKeychain = Mutex<Set<String>>([])

    func secret(_ request: SecretRequest) async -> SecretAnswer? {
        if let key = request.keychainKey {
            let wasStored = fromKeychain.withLock { $0.remove(key) != nil }
            // A stored secret is tried first. When it was refused, it is wrong: forget it and ask.
            if request.retry, wasStored { secrets.remove(for: key) }
            if !request.retry, let stored = secrets.secret(for: key) {
                fromKeychain.withLock { _ = $0.insert(key) }
                return SecretAnswer(secret: stored, remember: false)
            }
        }
        return await MainActor.run { controller }?.askSecret(request)
    }

    func secretWorked(_ request: SecretRequest, _ answer: SecretAnswer) async {
        guard answer.remember, let key = request.keychainKey else { return }
        secrets.save(answer.secret, for: key)
    }

    func note(_ message: String) async {
        await MainActor.run { controller?.activePane.report(message) }
    }
}

extension MainWindowController {
    func askHostKey(_ question: HostKeyQuestion) async -> HostKeyAnswer {
        guard let window else { return .cancel }
        let alert = NSAlert()
        switch question.reason {
        case .unknown:
            alert.messageText = "Basil has not connected to \(question.host) before. Trust it?"
            alert.informativeText = """
            Its \(question.keyType) key fingerprint is \(question.fingerprint).
            Check that this matches the server's key before you trust it. Remembered keys are saved in \(question.knownHostsFile).
            """
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Trust and Remember")
            alert.addButton(withTitle: "Trust Once")
            alert.addButton(withTitle: "Cancel")
            return switch await present(alert, in: window) {
            case 0: .trustAndRemember
            case 1: .trustOnce
            default: .cancel
            }
        case .changed:
            alert.messageText = "Warning: the host key of \(question.host) has changed."
            alert.informativeText = """
            Someone may be intercepting the connection, or the server was set up again. Do not connect unless you know why the key changed.
            The new \(question.keyType) key fingerprint is \(question.fingerprint). The old key is in \(question.knownHostsFile).
            """
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Connect Once")
            alert.addButton(withTitle: "Replace Key and Connect")
            return switch await present(alert, in: window) {
            case 1: .trustOnce
            case 2: .trustAndRemember
            default: .cancel
            }
        }
    }

    func askCertificate(_ question: CertificateQuestion) async -> HostKeyAnswer {
        guard let window else { return .cancel }
        let alert = NSAlert()
        var details = "Issued to \(question.subject) by \(question.issuer)"
        if !question.validity.isEmpty { details += ", \(question.validity)" }
        details += ". Fingerprint \(question.fingerprint)."
        switch question.reason {
        case .untrusted(let why):
            alert.messageText = "macOS does not trust the certificate of \(question.host). Connect anyway?"
            alert.informativeText = """
            \(why)
            \(details)
            Check the fingerprint with the server's administrator before you trust it. Remembered certificates are saved in \(question.trustFile).
            """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Trust and Remember")
            alert.addButton(withTitle: "Trust Once")
            alert.addButton(withTitle: "Cancel")
            return switch await present(alert, in: window) {
            case 0: .trustAndRemember
            case 1: .trustOnce
            default: .cancel
            }
        case .changed(let why):
            alert.messageText = "Warning: the certificate of \(question.host) has changed."
            alert.informativeText = """
            Someone may be intercepting the connection, or the server got a new certificate. Do not connect unless you know why it changed.
            \(why)
            The new certificate: \(details)
            """
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Connect Once")
            alert.addButton(withTitle: "Replace Certificate and Connect")
            return switch await present(alert, in: window) {
            case 1: .trustOnce
            case 2: .trustAndRemember
            default: .cancel
            }
        }
    }

    func askSecret(_ request: SecretRequest) async -> SecretAnswer? {
        guard let window else { return nil }
        let alert = NSAlert()
        let fieldLabel: String
        switch request.kind {
        case .password:
            fieldLabel = "Password"
            alert.messageText = request.retry ? "Wrong password for \(request.account). Try again." : "Password for \(request.account):"
        case .passphrase(let keyFile):
            let name = (keyFile as NSString).lastPathComponent
            fieldLabel = "Passphrase"
            alert.messageText = request.retry ? "Wrong passphrase for the key \(name). Try again." : "Passphrase for the key \(name):"
            alert.informativeText = "To log in to \(request.account) with \(keyFile)."
        case .serverPrompt(let prompt):
            fieldLabel = prompt.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            alert.messageText = prompt
            alert.informativeText = "\(request.account) asks this to log in."
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let width: CGFloat = 300
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: width, height: 24))
        field.setAccessibilityLabel(fieldLabel)
        let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: width, height: 22)
        remember.state = .off
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 54))
        accessory.addSubview(field)
        if request.keychainKey != nil { accessory.addSubview(remember) } else { field.frame.origin.y = 0; accessory.frame.size.height = 24 }
        alert.accessoryView = accessory
        alert.window.initialFirstResponder = field
        let confirmed: Bool = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { response in
                continuation.resume(returning: response == .alertFirstButtonReturn)
            }
            alert.window.makeFirstResponder(field)
        }
        guard confirmed else { return nil }
        return SecretAnswer(secret: field.stringValue, remember: request.keychainKey != nil && remember.state == .on)
    }

    // MARK: Connecting

    /// Connects in the active pane and shows the start folder. Spoken: "Connecting to ..." when it
    /// takes longer than a second, then "Connected to erion@example.com".
    func connect(_ target: RemoteTarget) {
        let pane = activePane
        let name = target.address
        guard providers.connector(for: target.service) != nil else {
            return pane.report("Basil cannot connect with \(target.service.rawValue.uppercased()) yet")
        }
        pane.report("Connecting to \(name)")
        let slow = Task { [weak self] in
            try await Task.sleep(for: .seconds(1))
            self?.announce("Connecting to \(name)")
        }
        Task {
            defer { slow.cancel() }
            do {
                let start = try await providers.connect(target, prompts: remotePrompts)
                slow.cancel()
                let title = (try? providers.provider(for: start.location) as? any ConnectedProvider)?.connectionTitle ?? name
                pane.navigate(to: start)
                announce("Connected to \(title)")
            } catch is RemoteCancelled {
                pane.report("Connection cancelled")
                announce("Connection cancelled")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                pane.report(message)
                announce(message)
            }
        }
    }

    /// The connection the active pane shows, if any.
    var activeConnection: (any ConnectedProvider)? {
        let location = activePane.model.directory.outermostContainer.location
        return try? providers.provider(for: location) as? any ConnectedProvider
    }

    /// Net > Disconnect: closes the active pane's connection. Panes and tabs that show it go to
    /// the home folder.
    func disconnectActive() {
        guard let connection = activeConnection else { return announce("This pane is not connected to a server") }
        disconnect(connection)
    }

    func disconnect(_ connection: any ConnectedProvider) {
        let location = connection.location
        let home = VFSPath.local(FileManager.default.homeDirectoryForCurrentUser.path)
        for pane in [left, right] {
            pane.leaveConnection(location, for: home)
        }
        let title = connection.connectionTitle
        Task {
            await providers.disconnect(location)
            announce("Disconnected from \(title)")
        }
    }

    /// Panes showing a remote folder reread after an operation: remote folders are not watched.
    func rereadRemotePanes() {
        for pane in [left, right] where !pane.model.isLoading {
            let location = pane.model.directory.outermostContainer.location
            if (try? providers.provider(for: location)) is any ConnectedProvider {
                pane.model.reload(cursor: pane.cursorPath)
            }
        }
    }

    // MARK: Cmd+K

    func showConnections() {
        guard let window else { return }
        let model = ConnectionsModel(saved: settings.settings.connections,
                                     services: providers.remoteConnectors.map(ConnectionsModel.Service.init),
                                     aliases: providers.remoteConnectors.flatMap { $0.knownHosts() })
        let hosting = NSHostingController(rootView: ConnectionsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        hosting.view.setAccessibilityLabel("Connections")
        let sheet = EscapableSheet(contentViewController: hosting)
        sheet.title = "Connect to Server"
        let pane = activePane
        sheet.onCancel = { model.cancel() }
        model.onSave = { [weak self] saved in self?.settings.settings.connections = saved }
        model.onClose = { [weak window, weak sheet] in
            if let sheet { window?.endSheet(sheet) }
        }
        model.onConnect = { [weak self, weak window, weak sheet] target in
            if let sheet { window?.endSheet(sheet) }
            self?.connect(target)
        }
        model.announce = { [weak self] message in self?.announce(message) }
        window.beginSheet(sheet) { [weak window] _ in
            window?.makeFirstResponder(pane.tableView)
        }
    }
}

extension PaneViewController {
    /// The pane and its tabs leave a connection that is being closed.
    func leaveConnection(_ location: ProviderLocation, for home: VFSPath) {
        func inside(_ path: VFSPath) -> Bool { path.outermostContainer.location == location }
        for i in tabs.indices where i != activeTabIndex && inside(tabs[i].directory) {
            tabs[i].directory = home
            tabs[i].cursor = nil
        }
        if inside(model.directory) { navigate(to: home) }
    }
}

// MARK: The manager

@MainActor @Observable
final class ConnectionsModel {
    /// What the editor shows for one connector.
    struct Service: Equatable {
        let id: ProviderID
        let name: String
        let defaultPort: Int
        let logins: [RemoteLogin]
        let automaticLoginTitle: String
        let hostPlaceholder: String
        let userPlaceholder: String
        let options: [RemoteOption]

        init(_ connector: any RemoteConnector) {
            id = connector.service
            name = connector.displayName
            defaultPort = connector.defaultPort
            logins = connector.logins
            automaticLoginTitle = connector.automaticLoginTitle
            hostPlaceholder = connector.hostPlaceholder
            userPlaceholder = connector.userPlaceholder
            options = connector.options
        }
    }

    var saved: [SavedConnection]
    var selection: UUID?
    var quick = ""
    /// The connection being edited (new or existing), shown while `isEditing`. Never optional:
    /// SwiftUI crashes reading a Binding(optional) that a field still holds after it became nil.
    var draft = ConnectionDraft(SavedConnection(name: "", target: RemoteTarget(service: ProviderID("sftp"), host: "")), isNew: true)
    var isEditing = false
    let services: [Service]
    let aliases: [String]

    @ObservationIgnored var onConnect: ((RemoteTarget) -> Void)?
    @ObservationIgnored var onSave: (([SavedConnection]) -> Void)?
    @ObservationIgnored var onClose: (() -> Void)?
    @ObservationIgnored var announce: ((String) -> Void)?

    init(saved: [SavedConnection], services: [Service], aliases: [String]) {
        self.saved = saved
        self.services = services
        self.aliases = aliases
        selection = saved.first?.id
    }

    var defaultService: ProviderID { services.first?.id ?? ProviderID("sftp") }

    func service(_ id: ProviderID) -> Service? { services.first { $0.id == id } }

    var selected: SavedConnection? { saved.first { $0.id == selection } }

    var quickTarget: RemoteTarget? { RemoteTarget.parse(quick, defaultService: defaultService) }

    func connectQuick() {
        guard let target = quickTarget else { return announce?("Type an address such as user@host") ?? () }
        onConnect?(target)
    }

    func connectSelected() {
        guard let connection = selected else { return }
        onConnect?(connection.target)
    }

    func newConnection() {
        let target = quickTarget ?? RemoteTarget(service: defaultService, host: "")
        draft = ConnectionDraft(SavedConnection(name: "", target: target), isNew: true)
        isEditing = true
    }

    func editSelected() {
        guard let connection = selected else { return }
        draft = ConnectionDraft(connection, isNew: false)
        isEditing = true
    }

    func duplicateSelected() {
        guard let connection = selected, let index = saved.firstIndex(where: { $0.id == connection.id }) else { return }
        let copy = SavedConnection(name: connection.name.isEmpty ? "" : "\(connection.name) copy", target: connection.target)
        saved.insert(copy, at: index + 1)
        selection = copy.id
        onSave?(saved)
        announce?("Duplicated \(connection.title)")
    }

    func deleteSelected() {
        guard let connection = selected, let index = saved.firstIndex(where: { $0.id == connection.id }) else { return }
        saved.remove(at: index)
        selection = saved.indices.contains(index) ? saved[index].id : saved.last?.id
        onSave?(saved)
        announce?("Deleted \(connection.title)")
    }

    func move(by offset: Int) {
        guard let id = selection, let i = saved.firstIndex(where: { $0.id == id }), saved.indices.contains(i + offset) else { return }
        saved.swapAt(i, i + offset)
        onSave?(saved)
    }

    func finishEditing(save: Bool) {
        guard isEditing else { return }
        isEditing = false
        guard save, let connection = draft.connection(service: service(draft.service)) else { return }
        if let index = saved.firstIndex(where: { $0.id == connection.id }) {
            saved[index] = connection
        } else {
            saved.append(connection)
        }
        selection = connection.id
        onSave?(saved)
        announce?("Saved \(connection.title)")
    }

    /// Escape: leaves the editor, or closes the manager.
    func cancel() {
        if isEditing { finishEditing(save: false) } else { onClose?() }
    }
}

/// The editor's fields as typed.
struct ConnectionDraft {
    enum Auth: String, CaseIterable, Identifiable {
        case automatic, password, keyFile
        var id: String { rawValue }
        var login: RemoteLogin {
            switch self {
            case .automatic: .automatic
            case .password: .password
            case .keyFile: .keyFile
            }
        }
        func title(_ service: ConnectionsModel.Service?) -> String {
            switch self {
            case .automatic: service?.automaticLoginTitle ?? "Automatic"
            case .password: "Password"
            case .keyFile: "Key file"
            }
        }
    }

    let id: UUID
    let isNew: Bool
    var name: String
    var service: ProviderID
    var host: String
    var port: String
    var user: String
    var path: String
    var auth: Auth
    var keyFile: String
    /// The service's own options as set (missing: the default).
    var options: [String: String]

    init(_ connection: SavedConnection, isNew: Bool) {
        id = connection.id
        self.isNew = isNew
        name = connection.name
        service = connection.target.service
        host = connection.target.host
        port = connection.target.port.map(String.init) ?? ""
        user = connection.target.user ?? ""
        path = connection.target.path ?? ""
        switch connection.target.authentication {
        case .automatic: auth = .automatic; keyFile = ""
        case .password: auth = .password; keyFile = ""
        case .keyFile(let file): auth = .keyFile; keyFile = file
        }
        options = connection.target.options ?? [:]
    }

    /// The login actually used: the chosen one when the service offers it, else its first.
    func effectiveAuth(_ service: ConnectionsModel.Service?) -> Auth {
        guard let logins = service?.logins, !logins.contains(auth.login), let first = logins.first else { return auth }
        return Auth.allCases.first { $0.login == first } ?? auth
    }

    func option(_ option: RemoteOption) -> String {
        options[option.key] ?? option.value(in: RemoteTarget(service: service, host: ""))
    }

    func problem(_ service: ConnectionsModel.Service?) -> String? {
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Type the server's host name or address." }
        let trimmedPort = port.trimmingCharacters(in: .whitespaces)
        if !trimmedPort.isEmpty, Int(trimmedPort).map({ (1...65535).contains($0) }) != true { return "The port must be a number from 1 to 65535." }
        if effectiveAuth(service) == .keyFile, keyFile.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose the private key file." }
        return nil
    }

    func connection(service info: ConnectionsModel.Service?) -> SavedConnection? {
        guard problem(info) == nil else { return nil }
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        let authentication: RemoteTarget.Authentication = switch effectiveAuth(info) {
        case .automatic: .automatic
        case .password: .password
        case .keyFile: .keyFile(trim(keyFile))
        }
        var target = RemoteTarget(service: service, host: trim(host), port: Int(trim(port)),
                                  user: trim(user).isEmpty ? nil : trim(user),
                                  path: trim(path).isEmpty ? nil : trim(path), authentication: authentication)
        // Only this service's options, and only those that differ from their defaults.
        var kept: [String: String] = [:]
        for option in info?.options ?? [] {
            if let value = options[option.key], value != option.value(in: RemoteTarget(service: service, host: "")) {
                kept[option.key] = value
            }
        }
        target.options = kept.isEmpty ? nil : kept
        return SavedConnection(id: id, name: trim(name), target: target)
    }
}

struct ConnectionsView: View {
    @Bindable var model: ConnectionsModel

    var body: some View {
        Group {
            if model.isEditing {
                ConnectionEditor(model: model)
            } else {
                ConnectionList(model: model)
            }
        }
        .padding(16)
        .frame(width: 560)
    }
}

struct ConnectionList: View {
    @Bindable var model: ConnectionsModel
    @FocusState private var quickFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to Server").font(.headline)
            HStack {
                TextField("Address", text: $model.quick, prompt: Text("user@host:port/folder"))
                    .accessibilityLabel("Address")
                    .focused($quickFocused)
                    .onSubmit { model.connectQuick() }
                Button("Quick Connect") { model.connectQuick() }
                    .disabled(model.quickTarget == nil)
            }
            if model.services.count > 1 {
                Text("Addresses can start with \(model.services.map { "\($0.id.rawValue):// for \($0.name)" }.joined(separator: ", ")). Without one, \(model.services.first?.name ?? "") is used.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryTextColor)
            }
            if !model.aliases.isEmpty {
                Text("Host aliases from ~/.ssh/config work too: \(model.aliases.prefix(8).joined(separator: ", ")).")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryTextColor)
            }
            Text("Saved connections").font(.subheadline)
            List(selection: $model.selection) {
                ForEach(model.saved) { connection in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.title)
                        if !connection.name.isEmpty {
                            Text(connection.target.address)
                                .font(.callout)
                                .foregroundStyle(Theme.secondaryTextColor)
                        }
                    }
                    .tag(connection.id)
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "Connect") { model.selection = connection.id; model.connectSelected() }
                    .accessibilityAction(named: "Edit") { model.selection = connection.id; model.editSelected() }
                    .accessibilityAction(named: "Move Up") { model.selection = connection.id; model.move(by: -1) }
                    .accessibilityAction(named: "Move Down") { model.selection = connection.id; model.move(by: 1) }
                    .accessibilityAction(named: "Delete") { model.selection = connection.id; model.deleteSelected() }
                }
            }
            .accessibilityLabel("Saved connections")
            .frame(minHeight: 160)
            .onKeyPress(.return) {
                model.connectSelected()
                return .handled
            }
            if model.saved.isEmpty {
                Text("No saved connections. Use New to add one.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryTextColor)
            }
            HStack {
                Button("New") { model.newConnection() }
                Button("Edit") { model.editSelected() }.disabled(model.selected == nil)
                Button("Duplicate") { model.duplicateSelected() }.disabled(model.selected == nil)
                Button("Delete") { model.deleteSelected() }.disabled(model.selected == nil)
                Spacer()
                Button("Close") { model.onClose?() }
                    .keyboardShortcut(.cancelAction)
                Button("Connect") { model.connectSelected() }
                    .disabled(model.selected == nil)
            }
        }
        .onAppear { quickFocused = model.saved.isEmpty }
    }
}

struct ConnectionEditor: View {
    @Bindable var model: ConnectionsModel
    @FocusState private var hostFocused: Bool

    var body: some View {
        let binding = $model.draft
        let draft = model.draft
        let service = model.service(draft.service)
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isNew ? "New Connection" : "Edit \(draft.name.isEmpty ? draft.host : draft.name)").font(.headline)
            Form {
                TextField("Name", text: binding.name, prompt: Text("Optional"))
                    .accessibilityLabel("Name")
                if model.services.count > 1 {
                    Picker("Protocol", selection: binding.service) {
                        ForEach(model.services, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityLabel("Protocol")
                }
                TextField("Host", text: binding.host, prompt: Text(service?.hostPlaceholder ?? "Name or address"))
                    .accessibilityLabel("Host")
                    .focused($hostFocused)
                TextField("Port", text: binding.port, prompt: Text(defaultPortText(draft.service)))
                    .accessibilityLabel("Port")
                TextField("User", text: binding.user, prompt: Text(service?.userPlaceholder ?? NSUserName()))
                    .accessibilityLabel("User")
                TextField("Start folder", text: binding.path, prompt: Text("Home folder on the server"))
                    .accessibilityLabel("Start folder")
                let logins = ConnectionDraft.Auth.allCases.filter { service?.logins.contains($0.login) ?? true }
                if logins.count > 1 {
                    Picker("Log in with", selection: binding.auth) {
                        ForEach(logins) { Text($0.title(service)).tag($0) }
                    }
                    .accessibilityLabel("Log in with")
                }
                if draft.effectiveAuth(service) == .keyFile {
                    HStack {
                        TextField("Key file", text: binding.keyFile, prompt: Text("~/.ssh/id_ed25519"))
                            .accessibilityLabel("Key file")
                        Button("Choose Key File") {
                            if let path = chooseKeyFile() { binding.wrappedValue.keyFile = path }
                        }
                    }
                }
                ForEach(service?.options ?? []) { option in
                    optionControl(option, binding)
                    if let help = option.help {
                        Text(help)
                            .font(.callout)
                            .foregroundStyle(Theme.secondaryTextColor)
                    }
                }
                Text("Passwords and passphrases are asked for when connecting and can be remembered in the Keychain.")
                    .font(.callout)
                    .foregroundStyle(Theme.secondaryTextColor)
                if let problem = draft.problem(service) {
                    Text(problem)
                        .font(.callout)
                        .foregroundStyle(Theme.errorTextColor)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { model.finishEditing(save: false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { model.finishEditing(save: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.problem(service) != nil)
            }
        }
        .onAppear { hostFocused = true }
    }

    @ViewBuilder
    private func optionControl(_ option: RemoteOption, _ binding: Binding<ConnectionDraft>) -> some View {
        switch option.kind {
        case .toggle:
            Toggle(option.title, isOn: Binding(
                get: { binding.wrappedValue.option(option) == "true" },
                set: { binding.wrappedValue.options[option.key] = $0 ? "true" : "false" }))
                .accessibilityLabel(option.title)
        case .choice(let choices, _):
            Picker(option.title, selection: Binding(
                get: { binding.wrappedValue.option(option) },
                set: { binding.wrappedValue.options[option.key] = $0 })) {
                ForEach(choices, id: \.value) { Text($0.title).tag($0.value) }
            }
            .accessibilityLabel(option.title)
        }
    }

    private func defaultPortText(_ service: ProviderID) -> String {
        model.services.first { $0.id == service }.map { "\($0.defaultPort)" } ?? "Default"
    }

    private func chooseKeyFile() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose a private key"
        panel.prompt = "Choose"
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return url.path.hasPrefix(home + "/") ? "~" + url.path.dropFirst(home.count) : url.path
    }
}
