-- print-and-error.lua — run-print-and-error fixture
--
-- Verifies that print output captured before a runtime error is not lost:
-- the "before error" line must arrive in the output collector, and the run
-- outcome must be .error (not .done).

print("before error")
error("deliberate runtime error")
