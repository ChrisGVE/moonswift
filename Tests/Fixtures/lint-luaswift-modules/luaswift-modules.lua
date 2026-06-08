-- luaswift-modules.lua — lint-luaswift-modules fixture
--
-- References the luaswift root table and luaswift.json.decode, both of which
-- are base catalog entries.  When the catalog globals are passed to luacheck
-- there must be zero W1xx (undefined-global/field) warnings.
local data = luaswift.json.decode("{}")
local t = luaswift
return data, t
