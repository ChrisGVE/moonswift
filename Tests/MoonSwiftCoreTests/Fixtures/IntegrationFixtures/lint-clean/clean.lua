-- clean.lua — lint-clean fixture
--
-- A style-clean Lua script with no undefined globals, no unused variables,
-- and no syntax issues.  LintService must return an empty diagnostic list.
local function add(a, b)
    return a + b
end

return add(1, 2)
