import CLuaJIT
import Foundation
import Synchronization

/// What a Basil function called from Lua gives back: values now, a failure (raised as a Lua
/// error by the prelude), or work to wait for. While it waits, the Lua code that called it is a
/// suspended coroutine, so no thread is held (a dialog can stay open for minutes).
enum APIResult: Sendable {
    case values([LuaValue])
    case failure(String)
    case wait(@Sendable () async -> APIResult)
}

/// An error a plugin's Lua code raised (with its traceback), or a problem loading it.
struct PluginError: Error, LocalizedError, Sendable, Equatable {
    var message: String
    var errorDescription: String? { message }
}

/// One plugin's Lua state. LuaJIT states are not thread safe, so everything touching it runs on
/// the runtime's own serial queue. Basil's functions reach Swift through one C trampoline (the
/// function's name is its upvalue). Every call from Basil into Lua (a command, a column, a
/// provider) runs in a new coroutine, so Basil functions that wait (`APIResult.wait`) yield it
/// and it is resumed with their answer.
///
/// The sandbox: Lua 5.1's base, string, table, math, coroutine, bit and jit libraries, os with
/// time, clock, date and difftime only, no io, no debug, no dofile or loadfile, no binary
/// chunks, and `require` for the plugin's own .lua files. LuaJIT's ffi only with the permission.
final class LuaRuntime: @unchecked Sendable {
    let name: String
    let folder: URL
    let queue: DispatchQueue
    private var L: OpaquePointer?
    /// Called (on the runtime's queue) for every Basil function the plugin calls.
    private let dispatch: @Sendable (String, [LuaValue]) -> APIResult
    private let functionNames: [String]
    /// Work a coroutine yielded for, by the coroutine's state.
    private var pending: [OpaquePointer: @Sendable () async -> APIResult] = [:]
    /// Where `print` and errors go.
    let log: @Sendable (String) -> Void
    private var closed = false

    /// A light userdata a Basil function yields with, so stray yields are told apart.
    nonisolated(unsafe) static var sentinel: UInt8 = 0

    init(name: String, folder: URL, allowFFI: Bool, functions: [String],
         log: @escaping @Sendable (String) -> Void,
         dispatch: @escaping @Sendable (String, [LuaValue]) -> APIResult) throws {
        self.name = name
        self.folder = folder
        self.functionNames = functions
        self.dispatch = dispatch
        self.log = log
        queue = DispatchQueue(label: "Basil plugin \(name)")
        try queue.sync { try open(allowFFI: allowFFI) }
    }

    private func open(allowFFI: Bool) throws {
        guard let L = luaL_newstate() else { throw PluginError(message: "Lua could not start") }
        self.L = L
        func library(_ open: lua_CFunction, _ name: String) {
            lua_pushcclosure(L, open, 0)
            Lua.push(L, name)
            lua_call(L, 1, 0)
        }
        library(luaopen_base, "")
        library(luaopen_table, LUA_TABLIBNAME)
        library(luaopen_string, LUA_STRLIBNAME)
        library(luaopen_math, LUA_MATHLIBNAME)
        library(luaopen_bit, LUA_BITLIBNAME)
        library(luaopen_jit, LUA_JITLIBNAME)
        library(luaopen_os, LUA_OSLIBNAME)
        if allowFFI {
            lua_pushcclosure(L, luaopen_ffi, 0)
            lua_call(L, 0, 1)
            Lua.setGlobal(L, "__ffi")
        }
        lua_pushlightuserdata(L, Unmanaged.passUnretained(self).toOpaque())
        lua_setfield(L, Lua.registryIndex, "basil.runtime")

        // The raw Basil functions, handed to the prelude and then out of reach.
        Lua.newTable(L)
        for function in functionNames {
            Lua.push(L, function)
            lua_pushcclosure(L, luaTrampoline, 1)
            lua_setfield(L, -2, function)
        }
        guard luaL_loadbuffer(L, Self.prelude, Self.prelude.utf8.count, "=basil") == 0 else {
            throw PluginError(message: "Basil's Lua prelude did not load: \(Lua.string(L, -1) ?? "")")
        }
        lua_insert(L, -2)
        guard lua_pcall(L, 1, 0, 0) == 0 else {
            throw PluginError(message: "Basil's Lua prelude failed: \(Lua.string(L, -1) ?? "")")
        }
        Lua.getGlobal(L, "__basil_runOperation")
        operationRunner = Lua.ref(L)
        lua_pushnil(L)
        Lua.setGlobal(L, "__basil_runOperation")
    }

