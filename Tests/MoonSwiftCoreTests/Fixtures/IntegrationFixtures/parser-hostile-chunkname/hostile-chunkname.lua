-- hostile-chunkname.lua — parser-hostile-chunkname fixture
--
-- Contains "]:" and "]:N:" substrings that look like Lua long-bracket
-- terminators.  When LintService wraps this code in luaLongString() the
-- encoder must choose a bracket level that does not prematurely terminate
-- the long string, so the round-trip is lossless.
--
-- The hostile characters appear inside a string literal, so the script is
-- syntactically valid.  syntaxPrePass must return nil; lint may return warnings
-- only for actual Lua style issues (none expected for this code).
local marker = "]:1: something that looks like a Lua error"
local nested = "[[nested]] and ]:2: embedded"
return marker, nested
