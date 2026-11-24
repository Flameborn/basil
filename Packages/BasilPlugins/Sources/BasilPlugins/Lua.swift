import CLuaJIT
import Foundation

/// The Lua C API's macros, which Swift does not import.
enum Lua {
    static let registryIndex: Int32 = -10000
    static let globalsIndex: Int32 = -10002
    static func upvalueIndex(_ i: Int32) -> Int32 { globalsIndex - i }

    static func pop(_ L: OpaquePointer, _ n: Int32 = 1) { lua_settop(L, -n - 1) }
    static func newTable(_ L: OpaquePointer) { lua_createtable(L, 0, 0) }
    static func isNil(_ L: OpaquePointer, _ i: Int32) -> Bool { lua_type(L, i) == LUA_TNIL }
    static func string(_ L: OpaquePointer, _ i: Int32) -> String? {
        guard lua_type(L, i) == LUA_TSTRING || lua_type(L, i) == LUA_TNUMBER else { return nil }
        var length = 0
        guard let bytes = lua_tolstring(L, i, &length) else { return nil }
        return String(decoding: UnsafeRawBufferPointer(start: bytes, count: length), as: UTF8.self)
    }
    static func data(_ L: OpaquePointer, _ i: Int32) -> Data? {
        guard lua_type(L, i) == LUA_TSTRING else { return nil }
        var length = 0
        guard let bytes = lua_tolstring(L, i, &length) else { return nil }
        return Data(bytes: bytes, count: length)
    }
    static func push(_ L: OpaquePointer, _ text: String) {
        var text = text
        text.withUTF8 { lua_pushlstring(L, UnsafeRawPointer($0.baseAddress!).assumingMemoryBound(to: CChar.self), $0.count) }
    }
    static func push(_ L: OpaquePointer, data: Data) {
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                lua_pushlstring(L, base.assumingMemoryBound(to: CChar.self), raw.count)
            } else {
                lua_pushlstring(L, "", 0)
            }
        }
    }
    static func setField(_ L: OpaquePointer, _ index: Int32, _ name: String) { lua_setfield(L, index, name) }
    static func getGlobal(_ L: OpaquePointer, _ name: String) { lua_getfield(L, globalsIndex, name) }
    static func setGlobal(_ L: OpaquePointer, _ name: String) { lua_setfield(L, globalsIndex, name) }
    /// Pops the value on top and keeps it in the registry; the reference reads it back.
    static func ref(_ L: OpaquePointer) -> Int32 { luaL_ref(L, registryIndex) }
    static func unref(_ L: OpaquePointer, _ ref: Int32) { luaL_unref(L, registryIndex, ref) }
    static func pushRef(_ L: OpaquePointer, _ ref: Int32) { lua_rawgeti(L, registryIndex, ref) }
}

/// A Lua value copied out of (or into) a Lua state: what crosses between Lua and Swift.
/// Functions stay in Lua as registry references.
enum LuaValue: Sendable, Equatable {
    case `nil`
    case bool(Bool)
    case number(Double)
    case string(String)
    /// A string that is not text (file contents).
    case bytes(Data)
    case table([LuaKey: LuaValue])
    case function(Int32)

    enum LuaKey: Hashable, Sendable {
        case string(String)
        case index(Int)
    }

    static func array(_ values: [LuaValue]) -> LuaValue {
        .table(Dictionary(uniqueKeysWithValues: values.enumerated().map { (.index($0.offset + 1), $0.element) }))
    }

    static func record(_ fields: [String: LuaValue]) -> LuaValue {
        .table(Dictionary(uniqueKeysWithValues: fields.map { (.string($0.key), $0.value) }))
    }

    subscript(_ key: String) -> LuaValue {
        if case .table(let t) = self { return t[.string(key)] ?? .nil }
        return .nil
    }

    var string: String? {
        switch self {
        case .string(let s): s
        case .number(let n): n == n.rounded() && abs(n) < 1e15 ? String(Int64(n)) : String(n)
        case .bytes(let d): String(data: d, encoding: .utf8)
        default: nil
        }
    }
    var number: Double? { if case .number(let n) = self { n } else { nil } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var isNil: Bool { self == .nil }
    var function: Int32? { if case .function(let f) = self { f } else { nil } }
    var data: Data? {
        switch self {
        case .bytes(let d): d
        case .string(let s): Data(s.utf8)
        default: nil
        }
    }

    /// The array part (1...n) in order.
    var list: [LuaValue] {
        guard case .table(let t) = self else { return [] }
        var result: [LuaValue] = []
        var i = 1
        while let value = t[.index(i)] {
            result.append(value)
            i += 1
        }
        return result
    }

    /// The string-keyed entries.
    var fields: [String: LuaValue] {
        guard case .table(let t) = self else { return [:] }
        var result: [String: LuaValue] = [:]
        for (key, value) in t { if case .string(let k) = key { result[k] = value } }
        return result
    }

    /// Reads the value at `index`. Functions are kept in the registry (`ref`); tables are
    /// copied up to `depth` levels (cycles end there).
    static func read(_ L: OpaquePointer, _ index: Int32, depth: Int = 8) -> LuaValue {
        let index = index < 0 && index > Lua.registryIndex ? lua_gettop(L) + index + 1 : index
        switch lua_type(L, index) {
        case LUA_TBOOLEAN: return .bool(lua_toboolean(L, index) != 0)
        case LUA_TNUMBER: return .number(lua_tonumber(L, index))
        case LUA_TSTRING:
            let data = Lua.data(L, index) ?? Data()
            if let text = String(data: data, encoding: .utf8) { return .string(text) }
            return .bytes(data)
        case LUA_TFUNCTION:
            lua_pushvalue(L, index)
            return .function(Lua.ref(L))
        case LUA_TTABLE:
            guard depth > 0 else { return .nil }
            var table: [LuaKey: LuaValue] = [:]
            lua_pushnil(L)
            while lua_next(L, index) != 0 {
                let key: LuaKey?
                switch lua_type(L, -2) {
                case LUA_TNUMBER:
                    let n = lua_tonumber(L, -2)
                    key = n == n.rounded() ? .index(Int(n)) : nil
                case LUA_TSTRING:
                    key = Lua.string(L, -2).map { .string($0) }
                default:
                    key = nil
                }
                if let key { table[key] = read(L, -1, depth: depth - 1) }
                Lua.pop(L)
            }
            return .table(table)
        default:
            return .nil
        }
    }

    func push(_ L: OpaquePointer) {
        lua_checkstack(L, 4)
        switch self {
        case .nil: lua_pushnil(L)
        case .bool(let b): lua_pushboolean(L, b ? 1 : 0)
        case .number(let n): lua_pushnumber(L, n)
        case .string(let s): Lua.push(L, s)
        case .bytes(let d): Lua.push(L, data: d)
        case .function(let ref): Lua.pushRef(L, ref)
        case .table(let t):
            lua_createtable(L, 0, Int32(t.count))
            for (key, value) in t {
                switch key {
                case .index(let i): lua_pushnumber(L, Double(i))
                case .string(let s): Lua.push(L, s)
                }
                value.push(L)
                lua_rawset(L, -3)
            }
        }
    }
}
