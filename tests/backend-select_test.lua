local backend_select = dofile("conf.d/backend-select.lua")

local function fake_cache(values)
    return {
        get = function(_, key)
            return values[key]
        end,
    }
end

local function run_case(case)
    local actual = backend_select.pick_backend(case.use_leader, fake_cache(case.cache))
    if actual ~= case.expected then
        error(
            case.name
                .. ": expected=" .. tostring(case.expected)
                .. " actual=" .. tostring(actual)
        )
    end
end

local cases = {
    {
        name = "leader route uses leader",
        use_leader = true,
        cache = {
            leader = "10.0.1.10:12346",
            follower_1 = "10.0.1.11:12346",
        },
        expected = "10.0.1.10:12346",
    },
    {
        name = "leader route with missing leader returns nil",
        use_leader = true,
        cache = {
            follower_1 = "10.0.1.11:12346",
        },
        expected = nil,
    },
    {
        name = "follower route uses follower_1",
        use_leader = false,
        cache = {
            leader = "10.0.1.10:12346",
            follower_1 = "10.0.1.11:12346",
        },
        expected = "10.0.1.11:12346",
    },
    {
        name = "follower route falls back to leader when follower_1 is empty",
        use_leader = false,
        cache = {
            leader = "10.0.1.10:12346",
            follower_1 = "",
        },
        expected = "10.0.1.10:12346",
    },
    {
        name = "follower route falls back to leader when follower_1 is missing",
        use_leader = false,
        cache = {
            leader = "10.0.1.10:12346",
        },
        expected = "10.0.1.10:12346",
    },
    {
        name = "follower route with no backends returns nil",
        use_leader = false,
        cache = {},
        expected = nil,
    },
}

local passed = 0
for i, case in ipairs(cases) do
    local ok, err = pcall(function()
        run_case(case)
    end)
    if ok then
        passed = passed + 1
        io.write("PASS: case_", tostring(i), " ", case.name, "\n")
    else
        io.write("FAIL: case_", tostring(i), " ", tostring(err), "\n")
    end
end

io.write("Summary: ", tostring(passed), " passed, ", tostring(#cases - passed), " failed\n")
if passed ~= #cases then
    os.exit(1)
end
