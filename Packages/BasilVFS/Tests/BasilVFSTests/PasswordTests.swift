import BasilCore
import Foundation
import Synchronization
import Testing
@testable import BasilVFS

/// A SecretStore in memory, so tests never touch the user's keychain.
final class MemoryStore: SecretStore {
    let secrets = Mutex<[String: String]>([:])
    func secret(for key: String) -> String? { secrets.withLock { $0[key] } }
    func save(_ secret: String, for key: String) { secrets.withLock { $0[key] = secret } }
    func remove(for key: String) { secrets.withLock { _ = $0.removeValue(forKey: key) } }
}

@Suite struct PasswordTests {
    let archive = VFSPath.local("/tmp/a.7z")

    /// Answers from a script; records each prompt's retry flag.
    final class Script: Sendable {
        let answers: Mutex<[RememberingPasswords.Answer?]>
        let asked = Mutex<[Bool]>([])
        init(_ answers: [RememberingPasswords.Answer?]) { self.answers = Mutex(answers) }
        var prompt: RememberingPasswords.Prompt {
            { _, retry in
                self.asked.withLock { $0.append(retry) }
                return self.answers.withLock { $0.isEmpty ? nil : $0.removeFirst() }
            }
        }
    }

    @Test func keptInMemoryAfterItWorked() async {
        let script = Script([.init(password: "one", remember: false)])
        let store = MemoryStore()
        let passwords = RememberingPasswords(store: store, prompt: script.prompt)
        #expect(await passwords.password(for: archive, retry: false) == "one")
        passwords.accepted("one", for: archive)
        #expect(await passwords.password(for: archive, retry: false) == "one")
        #expect(script.asked.withLock { $0 } == [false])
        #expect(store.secrets.withLock { $0.isEmpty }) // not ticked: never saved
    }

    @Test func savedOnlyWhenTickedAndAccepted() async {
        let script = Script([.init(password: "bad", remember: true), .init(password: "good", remember: true)])
        let store = MemoryStore()
        let passwords = RememberingPasswords(store: store, prompt: script.prompt)
        #expect(await passwords.password(for: archive, retry: false) == "bad")
        #expect(await passwords.password(for: archive, retry: true) == "good")
        passwords.accepted("good", for: archive)
        #expect(store.secrets.withLock { $0 } == ["/tmp/a.7z": "good"])
        #expect(script.asked.withLock { $0 } == [false, true])
    }

    @Test func keychainFirstThenAskWhenWrong() async {
        let store = MemoryStore()
        store.save("old", for: "/tmp/a.7z")
        let script = Script([.init(password: "new", remember: true)])
        let passwords = RememberingPasswords(store: store, prompt: script.prompt)
        #expect(await passwords.password(for: archive, retry: false) == "old")
        #expect(script.asked.withLock { $0 }.isEmpty)
        #expect(await passwords.password(for: archive, retry: true) == "new")
        passwords.accepted("new", for: archive)
        #expect(store.secret(for: "/tmp/a.7z") == "new")
    }

    @Test func cancelGivesNil() async {
        let passwords = RememberingPasswords(store: MemoryStore(), prompt: Script([nil]).prompt)
        #expect(await passwords.password(for: archive, retry: false) == nil)
    }

    @Test func nestedArchivesHaveTheirOwnKey() {
        let outer = VFSPath.local("/Users/me/outer.zip")
        let inner = VFSPath(location: ProviderLocation(provider: ProviderID("archive"), container: outer), path: "/inner.7z")
        #expect(RememberingPasswords.key(for: inner) == "/Users/me/outer.zip > /inner.7z")
    }
}