    /// The prelude's runner of Lua queue items (`__basil_runOperation`).
    private(set) var operationRunner: Int32 = 0

    /// Called from the trampoline, on the runtime's queue, inside Lua.
    fileprivate func call(_ function: String, _ L: OpaquePointer) -> Int32 {
        let count = lua_gettop(L)
        var args: [LuaValue] = []
        if count > 0 { for i in 1...count { args.append(LuaValue.read(L, i)) } }
        switch dispatch(function, args) {
        case .values(let values):
            lua_checkstack(L, Int32(values.count) + 2)
            lua_pushboolean(L, 1)
            for value in values { value.push(L) }
            return Int32(values.count) + 1
        case .failure(let message):
            lua_pushboolean(L, 0)
            Lua.push(L, message)
            return 2
        case .wait(let work):
            if lua_pushthread(L) == 1 {
                // The main state (a sync call): nothing to suspend.
                Lua.pop(L)
                lua_pushboolean(L, 0)
                Lua.push(L, "\(function) cannot be used here, only in commands, columns, providers and operations")
                return 2
            }
            Lua.pop(L)
            pending[L] = work
            lua_pushlightuserdata(L, &Self.sentinel)
            return lua_yield(L, 1)
        }
    }

    // MARK: Running Lua

    /// Loads a chunk of the plugin (main.lua) and runs it as a coroutine.
    func run(file: URL) async throws {
        let source = try String(contentsOf: file, encoding: .utf8)
        let ref: Int32 = try queue.sync {
            guard let L else { throw PluginError(message: "\(name) is not loaded") }
            let chunk = "@" + file.lastPathComponent
            guard luaL_loadbuffer(L, source, source.utf8.count, chunk) == 0 else {
                let message = Lua.string(L, -1) ?? "could not be read"
                Lua.pop(L)
                throw PluginError(message: message)
            }
            return Lua.ref(L)
        }
        defer { release(ref) }
        _ = try await call(ref, [])
    }

