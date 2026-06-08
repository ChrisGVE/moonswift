-- undefined-global.lua — lint-undefined-global fixture
--
-- References `notDeclaredAnywhere`, which is not a Lua standard-library
-- global and is not in the luaswift catalog.  Luacheck must report a W111
-- (or another W1xx) undefined-global warning on this line.
return notDeclaredAnywhere
