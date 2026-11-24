# Writing Basil plugins

Basil plugins are written in Lua and run in LuaJIT 2.1. Write them against Lua 5.1: LuaJIT's extensions (`bit`, `jit`, and `ffi` with permission) are there too.

## Where plugins live

Each plugin is a folder in `~/Library/Application Support/Basil/Plugins`. Settings > Plugins has Open Plugins Folder, lists every plugin found there, and turns each one on or off. A new plugin is off until you turn it on. Changes to a plugin's files take effect with Reload Plugin.

A plugin folder holds:

- `plugin.json`, the manifest, read before any of the plugin's code runs.
- `main.lua`, run when the plugin is turned on (another file can be named in the manifest).
- Any other `.lua` files, loaded with `require`.

```json
{
  "id": "com.example.wordcount",
  "name": "Word Count",
  "version": "1.0",
  "description": "A Words column for text files.",
  "author": "Your name",
  "main": "main.lua",
  "permissions": []
}
```

`id`, `name` and `version` are required. The id may use letters, digits, dots, dashes and underscores and must be unique among installed plugins.

## What a plugin can reach

Without permissions a plugin works only through Basil: it reads files through Basil's providers (local disks, servers, archives), changes them only through Basil's queue, and talks to the user through Basil's dialogs. Its Lua has the base library, `string`, `table`, `math`, `coroutine`, `bit`, `jit`, and from `os` only `time`, `clock`, `date` and `difftime`. There is no `io`, no `debug`, no `dofile` or `loadfile`, and no loading of compiled (binary) chunks.

Three permissions can be asked for in `permissions`. Basil asks the user once, when the plugin is turned on:

| Permission | Gives |
|---|---|
| `network` | `basil.http` |
| `shell` | `basil.shell` |
| `ffi` | `require("ffi")`: LuaJIT's FFI, which can call any C function, so everything the user's account can do |

## Paths and items

A path is a table `{ place = "local", path = "/Users/me/Music" }`. `place` is `"local"` for this Mac; other places (servers, archives, a plugin's own provider) get a token that Basil hands out. An absolute string such as `"/tmp"` also works where a path is expected and means this Mac.

An item is a path with more fields: `name`, `kind` (`"file"`, `"folder"`, `"link"`, `"folderlink"`, `"other"`), `size` (bytes, files only), `modified` and `created` (seconds since 1970), `hidden`.

Helpers: `basil.path(place, path)` (or `basil.path("/abs/local/path")`), `basil.name(p)`, `basil.parent(p)`, `basil.join(p, name)`.

## Functions

Functions that wait (dialogs, files, the shell, the network, Basil's operations) can be called from commands, columns, providers and operations; the plugin's code waits for the answer without holding up Basil. They cannot be used inside coroutines the plugin makes itself, or in Multi-Rename placeholders. A function that fails raises a Lua error; use `pcall` to handle it.

### Commands

```lua
basil.command{
  id = "greet",                 -- the command's id, unique in the plugin
  title = "Greet",              -- in menus and Settings > Keys
  keys = { "Ctrl+Shift+G" },    -- optional default keys, written like Settings > Keys writes them
  menu = "Commands/Plugins",    -- the menu, and submenus after slashes (this is the default)
  context = true,               -- also in the pane's context menu, in its Plugins submenu
  when = "files",               -- in the context menu only for "items", "files" or "folders" ("always" by default)
  run = function(ctx)
    -- ctx.pane.folder, ctx.pane.cursor (an item or nil), ctx.pane.items (selected, or the cursor item)
    -- ctx.other.folder: the other pane's folder
  end,
}
```

Users can change or remove the keys in Settings > Keys.

### Talking to the user

- `basil.announce(text)`: said by VoiceOver (or the system voice).
- `basil.ask(message, default)`: a text field; the text, or nil when cancelled.
- `basil.confirm(message, button)`: true or false.
- `basil.choose(message, { "One", "Two" })`: the number chosen, or nil.
- `basil.pane("active")`, `basil.pane("other")`: the pane as in `ctx.pane` and `ctx.other`.
- `basil.navigate(path)`: the active pane goes to a folder.
- `print(...)`, `basil.log(...)`: the plugin's log in Settings > Plugins (Show Log).

### Files

- `basil.fs.list(path)`: the items of a folder.
- `basil.fs.stat(path)`: one item, or nil when there is nothing there.
- `basil.fs.read(path, max)`: a file's contents as a string (at most `max` bytes, 16 MB by default).

### Changing files

These go to Basil's queue like the keys do, with the user's copy settings:

- `basil.copy(items, target)`, `basil.move(items, target)`: `items` is one path or a list, `target` a folder.
- `basil.delete(items, { trash = true })`: asks the user first, like F8; `trash = false` deletes permanently, like Shift+F8.
- `basil.mkdir(path)`, `basil.rename(path, newName)`.

Your own queue items, with progress, a log and Cancel:

```lua
basil.operation{
  title = "Counting words",
  kind = "Word count",          -- optional: its own entry in Settings > Sounds and Speech
  run = function(op)
    for i = 1, 10 do
      op:checkpoint()           -- waits while paused, raises an error once cancelled
      op:progress(i / 10, "step " .. i)
      op:items(i, 10)
    end
    op:log("done")
  end,
}
```

### Columns

```lua
basil.column{
  id = "words", title = "Words", width = 70, align = "right",
  fill = function(folder, items)
    return { ["notes.md"] = "120" }   -- text by item name; nil: the column is not shown here
  end,
}
```

Plugin columns appear in Settings > Views and Columns, where they are added to a view. A pane fills them after each folder loads or changes.

### Providers

A folder tree of the plugin's own, browsed like any folder:

```lua
local place = basil.provider{
  id = "notes", title = "My notes",
  list = function(path)                      -- the items of a folder, nil when there is none
    return { { name = "a.txt", size = 3 }, { name = "Sub", kind = "folder" } }
  end,
  read = function(path) return "abc" end,    -- optional: F3 and F5 then work
  item = function(path) end,                 -- optional: one item (otherwise the parent is listed)
}
basil.command{ id = "open", title = "Open My Notes", run = function() basil.navigate(basil.path(place, "/")) end }
```

Providers are read only for now.

### Multi-Rename placeholders

```lua
basil.placeholder{ name = "Upper", title = "Name in capitals", value = function(item, number) return item.name:upper() end }
```

`[=Upper]` in a Multi-Rename mask uses it. The function must answer at once and cannot use functions that wait.

### Shell and network (with permission)

- `basil.shell(command, { cwd = path, input = text })`: runs `/bin/sh -c command`; answers `{ status = 0, output = "..." }` (standard output and errors together). `cwd` must be on this Mac or a mounted share.
- `basil.http{ url = "https://...", method = "POST", headers = { ... }, body = "...", timeout = 60 }`: answers `{ status = 200, headers = { ... }, body = "..." }`.

### Modules

`require("util")` loads `util.lua` from the plugin's folder, `require("lib.text")` loads `lib/text.lua`. `basil.plugin` has the plugin's `id`, `name`, `version` and `folder`.

## Examples

`Plugins/Examples` in Basil's repository has a template (Hello World), a column (Word Count) and a command that uses the shell permission (Open on GitHub). Copy a folder into the Plugins folder and turn it on in Settings > Plugins.
