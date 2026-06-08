-- sandbox-test.lua — run-sandbox-test fixture
--
-- Probes the os table to determine whether the sandbox has stripped
-- os.getenv (sandboxed mode) or left it in place (unrestricted mode).
--
-- In sandboxed mode:  os.getenv is nil  → prints "sandboxed"
-- In unrestricted mode: os.getenv is a function → prints "unrestricted"
--
-- The integration test runs this under both RunConfig modes and asserts
-- the corresponding output line.
if type(os.getenv) == "function" then
    print("unrestricted")
else
    print("sandboxed")
end
