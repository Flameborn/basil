-- Uses the shell permission to ask git where the repository lives, then opens the page.
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function git(folder, args)
  local result = basil.shell("git " .. args, { cwd = folder })
  if result.status ~= 0 then return nil end
  return trim(result.output)
end

-- git@github.com:owner/repo.git or https://github.com/owner/repo(.git) to owner/repo
local function repository(remote)
  local path = remote:match("github%.com[:/](.+)$")
  if not path then return nil end
  return (path:gsub("%.git$", ""))
end

basil.command{
  id = "open",
  title = "Open on GitHub",
  context = true,
  when = "items",
  run = function(ctx)
    local item = ctx.pane.cursor
    if not item or item.place ~= "local" then
      basil.announce("Open on GitHub works on files on this Mac")
      return
    end
    local folder = item.kind == "folder" and item or basil.parent(item)
    local top = git(folder, "rev-parse --show-toplevel")
    local remote = top and git(folder, "remote get-url origin")
    local repo = remote and repository(remote)
    if not repo then
      basil.announce(item.name .. " is not in a repository with a GitHub remote named origin")
      return
    end
    local branch = git(folder, "rev-parse --abbrev-ref HEAD") or "HEAD"
    local relative = item.path:sub(#top + 2)
    local kind = item.kind == "folder" and "tree" or "blob"
    local url = "https://github.com/" .. repo .. "/" .. kind .. "/" .. branch .. "/" .. relative
    basil.shell("open " .. quote(url))
    basil.announce("Opened " .. item.name .. " on GitHub")
  end,
}
