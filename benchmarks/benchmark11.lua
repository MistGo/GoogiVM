--[[
  GoogiVM benchmark harness: 11 standard micro-cases.

  Modes
  -----
  In-game (Scrap Mechanic / ScrapComputers):
      Paste this entire file into a computer's Main.lua and run it.
      `loadstring` is provided by the sandbox and compiles with whichever VM
      is active (`GOOGI_USE_CUSTOM_VM`), so the identical script measures
      GoogiVM and FiOne under the same conditions.

  Desktop:
      luajit benchmarks/benchmark11.lua            -- auto: GoogiVM if local
      luajit benchmarks/benchmark11.lua googi      -- force local GoogiVM
      luajit benchmarks/benchmark11.lua native     -- force host loadstring
      lua    benchmarks/benchmark11.lua googi baseline.csv

      The optional 2nd argument is a previously exported CSV; when present the
      script also reports per-case ratios and their geometric mean.

  Artifacts (written only when `io` is available)
  ----------------------------------------------
      benchmark11_<label>.csv       per-case medians, best, worst, reps
      benchmark11_<label>_raw.txt   full raw console log

  The summary reports both the sum of medians and the geometric mean, because
  a sum is dominated by the slowest case while the geometric mean weights all
  cases equally.
]]

local MODE = "auto"        -- "auto" | "googi" | "vm" | "native"
local LABEL = nil          -- engine label; defaults to the resolved name
local BASELINE_PATH = nil  -- CSV exported by a previous run (optional)
local SAMPLES = 3          -- measured samples per case
local MIN_SAMPLE = 0.01    -- grow reps until one sample lasts this long

----------------------------------------------------------------------------
-- Environment handed to every benchmark chunk
----------------------------------------------------------------------------

local ENV = {}

do
    -- Explicit assignments instead of iterating _G: restricted sandboxes may
    -- not expose `_G`, and referencing an absent global simply yields nil.
    ENV.assert = assert
    ENV.error = error
    ENV.ipairs = ipairs
    ENV.pairs = pairs
    ENV.next = next
    ENV.select = select
    ENV.type = type
    ENV.tostring = tostring
    ENV.tonumber = tonumber
    ENV.pcall = pcall
    ENV.xpcall = xpcall
    ENV.setmetatable = setmetatable
    ENV.getmetatable = getmetatable
    ENV.rawget = rawget
    ENV.rawset = rawset
    ENV.rawequal = rawequal
    ENV.unpack = unpack
    ENV.math = math
    ENV.string = string
    ENV.table = table
    ENV.os = os
end

----------------------------------------------------------------------------
-- Cases
----------------------------------------------------------------------------

