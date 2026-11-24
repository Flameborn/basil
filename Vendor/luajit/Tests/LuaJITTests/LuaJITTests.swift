import CLuaJIT
import Testing

/// The library links, runs Lua and compiles traces (the JIT works in this process).
@Test func runsLuaWithTheJIT() {
    let L = luaL_newstate()!
    defer { lua_close(L) }
    luaL_openlibs(L)
    let code = """
    local sum = 0
    for i = 1, 1000000 do sum = sum + i % 7 end
    return sum, jit.status(), jit.version
    """
    #expect(luaL_loadstring(L, code) == 0)
    #expect(lua_pcall(L, 0, 3, 0) == 0)
    #expect(lua_tonumber(L, -3) == 2_999_998)
    #expect(lua_toboolean(L, -2) == 1)
    #expect(String(cString: lua_tolstring(L, -1, nil)).hasPrefix("LuaJIT 2.1"))
}
