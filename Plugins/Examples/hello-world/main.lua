-- The smallest useful plugin: one command in Commands > Plugins and in the context menu.
-- Give it a key in Settings > Keys, or add keys = { "Ctrl+Shift+H" } below.
basil.command{
  id = "hello",
  title = "Say Hello",
  context = true,
  run = function(ctx)
    local items = ctx.pane.items
    local where = basil.name(ctx.pane.folder)
    if #items == 0 then
      basil.announce("Hello from a plugin, in " .. where)
    elseif #items == 1 then
      basil.announce("Hello from a plugin, " .. items[1].name .. " in " .. where)
    else
      basil.announce("Hello from a plugin, " .. #items .. " items in " .. where)
    end
  end,
}
