-- helper.lua — e2e/lua second fragment
--
-- A smaller second source so the navigator lists more than one fragment and
-- the editor/write-back can be exercised on a file other than main.lua.

local parts = {}
for word in string.gmatch("alpha beta gamma", "%a+") do
    parts[#parts + 1] = word:upper()
end

host_log("words", #parts)

return table.concat(parts, ",")
