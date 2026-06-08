-- runaway-loop.lua — run-runaway-loop fixture
--
-- An infinite loop intended to be terminated by the Lua instruction-count
-- hook set via RunService.run(_:config:) with a small instructionLimit.
--
-- NEVER run this without an instruction limit — it does not terminate.
-- The test that exercises this file sets instructionLimit = 1_000 in its
-- RunConfig so CI wall-clock impact is negligible (< 1 ms).
while true do
end
