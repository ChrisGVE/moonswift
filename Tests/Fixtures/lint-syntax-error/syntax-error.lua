-- syntax-error.lua — lint-syntax-error fixture
--
-- This file is intentionally a VALID Lua script used as a provenance
-- anchor.  The integration test injects an invalid statement after this
-- script to test the syntaxPrePass path:
--
--     let code = try! String(contentsOf: fixtureURL, encoding: .utf8)
--               + "\nthis is not valid Lua ==="
--
-- Encoding the invalid fragment inside the file would prevent stylua
-- from formatting the file, which would block the pre-commit hook.
-- The test constructs the bad fragment at runtime instead.
local x = 1
local y = 2
-- The test appends an invalid statement here.
