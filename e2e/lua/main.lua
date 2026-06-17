-- main.lua — e2e/lua entry fragment
--
-- Touches all four subsystems: mock values (app.*), mock functions
-- (host_log / fetch_count), a loop + branch for the debugger, and locals +
-- stdlib references for completions.

local function classify(n)
    if n < 0 then
        return "negative"
    elseif n == 0 then
        return "zero"
    end
    return "positive"
end

local total = 0
for i = 1, app.limits.max do
    total = total + i
end

host_log("total", total)

if app.settings.verbose then
    print("verbose: total=" .. tostring(total) .. " base=" .. tostring(fetch_count()))
end

return classify(total)
