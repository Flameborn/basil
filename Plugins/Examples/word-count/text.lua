-- Helpers in their own file, loaded with require("text").
local M = {}

local extensions = { txt = true, md = true, markdown = true, rst = true, tex = true, org = true, csv = true }

function M.isText(name)
  local ext = name:match("%.([^.]+)$")
  return ext ~= nil and extensions[ext:lower()] == true
end

function M.words(contents)
  local n = 0
  for _ in contents:gmatch("%S+") do n = n + 1 end
  return n
end

return M
