import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Synchronization

/// A loaded plugin: its Lua state and everything it registered (commands, menu items,
/// columns, providers, placeholders, operation kinds), so turning it off takes all of it away.
///
/// Every Basil function a plugin calls arrives in `handle` on the plugin's own queue. Work for
/// the main actor (registries, the panes, dialogs) and for providers waits there without
/// holding the queue (`APIResult.wait`).
public final class Plugin: @unchecked Sendable {
    public let manifest: PluginManifest
    public let folder: URL
    public let granted: Set<PluginPermission>
    let registry: ProviderRegistry
    nonisolated(unsafe) weak var host: (any PluginHost)?
    nonisolated(unsafe) let commands: CommandRegistry
    private(set) var runtime: LuaRuntime!
    let onLog: @Sendable (String) -> Void

    struct State {
        var places: [String: ProviderLocation] = ["local": .local]
        var tokens: [ProviderLocation: String] = [.local: "local"]
        var commands: [CommandID] = []
        var columns: [ColumnID] = []
        var providers: [ProviderLocation] = []
        var placeholders: [String] = []
        var kinds: [OperationKind] = []
        var contexts: [Int: OperationContext] = [:]
        var next = 1
    }
    let state = Mutex(State())

    static let functions = ["info", "log", "module", "command", "column", "provider", "placeholder", "operation",
                            "copy", "move", "delete", "mkdir", "rename", "announce", "navigate", "pane",
                            "ask", "confirm", "choose", "list", "stat", "read", "shell", "http",
                            "opProgress", "opLog", "opItems", "opCheckpoint"]

    init(manifest: PluginManifest, folder: URL, granted: Set<PluginPermission>, registry: ProviderRegistry,
         commands: CommandRegistry, host: (any PluginHost)?, log: @escaping @Sendable (String) -> Void) throws {
        self.manifest = manifest
        self.folder = folder
        self.granted = granted
        self.registry = registry
        self.commands = commands
        self.host = host
        onLog = log
        runtime = try LuaRuntime(name: manifest.name, folder: folder, allowFFI: granted.contains(.ffi),
                                 functions: Self.functions, log: log) { [unowned self] name, args in
            self.handle(name, args)
        }
    }

    /// Runs the plugin's main file.
    func start() async throws {
        try await runtime.run(file: folder.appendingPathComponent(manifest.entry))
    }

    /// Takes away everything the plugin registered and closes its Lua state.
    @MainActor
    func stop() {
        let s = state.withLock { $0 }
        for id in s.commands {
            commands.unregister(id)
            commands.menus.remove(id)
        }
        for column in s.columns {
            registry.unregisterAnnotators(of: column)
            ColumnCatalog.unregister(column)
        }
        for location in s.providers { registry.unregister(location) }
        for name in s.placeholders { MultiRenamePlaceholders.unregister(name) }
        for kind in s.kinds { OperationKindCatalog.unregister(kind) }
        state.withLock { $0 = State() }
        runtime.close()
        host?.pluginsChanged()
    }

    /// The id of something the plugin registers, in Basil's name space ("plugin.<plugin>.<id>").
    func scoped(_ id: String) -> String { "plugin.\(manifest.id).\(id)" }

    static func validID(_ id: String?) -> String? {
        guard let id, id.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else { return nil }
        return id
    }

