-- Run the 16-task real suite through both backends.
-- Usage, from the repository root:
--   luajit -joff benchmarks/bench_backend_compare.lua
--   luajit benchmarks/bench_backend_compare.lua

local custom = assert(dofile("custom_loadstring_full.lua"))
local f = assert(io.open("benchmarks/benchreal.lua", "rb"))
local src = f:read("*a")
f:close()

local function make_env()
    return {
        assert = assert,
        error = error,
        ipairs = ipairs,
        pairs = pairs,
        next = next,
        select = select,
        type = type,
        tostring = tostring,
        tonumber = tonumber,
        pcall = pcall,
        xpcall = xpcall,
        setmetatable = setmetatable,
        getmetatable = getmetatable,
        rawget = rawget,
        rawset = rawset,
        rawequal = rawequal,
        table = table,
        string = string,
        math = math,
        print = print,
        os = { clock = os.clock },
    }
end

for _, backend in ipairs({ "legacy", "closure" }) do
    local chunk, err = custom(src, make_env(), {
        backend = backend,
        sourceName = "benchreal.lua",
        maxInstructions = math.huge,
    })
    if not chunk then
        print("COMPILE ERROR", backend, err)
    else
        local t0 = os.clock()
        local ok, rerr = pcall(chunk)
        local dt = os.clock() - t0
        print(string.format("BACKEND %s total %.4f s ok=%s err=%s",
            backend, dt, tostring(ok), tostring(rerr)))
    end
end
