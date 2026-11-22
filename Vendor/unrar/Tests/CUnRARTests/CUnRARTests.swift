import CUnRAR
import Darwin
import Testing

@Test func libraryVersion() {
    #expect(RARGetDllVersion() == RAR_DLL_VERSION)
}

@Test func missingArchiveFailsToOpen() {
    var data = RAROpenArchiveDataEx()
    var name = Array("/nonexistent/basil-test.rar".unicodeScalars.map { wchar_t($0.value) }) + [0]
    let handle = name.withUnsafeMutableBufferPointer { buffer -> UnsafeMutableRawPointer? in
        data.ArcNameW = buffer.baseAddress
        data.OpenMode = UInt32(RAR_OM_LIST)
        return RAROpenArchiveEx(&data)
    }
    #expect(handle == nil)
    #expect(data.OpenResult == UInt32(ERAR_EOPEN))
}
