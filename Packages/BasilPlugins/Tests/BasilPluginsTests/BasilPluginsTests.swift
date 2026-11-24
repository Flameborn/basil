import BasilCore
import BasilOperations
import BasilVFS
import Foundation
import Testing
@testable import BasilPlugins

/// The main window as plugins see it, recording what they did.
@MainActor
final class FakeHost: PluginHost, WorkspaceContext {
    var announced: [String] = []
    var asked: [PluginDialog] = []
    var answers: [PluginDialogAnswer] = []
    var transfers: [([VFSPath], VFSPath, Bool)] = []
    var deleted: [([VFSPath], Bool)] = []
    var made: [VFSPath] = []
    var renamed: [(VFSPath, String)] = []
    var navigated: [VFSPath] = []
    var changes = 0
    let queue = FileOperationQueue()
    var folder: VFSPath
    var items: [FileItem] = []

    init(folder: VFSPath) { self.folder = folder }

    var workspace: (any WorkspaceContext)? { self }
    var activeDirectory: VFSPath? { folder }
    var otherDirectory: VFSPath? { .local("/tmp") }
    var cursorItem: FileItem? { items.first }
    var targetItems: [FileItem] { items }
    func navigate(to directory: VFSPath) { navigated.append(directory) }
    func announce(_ message: String) { announced.append(message) }
    func enqueue(_ operation: any QueueOperation) { queue.add(operation) }
    func transfer(_ sources: [VFSPath], to target: VFSPath, move: Bool) { transfers.append((sources, target, move)) }
    func delete(_ items: [VFSPath], toTrash: Bool) { deleted.append((items, toTrash)) }
    func makeDirectory(_ path: VFSPath) { made.append(path) }
    func rename(_ path: VFSPath, to name: String) { renamed.append((path, name)) }
    func ask(_ dialog: PluginDialog) async -> PluginDialogAnswer {
        asked.append(dialog)
        return answers.isEmpty ? .cancelled : answers.removeFirst()
    }
    func pluginsChanged() { changes += 1 }
}

/// A Plugins folder with plugins written by the tests.
/// A test's folder and its settings file next to it, removed when the test's `Setup` goes
/// away. A suite named by an absolute path keeps its domain in that file, where a named suite
/// would leave a plist in ~/Library/Preferences that cfprefsd writes back after removal.
final class Leftovers: Sendable {
    let folder: URL
    var suite: String { folder.path + "-settings" }
    init(folder: URL) { self.folder = folder }
    deinit {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(atPath: suite + ".plist")
    }
}

@MainActor
struct Setup {
    let leftovers: Leftovers
    let root: URL
    let folder: URL
    let registry = ProviderRegistry()
    let commands = CommandRegistry()
    let settings: SettingsStore
    let manager: PluginManager
    let host: FakeHost

    init() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("basil-plugins-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        leftovers = Leftovers(folder: url)
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        root = URL(fileURLWithPath: String(cString: realpath(url.path, &buffer)))
        folder = root.appendingPathComponent("Plugins")
        registry.register(LocalProvider())
        let defaults = UserDefaults(suiteName: leftovers.suite)!
        settings = SettingsStore(defaults: defaults)
        manager = PluginManager(folder: folder, registry: registry, commands: commands, settings: settings)
        host = FakeHost(folder: .local(root.path))
        manager.host = host
    }

