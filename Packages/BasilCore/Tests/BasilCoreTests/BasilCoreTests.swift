import Foundation
import Testing
@testable import BasilCore

@Suite struct VFSPathTests {
    @Test func normalises() {
        #expect(VFSPath.local("").path == "/")
        #expect(VFSPath.local("/a//b/./c/../d/").path == "/a/b/d")
        #expect(VFSPath.local("/..").path == "/")
    }

    @Test func parentAndAppending() {
        let p = VFSPath.local("/Users/x")
        #expect(p.parent == .local("/Users"))
        #expect(VFSPath.local("/").parent == nil)
        #expect(VFSPath.local("/").appending("a") == .local("/a"))
        #expect(p.appending("y").path == "/Users/x/y")
        #expect(p.name == "x")
    }

    @Test func prefixRespectsComponentBoundaries() {
        #expect(VFSPath.local("/a/bc").hasPrefix(.local("/a")))
        #expect(!VFSPath.local("/ab").hasPrefix(.local("/a")))
        #expect(VFSPath.local("/a").hasPrefix(.local("/")))
    }

    @Test func nestedLocationDescription() {
        let zip = VFSPath.local("/tmp/x.zip")
        let inner = VFSPath(location: ProviderLocation(provider: ProviderID("archive"), container: zip), path: "/dir/f.txt")
        #expect(inner.description == "/tmp/x.zip#/dir/f.txt")
        #expect(inner.location.container == zip)
    }
}

@Suite struct FileItemTests {
    @Test(arguments: [
        ("song.mp3", false, "song", "mp3"),
        ("archive.tar.gz", false, "archive.tar", "gz"),
        (".zshrc", false, ".zshrc", ""),
        ("noext", false, "noext", ""),
        ("trailing.", false, "trailing.", ""),
        ("My.App", true, "My.App", ""),
    ])
    func splitsExtension(name: String, isDir: Bool, base: String, ext: String) {
        let r = FileItem.splitExtension(name, isDirectory: isDir)
        #expect(r.base == base)
        #expect(r.ext == ext)
    }
}