    /// Reports an error of the plugin's Lua code: in its log, and said in words.
    func report(_ error: Error, while doing: String) {
        let text = (error as? PluginError)?.message ?? error.localizedDescription
        onLog("Error \(doing): \(text)")
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.host?.announce("\(self.manifest.name): \(first)")
        }
    }

    // MARK: Paths and items

    func token(_ location: ProviderLocation) -> String {
        state.withLock { s in
            if let token = s.tokens[location] { return token }
            let token = "p\(s.next)"
            s.next += 1
            s.tokens[location] = token
            s.places[token] = location
            return token
        }
    }

    /// A path from Lua: a table { place =, path = } (an item works too), or an absolute local path.
    func path(_ value: LuaValue) -> VFSPath? {
        if let text = value.string, text.hasPrefix("/") { return .local(text) }
        guard let path = value["path"].string, path.hasPrefix("/") else { return nil }
        let place = value["place"].string ?? "local"
        guard let location = state.withLock({ $0.places[place] }) else { return nil }
        return VFSPath(location: location, path: path)
    }

    func paths(_ value: LuaValue) -> [VFSPath]? {
        if let one = path(value) { return [one] }
        let list = value.list.compactMap(path)
        return list.isEmpty || list.count != value.list.count ? nil : list
    }

    func value(_ path: VFSPath) -> LuaValue {
        .record(["place": .string(token(path.location)), "path": .string(path.path)])
    }

    static func kindName(_ kind: FileItem.Kind) -> String {
        switch kind {
        case .file: "file"
        case .directory: "folder"
        case .symlink(target: .directory): "folderlink"
        case .symlink: "link"
        case .other: "other"
        }
    }

    func value(_ item: FileItem) -> LuaValue {
        var fields: [String: LuaValue] = ["place": .string(token(item.path.location)), "path": .string(item.path.path),
                                          "name": .string(item.name), "kind": .string(Self.kindName(item.kind)),
                                          "hidden": .bool(item.isHidden)]
        if let size = item.size { fields["size"] = .number(Double(size)) }
        if let modified = item.modified { fields["modified"] = .number(modified.timeIntervalSince1970) }
        if let created = item.created { fields["created"] = .number(created.timeIntervalSince1970) }
        return .record(fields)
    }

    static func describe(_ error: Error) -> String {
        if let vfs = error as? VFSError { return vfs.localizedDescription }
        return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: The API

    func handle(_ name: String, _ a: [LuaValue]) -> APIResult {
        let first = a.first ?? .nil
        switch name {
        case "info":
            return .values([.record(["id": .string(manifest.id), "name": .string(manifest.name),
                                     "version": .string(manifest.version), "folder": .string(folder.path)])])
        case "log":
            onLog(first.string ?? "")
            return .values([])
        case "module": return module(first.string)
        case "command": return command(first)
        case "column": return column(first)
        case "provider": return provider(first)
        case "placeholder": return placeholder(first)
        case "operation": return operation(first)
        case "copy", "move":
            guard let sources = paths(first), let target = path(a.count > 1 ? a[1] : .nil) else {
                return .failure("basil.\(name) needs the items and a target folder")
            }
            return onMain { host in host.transfer(sources, to: target, move: name == "move") }
        case "delete":
            guard let items = paths(first) else { return .failure("basil.delete needs the items") }
            let trash = (a.count > 1 ? a[1]["trash"].bool : nil) ?? true
            return onMain { host in host.delete(items, toTrash: trash) }
        case "mkdir":
            guard let path = path(first) else { return .failure("basil.mkdir needs a path") }
            return onMain { host in host.makeDirectory(path) }
        case "rename":
            guard let path = path(first), let newName = (a.count > 1 ? a[1] : .nil).string, !newName.isEmpty,
                  !newName.contains("/") else { return .failure("basil.rename needs an item and a new name without slashes") }
            return onMain { host in host.rename(path, to: newName) }
        case "announce":
            let text = first.string ?? ""
            Task { @MainActor [weak self] in self?.host?.announce(text) }
            return .values([])
        case "navigate":
            guard let path = path(first) else { return .failure("basil.navigate needs a folder") }
            return onMain { host in host.navigate(to: path) }
        case "pane": return pane(first.string ?? "active")
        case "ask", "confirm", "choose": return dialog(name, a)
        case "list", "stat", "read": return files(name, a)
        case "shell": return shell(a)
        case "http": return http(first)
        case "opProgress", "opLog", "opItems", "opCheckpoint": return operationCall(name, a)
        default: return .failure("basil.\(name) is not available")
        }
    }

    /// Runs `body` on the main actor and answers with nothing.
    private func onMain(_ body: @escaping @MainActor (any PluginHost) -> Void) -> APIResult {
        .wait { @Sendable [weak self] in
            await MainActor.run {
                guard let host = self?.host else { return .failure("Basil's window is not open") }
                body(host)
                return .values([])
            }
        }
    }

    // MARK: require

    private func module(_ name: String?) -> APIResult {
        guard let name, name.range(of: #"^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$"#, options: .regularExpression) != nil else {
            return .failure("module names are words separated by dots, such as util or lib.text")
        }
        let relative = name.replacingOccurrences(of: ".", with: "/") + ".lua"
        let file = folder.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: file.path) else {
            return .failure("module \(name) not found (\(relative) in the plugin's folder)")
        }
        // A link inside the folder may not lead out of it.
        func real(_ url: URL) -> String {
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
            return realpath(url.path, &buffer).map { String(cString: $0) } ?? url.path
        }
        guard real(file).hasPrefix(real(folder) + "/") else { return .failure("module \(name) is outside the plugin's folder") }
        guard let source = try? String(contentsOf: file, encoding: .utf8) else {
            return .failure("module \(name) could not be read as UTF-8 text")
        }
        return .values([.string(source), .string("@" + relative)])
    }

    // MARK: Commands

    private func command(_ spec: LuaValue) -> APIResult {
        guard let id = Self.validID(spec["id"].string), let title = spec["title"].string, !title.isEmpty,
              let run = spec["run"].function else {
            return .failure("basil.command needs id (letters, digits, dots, dashes), title and run")
        }
        var keys: [KeyChord] = []
        for text in spec["keys"].list.compactMap(\.string) + [spec["keys"].string].compactMap({ $0 }) {
            guard let chord = KeyChord(parsing: text) else { return .failure("basil.command: \(text) is not a key Basil knows") }
            keys.append(chord)
        }
        let menuPath = (spec["menu"].string ?? "Commands/Plugins").split(separator: "/").map(String.init)
        let inContext = spec["context"].bool ?? false
        let when = spec["when"].string ?? "always"
        guard ["always", "items", "files", "folders"].contains(when) else {
            return .failure("basil.command: when is always, items, files or folders")
        }
        let commandID = CommandID(rawValue: scoped(id))
        let chords = keys
        return .wait { @Sendable [weak self] in
            await self?.register(commandID, title: title, keys: chords, when: when, menuPath: menuPath,
                                 inContext: inContext, run: run) ?? .failure("plugin turned off")
        }
    }

    @MainActor
    private func register(_ commandID: CommandID, title: String, keys: [KeyChord], when: String, menuPath: [String],
                          inContext: Bool, run: Int32) -> APIResult {
        var applicable: (@MainActor (any WorkspaceContext) -> Bool)?
        if when != "always" {
            applicable = { context in Self.fits(context.targetItems, when) }
        }
        let command = CommandRegistry.Command(id: commandID, title: title, defaultKeys: keys, isApplicable: applicable) {
            [weak self] context in
            self?.runCommand(run, title: title, in: context)
        }
        commands.register(command)
        if let menu = menuPath.first {
            commands.menus.add([.command(commandID)], to: menu, submenu: Array(menuPath.dropFirst()))
        }
        if inContext { commands.menus.addToContextMenu([.command(commandID)], submenu: ["Plugins"]) }
        state.withLock { $0.commands.append(commandID) }
        host?.pluginsChanged()
        return .values([])
    }

    static func fits(_ items: [FileItem], _ when: String) -> Bool {
        switch when {
        case "files": return !items.isEmpty && items.allSatisfy { $0.kind == .file }
        case "folders": return !items.isEmpty && items.allSatisfy(\.isDirectoryLike)
        default: return !items.isEmpty
        }
    }

    /// The command's argument: the active pane (folder, cursor, selected or cursor items) and
    /// the other pane's folder.
    @MainActor
    func context(_ workspace: any WorkspaceContext) -> LuaValue {
        var pane: [String: LuaValue] = ["items": .array(workspace.targetItems.map(value))]
        if let folder = workspace.activeDirectory { pane["folder"] = value(folder) }
        if let cursor = workspace.cursorItem { pane["cursor"] = value(cursor) }
        var other: [String: LuaValue] = [:]
        if let folder = host?.otherDirectory ?? workspace.otherDirectory { other["folder"] = value(folder) }
        return .record(["pane": .record(pane), "other": .record(other)])
    }

    @MainActor
    private func runCommand(_ run: Int32, title: String, in workspace: any WorkspaceContext) {
        let argument = context(workspace)
        let runtime = runtime!
        Task {
            do { _ = try await runtime.call(run, [argument]) } catch { report(error, while: "running \(title)") }
        }
    }

    private func pane(_ which: String) -> APIResult {
        .wait { @Sendable [weak self] in
            await MainActor.run {
                guard let self, let workspace = self.host?.workspace else { return .values([.nil]) }
                let context = self.context(workspace)
                return .values([which == "other" ? context["other"] : context["pane"]])
            }
        }
    }

    // MARK: Columns

    private func column(_ spec: LuaValue) -> APIResult {
        guard let id = Self.validID(spec["id"].string), let title = spec["title"].string, !title.isEmpty,
              let fill = spec["fill"].function else {
            return .failure("basil.column needs id, title and fill")
        }
        let columnID = ColumnID(rawValue: scoped(id))
        let width = spec["width"].number ?? 90
        let alignment: ColumnDefinition.Alignment = spec["align"].string == "right" ? .trailing : .leading
        ColumnCatalog.register(ColumnDefinition(id: columnID, title: title, defaultWidth: width, alignment: alignment,
                                                sortKey: nil, onlyWhenAnnotated: true) { item, context in
            context.annotation(columnID, for: item) ?? ""
        })
        registry.register(annotator: PluginColumnAnnotator(column: columnID, plugin: self, fill: fill))
        state.withLock { $0.columns.append(columnID) }
        return onMain { host in host.pluginsChanged() }
    }

    // MARK: Providers

    private func provider(_ spec: LuaValue) -> APIResult {
        guard let id = Self.validID(spec["id"].string), let title = spec["title"].string, !title.isEmpty,
              let list = spec["list"].function else {
            return .failure("basil.provider needs id, title and list")
        }
        let location = ProviderLocation(provider: ProviderID(scoped(id)))
        let provider = LuaProvider(location: location, title: title, plugin: self, list: list,
                                   read: spec["read"].function, item: spec["item"].function)
        registry.register(provider)
        state.withLock { $0.providers.append(location) }
        return .values([.string(token(location))])
    }

    // MARK: Multi-Rename placeholders

    private func placeholder(_ spec: LuaValue) -> APIResult {
        guard let name = spec["name"].string, name.range(of: #"^[A-Za-z][A-Za-z0-9_]*$"#, options: .regularExpression) != nil,
              let valueFunction = spec["value"].function else {
            return .failure("basil.placeholder needs name (letters, digits, underscores) and value")
        }
        let runtime = runtime!
        MultiRenamePlaceholders.register(.init(name: name, title: spec["title"].string ?? name) { [weak self] input in
            guard let self else { return "" }
            let argument = self.value(input.item)
            switch runtime.callNow(valueFunction, [argument, .number(Double(input.index + 1))]) {
            case .success(let values): return values.first?.string ?? ""
            case .failure: return ""
            }
        })
        state.withLock { $0.placeholders.append(name) }
        return .values([])
    }

    // MARK: Operations

    private func operation(_ spec: LuaValue) -> APIResult {
        guard let title = spec["title"].string, !title.isEmpty, let run = spec["run"].function else {
            return .failure("basil.operation needs title and run")
        }
        var kind = OperationKind.other
        var kindInfo: OperationKindInfo?
        if let kindName = spec["kind"].string, !kindName.isEmpty {
            let slug = kindName.lowercased().filter { $0.isLetter || $0.isNumber }
            kind = OperationKind(rawValue: scoped(slug.isEmpty ? "operation" : slug))
            kindInfo = OperationKindInfo(kind: kind, name: kindName, pastTense: "done")
        }
        let operation = PluginOperation(title: title, kind: kind, plugin: self, run: run)
        return .wait { @Sendable [weak self] in
            await MainActor.run {
                guard let self, let host = self.host else { return .failure("Basil's window is not open") }
                if let kindInfo {
                    OperationKindCatalog.register(kindInfo)
                    self.state.withLock { s in if !s.kinds.contains(kindInfo.kind) { s.kinds.append(kindInfo.kind) } }
                }
                host.enqueue(operation)
                return .values([])
            }
        }
    }

    func add(_ context: OperationContext) -> Int {
        state.withLock { s in
            let id = s.next
            s.next += 1
            s.contexts[id] = context
            return id
        }
    }

    func removeContext(_ id: Int) { _ = state.withLock { $0.contexts.removeValue(forKey: id) } }

    private func operationCall(_ name: String, _ a: [LuaValue]) -> APIResult {
        guard let id = a.first?.number.map(Int.init), let context = state.withLock({ $0.contexts[id] }) else {
            return .failure("the operation has ended")
        }
        let rest = Array(a.dropFirst())
        switch name {
        case "opProgress":
            context.progress(rest.first?.number, (rest.count > 1 ? rest[1] : .nil).string ?? "")
        case "opLog":
            context.log(rest.first?.string ?? "")
        case "opItems":
            context.items(done: Int(rest.first?.number ?? 0), total: Int((rest.count > 1 ? rest[1] : .nil).number ?? 0))
        default:
            return .wait {
                do {
                    try await context.checkpoint()
                    return .values([])
                } catch {
                    return .failure("cancelled")
                }
            }
        }
        return .values([])
    }

    // MARK: Dialogs

    private func dialog(_ kind: String, _ a: [LuaValue]) -> APIResult {
        let message = a.first?.string ?? ""
        let second = a.count > 1 ? a[1] : .nil
        let request: PluginDialog
        switch kind {
        case "ask": request = .text(plugin: manifest.name, message: message, text: second.string ?? "")
        case "confirm": request = .confirm(plugin: manifest.name, message: message, button: second.string ?? "OK")
        default:
            let options = second.list.compactMap(\.string)
            guard !options.isEmpty else { return .failure("basil.choose needs a list of options") }
            request = .choose(plugin: manifest.name, message: message, options: options)
        }
        return .wait { @Sendable [weak self] in
            switch await Self.ask(self, request) {
            case .text(let text): return .values([.string(text)])
            case .confirmed: return .values([.bool(true)])
            case .chosen(let index): return .values([.number(Double(index + 1))])
            case .cancelled, nil: return .values([kind == "confirm" ? .bool(false) : .nil])
            }
        }
    }

    @MainActor
    private static func ask(_ plugin: Plugin?, _ request: PluginDialog) async -> PluginDialogAnswer? {
        guard let host = plugin?.host else { return nil }
        return await host.ask(request)
    }

    // MARK: Files

    private func files(_ name: String, _ a: [LuaValue]) -> APIResult {
        guard let path = path(a.first ?? .nil) else { return .failure("basil.fs.\(name) needs a path") }
        let limit = Int((a.count > 1 ? a[1] : .nil).number ?? Double(16 << 20))
        let registry = registry
        return .wait { @Sendable [weak self] in
            guard let self else { return .failure("plugin turned off") }
            do {
                let provider = try registry.provider(for: path.location)
                switch name {
                case "list":
                    var items: [FileItem] = []
                    for try await batch in provider.list(path) { items += batch }
                    return .values([.array(items.map(self.value))])
                case "stat":
                    do { return .values([self.value(try await provider.item(at: path))]) } catch VFSError.notFound {
                        return .values([.nil])
                    }
                default:
                    guard let readable = provider as? any WritableProvider else {
                        return .failure("\(path.name) cannot be read")
                    }
                    let file = try await readable.openForReading(path, bypassCache: false)
                    var data = Data()
                    while data.count < limit {
                        let chunk = try await file.read(at: Int64(data.count), count: min(1 << 20, limit - data.count))
                        if chunk.isEmpty { break }
                        data += chunk
                    }
                    await file.close()
                    return .values([.bytes(data)])
                }
            } catch {
                return .failure(Self.describe(error))
            }
        }
    }

    // MARK: Shell and network (permissions)

    private func shell(_ a: [LuaValue]) -> APIResult {
        guard granted.contains(.shell) else {
            return .failure("basil.shell needs the shell permission (\"permissions\": [\"shell\"] in plugin.json)")
        }
        guard let command = a.first?.string, !command.isEmpty else { return .failure("basil.shell needs a command") }
        let options = a.count > 1 ? a[1] : .nil
        var directory: String?
        if !options["cwd"].isNil {
            guard let folder = path(options["cwd"]), let local = registry.localPath(of: folder) else {
                return .failure("basil.shell runs only in folders on this Mac or on mounted shares")
            }
            directory = local.path
        }
        let input = options["input"].data
        return .wait {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: Self.runShell(command, in: directory, input: input))
                }
            }
        }
    }

    static func runShell(_ command: String, in directory: String?, input: Data?) -> APIResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        let output = Pipe()
        let stdin = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        do { try process.run() } catch { return .failure("the command could not start: \(error.localizedDescription)") }
        if let input {
            Thread.detachNewThread {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return .values([.record(["status": .number(Double(process.terminationStatus)),
                                 "output": String(data: data, encoding: .utf8).map(LuaValue.string) ?? .bytes(data)])])
    }

    private func http(_ spec: LuaValue) -> APIResult {
        guard granted.contains(.network) else {
            return .failure("basil.http needs the network permission (\"permissions\": [\"network\"] in plugin.json)")
        }
        guard let address = spec["url"].string ?? spec.string, let url = URL(string: address),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            return .failure("basil.http needs an http or https url")
        }
        var request = URLRequest(url: url)
        request.httpMethod = spec["method"].string?.uppercased() ?? "GET"
        for (name, value) in spec["headers"].fields { if let text = value.string { request.setValue(text, forHTTPHeaderField: name) } }
        request.httpBody = spec["body"].data
        request.timeoutInterval = spec["timeout"].number ?? 60
        let prepared = request
        return .wait {
            do {
                let (data, response) = try await URLSession(configuration: .ephemeral).data(for: prepared)
                let http = response as? HTTPURLResponse
                var headers: [String: LuaValue] = [:]
                for (name, value) in http?.allHeaderFields ?? [:] {
                    if let name = name as? String, let value = value as? String { headers[name.lowercased()] = .string(value) }
                }
                let body = String(data: data, encoding: .utf8).map(LuaValue.string) ?? .bytes(data)
                return .values([.record(["status": .number(Double(http?.statusCode ?? 0)), "headers": .record(headers),
                                         "body": body])])
            } catch {
                return .failure(error.localizedDescription)
            }
        }
    }
}