    /// Writes a plugin and returns its id.
    @discardableResult
    func write(_ id: String, _ main: String, permissions: [String] = [], files: [String: String] = [:]) throws -> String {
        let dir = folder.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["id": id, "name": "Test \(id)", "version": "1.0", "permissions": permissions]
        try JSONSerialization.data(withJSONObject: manifest).write(to: dir.appendingPathComponent("plugin.json"))
        try main.write(to: dir.appendingPathComponent("main.lua"), atomically: true, encoding: .utf8)
        for (name, text) in files {
            let file = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        return id
    }

    func enable(_ id: String) async {
        manager.scan()
        await manager.setEnabled(id, true)
    }

    func entry(_ id: String) -> PluginManager.Entry? { manager.entries.first { $0.id == id } }

    func wait(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }
}

@MainActor
@Suite struct PluginTests {
    @Test func theSandboxKeepsToBasil() async throws {
        let s = try Setup()
        try s.write("sandbox", """
        local function has(x) return x ~= nil end
        print("io", has(io), "debug", has(debug), "dofile", has(dofile), "loadfile", has(loadfile))
        print("os.execute", has(os.execute), "os.getenv", has(os.getenv), "os.time", has(os.time))
        print("ffi", pcall(require, "ffi"))
        print("binary", loadstring(string.dump(function() end)))
        print("text", loadstring("return 1 + 1")())
        local util = require("lib.util")
        print("module", util.twice(21))
        print("outside", pcall(require, "..secret"))
        print("missing", pcall(require, "nothing"))
        print("plugin", basil.plugin.id, basil.plugin.version)
        """, files: ["lib/util.lua": "return { twice = function(x) return x * 2 end }"])
        await s.enable("sandbox")
        let log = try #require(s.entry("sandbox")).log
        #expect(log.contains("io\tfalse\tdebug\tfalse\tdofile\tfalse\tloadfile\tfalse"), "\(log)")
        #expect(log.contains("os.execute\tfalse\tos.getenv\tfalse\tos.time\ttrue"))
        #expect(log.contains { $0.hasPrefix("ffi\tfalse\t") && $0.contains("ffi permission") })
        #expect(log.contains("binary\tnil\tbinary chunks are not allowed"))
        #expect(log.contains("text\t2"))
        #expect(log.contains("module\t42"))
        #expect(log.contains { $0.hasPrefix("outside\tfalse") })
        #expect(log.contains { $0.hasPrefix("missing\tfalse") && $0.contains("not found") }, "\(log)")
        #expect(log.contains("plugin\tsandbox\t1.0"))
        #expect(s.entry("sandbox")?.problem == nil)
    }

    @Test func commandsRunWithThePaneAndWaitForDialogs() async throws {
        let s = try Setup()
        try s.write("hello", """
        basil.command{
          id = "greet", title = "Greet", keys = { "Cmd+Shift+G" }, menu = "Commands/Greetings", context = true,
          when = "files",
          run = function(ctx)
            local name = basil.ask("Your name?", "Ann")
            if name == nil then basil.announce("no name") return end
            local which = basil.choose("Pick one", { "red", "green" })
            local sure = basil.confirm("Sure?")
            basil.announce("Hello " .. name .. " in " .. basil.name(ctx.pane.folder) .. ", " .. ctx.pane.cursor.name
              .. ", " .. tostring(which) .. ", " .. tostring(sure) .. ", other " .. ctx.other.folder.path)
          end,
        }
        """)
        s.host.items = [FileItem(path: .local(s.root.path + "/a.txt"), kind: .file, size: 3)]
        await s.enable("hello")
        let id = CommandID(rawValue: "plugin.hello.greet")
        let command = try #require(s.commands.command(id))
        #expect(command.title == "Greet")
        #expect(s.commands.commandID(for: KeyChord(.character("g"), [.command, .shift])) == id)
        #expect(s.commands.menus.menus.contains { $0.title == "Commands" && $0.items.contains(.submenu("Greetings", [.command(id)])) })
        #expect(s.commands.menus.contextMenu.contains(.submenu("Plugins", [.command(id)])))
        #expect(s.commands.isApplicable(id, in: s.host))

        s.host.answers = [.text("Bo"), .chosen(1), .confirmed]
        #expect(s.commands.perform(id, in: s.host))
        #expect(await s.wait { !s.host.announced.isEmpty })
        #expect(s.host.announced == ["Hello Bo in \(s.root.lastPathComponent), a.txt, 2, true, other /tmp"])
        #expect(s.host.asked.first == .text(plugin: "Test hello", message: "Your name?", text: "Ann"))

        // Cancelled: the command goes on with nil.
        s.host.announced = []
        s.commands.perform(id, in: s.host)
        #expect(await s.wait { s.host.announced == ["no name"] })

        // Folders only: "files" does not fit.
        s.host.items = [FileItem(path: .local(s.root.path), kind: .directory)]
        #expect(!s.commands.isApplicable(id, in: s.host))

        // Turned off: the command, its key and its menu items are gone.
        await s.manager.setEnabled("hello", false)
        #expect(s.commands.command(id) == nil)
        #expect(s.commands.commandID(for: KeyChord(.character("g"), [.command, .shift])) == nil)
        #expect(!s.commands.menus.contextMenu.contains(.submenu("Plugins", [.command(id)])))
    }

