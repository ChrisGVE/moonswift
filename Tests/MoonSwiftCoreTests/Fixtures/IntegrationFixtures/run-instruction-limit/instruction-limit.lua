-- instruction-limit.lua — run-instruction-limit fixture
--
-- Prints one line before entering an infinite loop so the integration test
-- can verify that output captured before the instruction-limit trip arrives
-- even when the run ends abnormally.
--
-- The test arms instructionLimit = 5_000 via RunConfig; the loop trips the
-- hook and the run returns .limitExceeded(.instructions).
print("before limit")
local i = 0
while true do
    i = i + 1
end