local CASES = {
    {
        name = "fib(30) recursive", expected = 832040, warmup = 0, samples = 1,
        src = [[
local function fib(n)
    if n < 2 then return n end
    return fib(n - 1) + fib(n - 2)
end
return fib(30)
]],
    },
    {
        name = "fib(32) recursive", expected = 2178309, warmup = 0, samples = 1,
        src = [[
local function fib(n)
    if n < 2 then return n end
    return fib(n - 1) + fib(n - 2)
end
return fib(32)
]],
    },
    {
        name = "1M function calls", expected = 1000000,
        src = [[
local function inc(x) return x + 1 end
local sum = 0
for _ = 1, 1000000 do sum = inc(sum) end
return sum
]],
    },
    {
        name = "1M closure calls", expected = 1000000,
        src = [[
local n = 0
local function next_value() n = n + 1; return n end
local sum = 0
for _ = 1, 1000000 do sum = next_value() end
return sum
]],
    },
    {
        name = "100k upvalue increments", expected = 100000,
        src = [[
local n = 0
local function increment() n = n + 1 end
for _ = 1, 100000 do increment() end
return n
]],
    },
    {
        name = "100k vararg calls", expected = 300000,
        src = [[
local function count_args(...) return select('#', ...) end
local sum = 0
for i = 1, 100000 do sum = sum + count_args(i, i + 1, i + 2) end
return sum
]],
    },
    {
        name = "100k metatable adds", expected = 300000,
        src = [[
local mt = { __add = function(a, b) return a.value + b.value end }
local a = setmetatable({ value = 1 }, mt)
local b = setmetatable({ value = 2 }, mt)
local sum = 0
for _ = 1, 100000 do sum = sum + (a + b) end
return sum
]],
    },
    {
        name = "200k table writes + reads", expected = 20000100000,
        src = [[
local t = {}
for i = 1, 200000 do t[i] = i end
local sum = 0
for i = 1, 200000 do sum = sum + t[i] end
return sum
]],
    },
    {
        name = "1M branch/mod iterations", expected = 250000000000,
        src = [[
local sum = 0
for i = 1, 1000000 do
    if i % 2 == 0 then sum = sum + i else sum = sum - 1 end
end
return sum
]],
    },
    {
        name = "primes <= 50000", expected = 5133,
        src = [[
local function count_primes(limit)
    local count = 0
    for n = 2, limit do
        local is_prime = true
        local limit_sqrt = math.floor(math.sqrt(n))
        for d = 2, limit_sqrt do
            if n % d == 0 then is_prime = false; break end
        end
        if is_prime then count = count + 1 end
    end
    return count
end
return count_primes(50000)
]],
    },
    {
        name = "10k string concatenations", expected = 10000,
        src = [[
local s = ""
for _ = 1, 10000 do s = s .. "x" end
return #s
]],
    },
}

----------------------------------------------------------------------------
-- Output helpers (io is optional: it does not exist inside the sandbox)
----------------------------------------------------------------------------

local log = {}

