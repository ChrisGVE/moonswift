-- MoonSwift test fixture: sample.lua
-- Used by HighlighterTests to verify token spans.

local function greet(name)
    if name == nil then
        return "hello world"
    end
    return "hello " .. name
end

local x = 42
local y = 3.14
local flag = true
local nothing = nil

-- simple loop
for i = 1, 10 do
    x = x + i
end

while flag do
    flag = false
end

print(greet("Lua"))
