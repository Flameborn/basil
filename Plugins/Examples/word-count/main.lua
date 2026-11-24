-- A column filled per folder. fill gets the folder and its items and answers a table of
-- text by item name; items left out show nothing.
local text = require("text")

basil.column{
  id = "words",
  title = "Words",
  width = 70,
  align = "right",
  fill = function(folder, items)
    local result = {}
    for _, item in ipairs(items) do
      if item.kind == "file" and text.isText(item.name) and (item.size or 0) <= 1024 * 1024 then
        local ok, contents = pcall(basil.fs.read, item)
        if ok then result[item.name] = tostring(text.words(contents)) end
      end
    end
    return result
  end,
}