local function emit(line)
    line = tostring(line)
    log[#log + 1] = line
    print(line)
end

local function sanitize(name)
    return (tostring(name):gsub("[^%w%.%-_]+", "_"))
end

local function write_file(path, data)
    local io_lib = io
    if not io_lib or not io_lib.open then return false end
    local ok, fh = pcall(io_lib.open, path, "wb")
    if not ok or not fh then return false end
    fh:write(data)
    fh:close()
    return true
end

local function fmt(x, digits)
    if type(x) ~= "number" then return tostring(x) end
    return string.format("%." .. (digits or 4) .. "f", x)
end

----------------------------------------------------------------------------
-- Engine resolution
----------------------------------------------------------------------------

local function resolve_engine()
    local mode = MODE
    if type(arg) == "table" and arg[1] then mode = arg[1] end
    if type(arg) == "table" and arg[2] then
        if arg[2]:lower():sub(-4) == ".csv" then
            BASELINE_PATH = arg[2]
        else
            LABEL = LABEL or arg[2]
        end
    end

    if mode == "vm" or mode == "sandbox" then
        assert(loadstring, "sandbox loadstring is not available")
        return loadstring, LABEL or "sandbox-loadstring", false, false
    end
    if mode == "native" or mode == "host" then
        assert(loadstring, "host loadstring is not available")
        return loadstring, LABEL or "host-loadstring", true, false
    end
    if mode == "googi" then
        assert(type(dofile) == "function", "dofile is not available")
        local ok, fn = pcall(dofile, "custom_loadstring_full.lua")
        assert(ok and type(fn) == "function",
            "cannot load custom_loadstring_full.lua: " .. tostring(fn))
        return fn, LABEL or "GoogiVM", false, true
    end

    -- auto
    if type(arg) ~= "table" and loadstring then
        -- Inside a sandbox there is no CLI arg table; loadstring is the
        -- sandbox loader, which is exactly what we want to measure.
        return loadstring, LABEL or "sandbox-loadstring", false, false
    end
    if type(dofile) == "function" then
        local ok, fn = pcall(dofile, "custom_loadstring_full.lua")
        if ok and type(fn) == "function" then
            return fn, LABEL or "GoogiVM", false, true
        end
    end
    assert(loadstring, "no Lua loader available")
    return loadstring, LABEL or "host-loadstring", true, false
end

local engine, label, is_native, has_options = resolve_engine()

-- fib(32) needs well over the default 50M-instruction budget on an
-- interpreted VM; benchmark runs should never be cut short by a quota.
local OPTIONS = {
    maxInstructions = math.huge,
    maxCallDepth = math.huge,
    maxStack = math.huge,
}

local function compile(src)
    local fn, err
    if has_options then
        fn, err = engine(src, ENV, OPTIONS)
    elseif is_native then
        fn, err = engine(src, "@bench")
    else
        -- Sandbox loaders use loadstring(code, env); host loadstring expects a
        -- string chunk name, so fall back to the one-argument form.
        local ok, a, b = pcall(engine, src, ENV)
        if ok and a then
            fn, err = a, b
        else
            local ok2, a2, b2 = pcall(engine, src)
            if ok2 then
                fn, err = a2, b2
            else
                fn, err = nil, ok and b or a
            end
        end
    end
    if not fn then return nil, err end
    if setfenv then
        pcall(setfenv, fn, ENV)
    end
    return fn
end

----------------------------------------------------------------------------
-- Measurement
----------------------------------------------------------------------------

local function median(values, n)
    local sorted = {}
    for i = 1, n do sorted[i] = values[i] end
    table.sort(sorted)
    if n % 2 == 1 then
        return sorted[(n + 1) / 2]
    end
    return (sorted[n / 2] + sorted[n / 2 + 1]) / 2
end

local function measure(fn, samples)
    local reps = 1
    while reps <= 4096 do
        local started = os.clock()
        for _ = 1, reps do fn() end
        if os.clock() - started >= MIN_SAMPLE then break end
        reps = reps * 2
    end

    local times = {}
    local best, worst
    for i = 1, samples do
        local started = os.clock()
        for _ = 1, reps do fn() end
        local elapsed = (os.clock() - started) / reps
        times[i] = elapsed
        if not best or elapsed < best then best = elapsed end
        if not worst or elapsed > worst then worst = elapsed end
    end
    return median(times, samples), best, worst, reps
end

----------------------------------------------------------------------------
-- Baseline CSV (optional)
----------------------------------------------------------------------------

local function read_file(path)
    local io_lib = io
    if not io_lib or not io_lib.open then return nil end
    local ok, fh = pcall(io_lib.open, path, "rb")
    if not ok or not fh then return nil end
    local data = fh:read("*a")
    fh:close()
    return data
end

local function load_baseline(path)
    local data = path and read_file(path)
    if not data then return nil end
    local map = {}
    for line in data:gmatch("[^\r\n]+") do
        local fields = {}
        for field in (line .. ","):gmatch("([^,]*),") do
            fields[#fields + 1] = field
        end
        local case_name = fields[2]
        local value = tonumber(fields[3])
        if case_name and value and case_name ~= "case" then
            map[case_name] = value
        end
    end
    if next(map) == nil then return nil end
    return map
end

----------------------------------------------------------------------------
-- Run
----------------------------------------------------------------------------

emit("== GoogiVM benchmark: 11 micro-cases ==")
emit("engine: " .. label)
emit("samples: " .. SAMPLES .. ", min sample time: " .. MIN_SAMPLE .. " s")
emit("")

local rows = {}
local failures = 0

for i = 1, #CASES do
    local case = CASES[i]
    local fn, cerr = compile(case.src)
    if not fn then
        failures = failures + 1
        emit(string.format("%2d %-30s COMPILE ERROR  %s", i, case.name, tostring(cerr)))
        rows[#rows + 1] = { name = case.name, error = "compile: " .. tostring(cerr) }
    else
        local ok, value = pcall(fn)
        if not ok then
            failures = failures + 1
            emit(string.format("%2d %-30s RUNTIME ERROR  %s", i, case.name, tostring(value)))
            rows[#rows + 1] = { name = case.name, error = "runtime: " .. tostring(value) }
        elseif value ~= case.expected then
            failures = failures + 1
            emit(string.format("%2d %-30s WRONG RESULT   got %s, want %s",
                i, case.name, tostring(value), tostring(case.expected)))
            rows[#rows + 1] = { name = case.name, error = "result: " .. tostring(value) }
        else
            local warmup = case.warmup or 1
            for _ = 1, warmup do fn() end
            local samples = case.samples or SAMPLES
            if samples < 1 then samples = 1 end
            local med, best, worst, reps = measure(fn, samples)
            rows[#rows + 1] = {
                name = case.name, median = med, best = best, worst = worst,
                reps = reps, samples = samples, result = value,
            }
            emit(string.format("%2d %-30s %9.4f s  (best %.4f, worst %.4f, reps %d)",
                i, case.name, med, best, worst, reps))
        end
    end
end

----------------------------------------------------------------------------
-- Summary: sum of medians + geometric mean
----------------------------------------------------------------------------

local sum, count, logsum = 0, 0, 0
local base_sum, ratio_sum, ratios_count, ratios_log = 0, 0, 0, 0

local baseline = load_baseline(BASELINE_PATH)

for i = 1, #rows do
    local row = rows[i]
    if row.median then
        sum = sum + row.median
        count = count + 1
        if row.median > 0 then logsum = logsum + math.log(row.median) end
        if baseline and baseline[row.name] and row.median > 0 then
            local ratio = baseline[row.name] / row.median
            base_sum = base_sum + baseline[row.name]
            ratio_sum = ratio_sum + ratio
            ratios_count = ratios_count + 1
            if ratio > 0 then ratios_log = ratios_log + math.log(ratio) end
        end
    end
end

emit("")
emit("---------------------------------------------------------------")
emit(string.format("cases: %d, failures: %d", #CASES, failures))
emit(string.format("sum of medians:        %.4f s", sum))
if count > 0 then
    emit(string.format("geometric mean:        %.4f s", math.exp(logsum / count)))
end
if ratios_count > 0 then
    emit(string.format("baseline geomean ratio: %.3fx over %d cases",
        math.exp(ratios_log / ratios_count), ratios_count))
    emit(string.format("baseline mean ratio:    %.3fx", ratio_sum / ratios_count))
    if sum > 0 then
        emit(string.format("baseline total ratio:   %.3fx", base_sum / sum))
    end
    emit("(ratio = baseline / this engine; > 1 means this engine is faster)")
end

----------------------------------------------------------------------------
-- CSV export (reproducible; written when io is available)
----------------------------------------------------------------------------

local csv = {
    "label,case,median_s,best_s,worst_s,reps,samples,result,status",
}
for i = 1, #rows do
    local row = rows[i]
    if row.error then
        csv[#csv + 1] = string.format("%s,%s,,,,,,,%s",
            label, row.name, (row.error:gsub(",", ";")))
    else
        csv[#csv + 1] = string.format("%s,%s,%.9f,%.9f,%.9f,%d,%d,%s,ok",
            label, row.name, row.median, row.best, row.worst,
            row.reps, row.samples, tostring(row.result))
    end
end
local csv_text = table.concat(csv, "\n") .. "\n"

local base = "benchmark11_" .. sanitize(label)
local wrote_csv = write_file(base .. ".csv", csv_text)
local wrote_raw = write_file(base .. "_raw.txt", table.concat(log, "\n") .. "\n")

if wrote_csv or wrote_raw then
    emit("")
    if wrote_csv then emit("wrote " .. base .. ".csv") end
    if wrote_raw then emit("wrote " .. base .. "_raw.txt") end
else
    emit("")
    emit("(no io available: results are console-only)")
end

if failures > 0 then
    error("benchmark finished with " .. failures .. " failing case(s)", 0)
end
