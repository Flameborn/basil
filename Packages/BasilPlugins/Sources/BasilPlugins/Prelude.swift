extension LuaRuntime {
    /// Runs first in every plugin's state with the raw Basil functions as its argument. Raw
    /// functions answer (true, results...) or (false, message); the wrappers raise the message
    /// as a Lua error at the plugin's line. The raw table stays a local of this chunk, out of
    /// the plugin's reach (there is no debug library).
    static let prelude = #"""
    local raw = ...
    local unpack, select, type, error, maxn = unpack, select, type, error, table.maxn

    local function pack(...) return { n = select("#", ...), ... } end

    local function call(name, ...)
      local f = raw[name]
      if not f then error("basil." .. name .. " is not available", 3) end
      local res = pack(f(...))
      if not res[1] then error(res[2], 3) end
      return unpack(res, 2, res.n)
    end

    local function wrap(name)
      return function(...) return call(name, ...) end
    end

    basil = {}
    for _, name in ipairs({ "command", "column", "provider", "placeholder", "operation",
                            "copy", "move", "delete", "mkdir", "rename",
                            "announce", "navigate", "ask", "confirm", "choose",
                            "shell", "http", "pane" }) do
      basil[name] = wrap(name)
    end
    basil.fs = { list = wrap("list"), stat = wrap("stat"), read = wrap("read") }
    basil.plugin = call("info")

    -- Paths are tables { place = "local", path = "/Users/me" }; items are paths with more fields.
    function basil.path(place, path)
      if path == nil then return { place = "local", path = place } end
      return { place = place, path = path }
    end
    function basil.name(p)
      return (p.path:match("([^/]+)/?$")) or ""
    end
    function basil.parent(p)
      local parent = p.path:match("^(.*)/[^/]+/?$")
      if parent == nil then return nil end
      if parent == "" then parent = "/" end
      return { place = p.place, path = parent }
    end
    function basil.join(p, name)
      local base = p.path
      if base:sub(-1) ~= "/" then base = base .. "/" end
      return { place = p.place, path = base .. name }
    end

    local function log(...)
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring((select(i, ...))) end
      raw.log(table.concat(parts, "\t"))
    end
    print = log
    basil.log = log

    -- No files outside Basil's providers, no binary chunks.
    dofile, loadfile = nil, nil
    local loadstring_ = loadstring
    local function nobinary(s)
      return type(s) == "string" and s:byte(1) == 27
    end
    loadstring = function(s, name)
      if nobinary(s) then return nil, "binary chunks are not allowed" end
      return loadstring_(s, name)
    end
    load = function(source, name)
      if type(source) == "function" then
        local parts = {}
        while true do
          local piece = source()
          if piece == nil or piece == "" then break end
          parts[#parts + 1] = piece
        end
        source = table.concat(parts)
      end
      return loadstring(source, name)
    end
    local os_ = os
    os = { time = os_.time, clock = os_.clock, date = os_.date, difftime = os_.difftime }

    -- require: the plugin's own .lua files (a.b is a/b.lua), bit, jit, and ffi with permission.
    local ffi = __ffi
    __ffi = nil
    local loaded = { bit = bit, jit = jit, string = string, table = table, math = math, os = os, coroutine = coroutine }
    if ffi then loaded.ffi = ffi end
    function require(name)
      if loaded[name] ~= nil then return loaded[name] end
      if name == "ffi" then error("this plugin may not use LuaJIT's ffi (it needs the ffi permission)", 2) end
      local source, chunkname = call("module", name)
      local chunk, err = loadstring(source, chunkname)
      if not chunk then error(err, 2) end
      local result = chunk(name)
      if result == nil then result = true end
      loaded[name] = result
      return result
    end

    -- Queue items written in Lua: run(op) gets functions for progress, the log and cancelling.
    function __basil_runOperation(run, id)
      local op = {}
      local function method(f)
        return function(a, ...)
          if a == op then return f(...) end
          return f(a, ...)
        end
      end
      op.progress = method(function(fraction, detail) return call("opProgress", id, fraction, detail) end)
      op.log = method(function(text) return call("opLog", id, tostring(text)) end)
      op.items = method(function(done, total) return call("opItems", id, done, total) end)
      op.checkpoint = method(function() return call("opCheckpoint", id) end)
      return run(op)
    end
    """#
}
