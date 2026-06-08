-- opt-in-modules.lua — lint-opt-in-modules fixture
--
-- References luaswift.iox, an opt-in catalog module.  When the integration
-- test lints this with extra_modules = ["iox"], the luaswift.iox field is
-- recognised and the W1xx count is lower than without iox.
local f = luaswift.iox
return f