    /// Calls a Lua function (a registry reference) in a new coroutine and returns its results.
    func call(_ ref: Int32, _ args: [LuaValue]) async throws -> [LuaValue] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[LuaValue], Error>) in
            queue.async { [self] in
                guard let L, !closed else {
                    return continuation.resume(throwing: PluginError(message: "\(name) is not loaded"))
                }
                guard let co = lua_newthread(L) else {
                    return continuation.resume(throwing: PluginError(message: "Lua ran out of memory"))
                }
                let threadRef = Lua.ref(L)
                Lua.pushRef(co, ref)
                for arg in args { arg.push(co) }
                step(co, threadRef, Int32(args.count), continuation)
            }
        }
    }

    /// Resumes a coroutine; on the queue.
    private func step(_ co: OpaquePointer, _ threadRef: Int32, _ count: Int32,
                      _ continuation: CheckedContinuation<[LuaValue], Error>) {
        guard let L, !closed else {
            return continuation.resume(throwing: PluginError(message: "\(name) was turned off"))
        }
        let status = lua_resume(co, count)
        if status == LUA_YIELD {
            let isOurs = lua_gettop(co) >= 1 && lua_touserdata(co, -1) == UnsafeMutableRawPointer(&Self.sentinel)
            guard isOurs, let work = pending.removeValue(forKey: co) else {
                Lua.unref(L, threadRef)
                return continuation.resume(throwing: PluginError(
                    message: "coroutine.yield was used outside the plugin's own coroutines"))
            }
            lua_settop(co, 0)
            let suspended = Suspended(co: co, threadRef: threadRef, continuation: continuation)
            Task {
                let answer = await Self.settle(work)
                self.queue.async { self.resume(suspended, with: answer) }
            }
            return
        }
        if status == 0 {
            let top = lua_gettop(co)
            var results: [LuaValue] = []
            if top > 0 { for i in 1...top { results.append(LuaValue.read(co, i)) } }
            Lua.unref(L, threadRef)
            return continuation.resume(returning: results)
        }
        let message = Lua.string(co, -1) ?? "error"
        luaL_traceback(L, co, message, 0)
        let traceback = Lua.string(L, -1) ?? message
        Lua.pop(L)
        Lua.unref(L, threadRef)
        continuation.resume(throwing: PluginError(message: traceback))
    }

    /// A coroutine waiting for a Basil function's answer. Only touched on the runtime's queue.
    private struct Suspended: @unchecked Sendable {
        let co: OpaquePointer
        let threadRef: Int32
        let continuation: CheckedContinuation<[LuaValue], Error>
    }

    /// Hands the answer to the waiting coroutine and runs it on; on the queue.
    private func resume(_ s: Suspended, with answer: APIResult) {
        guard !closed else {
            return s.continuation.resume(throwing: PluginError(message: "\(name) was turned off"))
        }
        switch answer {
        case .values(let values):
            lua_checkstack(s.co, Int32(values.count) + 2)
            lua_pushboolean(s.co, 1)
            for value in values { value.push(s.co) }
            step(s.co, s.threadRef, Int32(values.count) + 1, s.continuation)
        case .failure(let message):
            lua_pushboolean(s.co, 0)
            Lua.push(s.co, message)
            step(s.co, s.threadRef, 2, s.continuation)
        case .wait:
            step(s.co, s.threadRef, 0, s.continuation)
        }
    }

    /// Waits until the work gives values or a failure.
    private static func settle(_ work: @Sendable () async -> APIResult) async -> APIResult {
        var result = await work()
        while case .wait(let more) = result { result = await more() }
        return result
    }

    /// Calls a Lua function at once, waiting at most `timeout` (Multi-Rename placeholders, which
    /// Basil needs right away). Basil functions that wait fail there.
    func callNow(_ ref: Int32, _ args: [LuaValue], timeout: TimeInterval = 0.5) -> Result<[LuaValue], PluginError> {
        let done = DispatchSemaphore(value: 0)
        let result = Mutex<Result<[LuaValue], PluginError>>(.failure(PluginError(message: "\(name) did not answer in time")))
        queue.async { [self] in
            defer { done.signal() }
            guard let L, !closed else { return }
            let base = lua_gettop(L)
            Lua.pushRef(L, ref)
            for arg in args { arg.push(L) }
            if lua_pcall(L, Int32(args.count), LUA_MULTRET, 0) != 0 {
                let message = Lua.string(L, -1) ?? "error"
                lua_settop(L, base)
                result.withLock { $0 = .failure(PluginError(message: message)) }
                return
            }
            var values: [LuaValue] = []
            let top = lua_gettop(L)
            if top > base { for i in (base + 1)...top { values.append(LuaValue.read(L, i)) } }
            lua_settop(L, base)
            result.withLock { $0 = .success(values) }
        }
        _ = done.wait(timeout: .now() + timeout)
        return result.withLock { $0 }
    }

    /// Lets go of a function reference.
    func release(_ ref: Int32) {
        queue.async { [self] in
            guard let L, !closed else { return }
            Lua.unref(L, ref)
        }
    }

    /// Closes the state; coroutines still waiting end with an error.
    func close() {
        queue.sync {
            closed = true
            pending = [:]
            if let L { lua_close(L) }
            L = nil
        }
    }

    deinit {
        if let L { lua_close(L) }
    }
}

/// The C function behind every raw Basil function; its upvalue is the function's name.
private func luaTrampoline(_ L: OpaquePointer?) -> Int32 {
    guard let L else { return 0 }
    lua_getfield(L, Lua.registryIndex, "basil.runtime")
    let pointer = lua_touserdata(L, -1)
    Lua.pop(L)
    guard let pointer, let function = Lua.string(L, Lua.upvalueIndex(1)) else { return 0 }
    let runtime = Unmanaged<LuaRuntime>.fromOpaque(pointer).takeUnretainedValue()
    return runtime.call(function, L)
}