    @Test func errorsAreReportedWithTheirLine() async throws {
        let s = try Setup()
        try s.write("broken", "local x = nil\nprint(x.field)\n")
        await s.enable("broken")
        let entry = try #require(s.entry("broken"))
        #expect(entry.problem?.contains("main.lua:2") == true, "\(entry.problem ?? "")")
        #expect(!entry.isLoaded)
        try s.write("syntax", "basil.command{ id = ")
        await s.enable("syntax")
        #expect(s.entry("syntax")?.problem?.contains("main.lua") == true)
        try s.write("badcall", "basil.command{ id = 'x' }")
        await s.enable("badcall")
        #expect(s.entry("badcall")?.problem?.contains("basil.command needs") == true)
    }

    @Test func columnsFillFromLua() async throws {
        let s = try Setup()
        try "one two three".write(to: s.root.appendingPathComponent("words.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: s.root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try s.write("count", """
        basil.column{
          id = "words", title = "Words", width = 70, align = "right",
          fill = function(folder, items)
            local result = {}
            for _, item in ipairs(items) do
              if item.kind == "file" then
                local text = basil.fs.read(item)
                local n = 0
                for _ in text:gmatch("%S+") do n = n + 1 end
                result[item.name] = tostring(n)
              end
            end
            return result
          end,
        }
        """)
        await s.enable("count")
        let column = ColumnID(rawValue: "plugin.count.words")
        let definition = try #require(ColumnCatalog.definition(column))
        #expect(definition.title == "Words" && definition.onlyWhenAnnotated && definition.alignment == .trailing)
        let annotations = await s.registry.annotations(for: .local(s.root.path))
        #expect(annotations[column]?.byName == ["words.txt": "3"])
        await s.manager.setEnabled("count", false)
        #expect(ColumnCatalog.definition(column) == nil)
        #expect(await s.registry.annotations(for: .local(s.root.path))[column] == nil)
    }

    @Test func providersAreBrowsedAndRead() async throws {
        let s = try Setup()
        try s.write("tree", """
        local place = basil.provider{
          id = "demo", title = "Demo tree",
          list = function(path)
            if path.path == "/" then
              return { { name = "Docs", kind = "folder" }, { name = "readme.txt", size = 5, modified = 1700000000 } }
            elseif path.path == "/Docs" then
              return { { name = "inner.md", size = 2 } }
            end
            return nil
          end,
          read = function(path) return path.path == "/readme.txt" and "hello" or "hi" end,
        }
        basil.command{ id = "open", title = "Open Demo", run = function() basil.navigate(basil.path(place, "/Docs")) end }
        """)
        await s.enable("tree")
        let location = ProviderLocation(provider: ProviderID("plugin.tree.demo"))
        let provider = try s.registry.provider(for: location)
        var names: [String] = []
        for try await batch in provider.list(VFSPath(location: location, path: "/")) { names += batch.map(\.name) }
        #expect(names == ["Docs", "readme.txt"])
        let readme = try await provider.item(at: VFSPath(location: location, path: "/readme.txt"))
        #expect(readme.size == 5 && readme.modified == Date(timeIntervalSince1970: 1_700_000_000))
        let writable = try #require(provider as? any WritableProvider)
        let file = try await writable.openForReading(VFSPath(location: location, path: "/readme.txt"), bypassCache: false)
        #expect(try await file.read(at: 0, count: 100) == Data("hello".utf8))
        await #expect(throws: VFSError.self) { try await writable.makeDirectory(VFSPath(location: location, path: "/New")) }
        await #expect(throws: VFSError.notFound(VFSPath(location: location, path: "/missing"))) {
            for try await _ in provider.list(VFSPath(location: location, path: "/missing")) {}
        }
        s.commands.perform(CommandID(rawValue: "plugin.tree.open"), in: s.host)
        #expect(await s.wait { !s.host.navigated.isEmpty })
        #expect(s.host.navigated == [VFSPath(location: location, path: "/Docs")])
        await s.manager.setEnabled("tree", false)
        #expect((try? s.registry.provider(for: location)) == nil)
    }

    @Test func placeholdersAndOperations() async throws {
        let s = try Setup()
        try s.write("ops", """
        basil.placeholder{ name = "Shout", title = "Name in capitals", value = function(item, n) return item.name:upper() .. n end }
        basil.command{ id = "work", title = "Work", run = function()
          basil.operation{ title = "Counting things", kind = "Counting", run = function(op)
            for i = 1, 3 do
              op:checkpoint()
              op:progress(i / 3, "step " .. i)
              op:items(i, 3)
            end
            op.log("done counting")
          end }
        end }
        """)
        await s.enable("ops")
        let shout = try #require(MultiRenamePlaceholders.definition("Shout"))
        #expect(shout.value(RenameInput(item: FileItem(path: .local("/x/song.mp3"), kind: .file), index: 1)) == "SONG.MP32")

        s.commands.perform(CommandID(rawValue: "plugin.ops.work"), in: s.host)
        #expect(await s.wait { s.host.queue.items.first?.state.isDone == true })
        let item = try #require(s.host.queue.items.first)
        #expect(item.state == .finished, "\(item.log)")
        #expect(item.title == "Counting things")
        #expect(item.log.contains { $0.contains("done counting") })
        #expect(OperationKindCatalog.info(item.kind).name == "Counting")

        await s.manager.setEnabled("ops", false)
        #expect(MultiRenamePlaceholders.definition("Shout") == nil)
        #expect(!OperationKindCatalog.all.contains { $0.name == "Counting" })
    }

    @Test func basilsOwnOperationsGoThroughTheHost() async throws {
        let s = try Setup()
        try s.write("files", """
        basil.command{ id = "go", title = "Go", run = function(ctx)
          local here = ctx.pane.folder
          basil.copy({ basil.join(here, "a") }, ctx.other.folder)
          basil.move(basil.join(here, "b"), "/tmp/target")
          basil.delete({ basil.join(here, "c") }, { trash = false })
          basil.mkdir(basil.join(here, "New"))
          basil.rename(basil.join(here, "d"), "e")
          local listed = basil.fs.list(here)
          basil.announce("listed " .. #listed .. ", stat " .. tostring(basil.fs.stat(basil.join(here, "missing"))))
        end }
        """)
        try Data().write(to: s.root.appendingPathComponent("a"))
        await s.enable("files")
        s.commands.perform(CommandID(rawValue: "plugin.files.go"), in: s.host)
        #expect(await s.wait { !s.host.announced.isEmpty })
        let here = s.root.path
        #expect(s.host.transfers.count == 2)
        #expect(s.host.transfers.first?.0 == [.local(here + "/a")] && s.host.transfers.first?.1 == .local("/tmp")
                && s.host.transfers.first?.2 == false)
        #expect(s.host.transfers.last?.0 == [.local(here + "/b")] && s.host.transfers.last?.2 == true)
        #expect(s.host.deleted.first?.0 == [.local(here + "/c")] && s.host.deleted.first?.1 == false)
        #expect(s.host.made == [.local(here + "/New")])
        #expect(s.host.renamed.first?.0 == .local(here + "/d") && s.host.renamed.first?.1 == "e")
        #expect(s.host.announced.first?.hasPrefix("listed ") == true && s.host.announced.first?.hasSuffix("stat nil") == true,
                "\(s.host.announced)")
    }

    @Test func permissionsAreAskedOnceAndRequired() async throws {
        let s = try Setup()
        try s.write("shelly", """
        local result = basil.shell("printf '%s' \\"$PWD\\"; echo; echo err 1>&2; exit 3", { cwd = basil.plugin.folder })
        print("status", result.status, result.output)
        """, permissions: ["shell"])
        try s.write("noshell", "print(pcall(basil.shell, 'true'))")
        // Denied: stays off.
        s.host.answers = [.cancelled]
        await s.enable("shelly")
        #expect(s.entry("shelly")?.isEnabled == false && s.entry("shelly")?.isLoaded == false)
        #expect(s.host.asked == [.permissions(plugin: "Test shelly", permissions: [.shell])])
        // Allowed: runs, and is not asked again on reload.
        s.host.answers = [.confirmed]
        await s.enable("shelly")
        #expect(s.entry("shelly")?.granted == [.shell])
        let folder = s.folder.appendingPathComponent("shelly").path
        #expect(s.entry("shelly")?.log.contains("status\t3\t\(folder)\nerr\n") == true, "\(s.entry("shelly")?.log ?? [])")
        await s.manager.reload("shelly")
        #expect(s.host.asked.count == 2)
        #expect(s.settings.settings.plugins["shelly"] == PluginSetting(enabled: true, granted: ["shell"]))

        await s.enable("noshell")
        #expect(s.entry("noshell")?.log.first?.contains("needs the shell permission") == true)
    }

    @Test func pluginsStayOffUntilTurnedOnAndBadManifestsAreListed() async throws {
        let s = try Setup()
        try s.write("quiet", "basil.command{ id = 'x', title = 'X', run = function() end }")
        let bad = s.folder.appendingPathComponent("bad")
        try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
        try Data("{ \"name\": \"No id\" }".utf8).write(to: bad.appendingPathComponent("plugin.json"))
        await s.manager.startEnabled()
        #expect(s.entry("quiet")?.isEnabled == false && s.entry("quiet")?.isLoaded == false)
        #expect(s.commands.command(CommandID(rawValue: "plugin.quiet.x")) == nil)
        #expect(s.entry("bad")?.problem?.contains("id is missing") == true, "\(s.entry("bad")?.problem ?? "")")
        // Turned on, then started again at the next launch.
        await s.manager.setEnabled("quiet", true)
        s.manager.stopAll()
        #expect(s.commands.command(CommandID(rawValue: "plugin.quiet.x")) == nil)
        await s.manager.startEnabled()
        #expect(s.commands.command(CommandID(rawValue: "plugin.quiet.x")) != nil)
    }

    /// The examples in Plugins/Examples load and work (Open on GitHub is only loaded: running it opens a browser).
    @Test func theExamplePluginsWork() async throws {
        let s = try Setup()
        let examples = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../Plugins/Examples")
            .standardizedFileURL
        try FileManager.default.createDirectory(at: s.folder, withIntermediateDirectories: true)
        for name in ["hello-world", "word-count", "open-on-github"] {
            try FileManager.default.copyItem(at: examples.appendingPathComponent(name), to: s.folder.appendingPathComponent(name))
        }
        try "one two\nthree".write(to: s.root.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)
        try "not counted".write(to: s.root.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)
        s.host.answers = [.confirmed]
        for id in ["basil.example.hello", "basil.example.wordcount", "basil.example.github"] {
            await s.enable(id)
            #expect(s.entry(id)?.isLoaded == true, "\(id): \(s.entry(id)?.problem ?? "")")
        }
        #expect(s.entry("basil.example.github")?.granted == [.shell])
        #expect(s.commands.command(CommandID(rawValue: "plugin.basil.example.github.open")) != nil)

        let words = await s.registry.annotations(for: .local(s.root.path))[ColumnID(rawValue: "plugin.basil.example.wordcount.words")]
        #expect(words?.byName == ["notes.md": "3"])

        s.host.items = [FileItem(path: .local(s.root.path + "/notes.md"), kind: .file)]
        s.commands.perform(CommandID(rawValue: "plugin.basil.example.hello.hello"), in: s.host)
        #expect(await s.wait { !s.host.announced.isEmpty })
        #expect(s.host.announced == ["Hello from a plugin, notes.md in \(s.root.lastPathComponent)"])
    }

    @Test func keyNamesAreRead() {
        #expect(KeyChord(parsing: "Cmd+Shift+L") == KeyChord(.character("l"), [.command, .shift]))
        #expect(KeyChord(parsing: "Option+F5") == KeyChord(.function(5), .option))
        #expect(KeyChord(parsing: "Ctrl+Page Down") == KeyChord(.pageDown, .control))
        #expect(KeyChord(parsing: "Numpad Plus") == KeyChord(.numpad("+")))
        #expect(KeyChord(parsing: "Cmd++") == KeyChord(.character("+"), .command))
        #expect(KeyChord(parsing: "Hyper+X") == nil)
        #expect(KeyChord(parsing: "Cmd+Shift+L")?.description == "Shift+Cmd+L")
    }
}
