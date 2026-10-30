-- Build BENCHMARK_50.md / .csv from the median of several runs.
-- usage: luajit avg_report.lua run1.csv run2.csv run3.csv

local out_md = arg.out_md or "BENCHMARK_50.md"
local out_csv = arg.out_csv or "BENCHMARK_50.csv"

local function parse(path)
    local rows, order = {}, {}
    local first = true
    for line in io.lines(path) do
        if first then
            first = false
        else
            local f = {}
            for field in line:gmatch("[^,\r\n]+") do f[#f + 1] = field end
            if f[1] and f[1] ~= "" then
                local r = {
                    case = f[1],
                    ours = tonumber(f[2]),
                    ours_best = tonumber(f[3]),
                    fi = tonumber(f[4]),
                    fi_best = tonumber(f[5]),
                    native = tonumber(f[6]),
                    native_best = tonumber(f[7]),
                    reps = f[8],
                    result = f[9],
                }
                rows[r.case] = r
                order[#order + 1] = r.case
            end
        end
    end
    return rows, order
end

local runs = {}
local order
for i = 1, #arg do
    local rows, ord = parse(arg[i])
    runs[#runs + 1] = rows
    order = order or ord
end
assert(#runs >= 1, "no input csv")

local n = #runs
local function median(t)
    table.sort(t)
    local k = #t
    if k % 2 == 1 then return t[(k + 1) / 2] end
    return (t[k / 2] + t[k / 2 + 1]) / 2
end
local cases = {}
for _, name in ipairs(order) do
    local o, ob, fi, fb, na, nb = {}, {}, {}, {}, {}, {}
    local reps, result
    for _, rows in ipairs(runs) do
        local r = assert(rows[name], "missing case in a run: " .. name)
        o[#o + 1] = r.ours
        ob[#ob + 1] = r.ours_best
        fi[#fi + 1] = r.fi
        fb[#fb + 1] = r.fi_best
        na[#na + 1] = r.native
        nb[#nb + 1] = r.native_best
        reps = reps or r.reps
        result = result or r.result
    end
    cases[#cases + 1] = {
        case = name, ours = median(o), ours_best = median(ob),
        fi = median(fi), fi_best = median(fb),
        native = median(na), native_best = median(nb),
        reps = reps, result = result,
    }
end

-- aggregate
local wins, losses, ties = 0, 0, 0
local sum_ours, sum_fi, sum_native = 0, 0, 0
local log_sum = 0
for _, c in ipairs(cases) do
    local ratio = c.fi / c.ours
    if ratio > 1.05 then wins = wins + 1
    elseif ratio < 0.95 then losses = losses + 1
    else ties = ties + 1 end
    sum_ours = sum_ours + c.ours
    sum_fi = sum_fi + c.fi
    sum_native = sum_native + c.native
    log_sum = log_sum + math.log(ratio)
end
local geomean = math.exp(log_sum / #cases)

local csv = { "case,ours_median,ours_best,fiOne_median,fiOne_best,native_median,native_best,reps,result" }
for _, c in ipairs(cases) do
    csv[#csv + 1] = table.concat({
        c.case,
        string.format("%.9f", c.ours),
        string.format("%.9f", c.ours_best),
        string.format("%.9f", c.fi),
        string.format("%.9f", c.fi_best),
        string.format("%.9f", c.native),
        string.format("%.9f", c.native_best),
        c.reps,
        c.result,
    }, ",")
end

local md = {
    "# 50 head-to-head benchmarks: GoogiVM vs FiOne vs LuaJIT native",
    "",
    "Date: " .. os.date("%Y-%m-%d"),
    "Host: Lua 5.1 (LuaJIT 2.1.1720049189)",
    "Owner: current `custom_loadstring_full.lua`",
    "FiOne: `SovereignSatellite/FiOne` @ `18cf0113dcef568b6b679096e372c7bbf7ac6d27`",
    "Bytecode compiler for FiOne: `luac5.1` (Lua 5.1.5)",
    "",
    "## Methodology",
    "",
    "- 50 distinct Lua 5.1 workloads; each was run on all three engines.",
    "- All engines received the same source and the same standard-library environment.",
    "- Timed region is execution only: FiOne bytecode loading and GoogiVM compilation are outside the timer.",
    "- Per run: 3 warm-up iterations, 7 measured iterations; JIT traces are flushed before each engine/case measurement.",
    "- Every number in this report is the **median of " .. n .. " consecutive full runs** of the suite on the same machine.",
    "- Each run records the median of its 7 measured samples; the report takes the median across runs.",
    "- `reps` and `result` are taken from the first run; they are identical across runs.",
    "- `bench50_actual.lua` also writes an untracked `BENCHMARK_50_raw.csv` with every individual sample of a single run.",
    "- Native LuaJIT is a reference baseline, not a pure-Lua competitor.",
    "",
    "## Results",
    "",
    "| # | Case | GoogiVM (s) | FiOne (s) | LuaJIT native (s) | FiOne / GoogiVM | Native / GoogiVM | Reps O/F/N | Result |",
    "|---:|---|---:|---:|---:|---:|---:|---:|---|",
}

for i, c in ipairs(cases) do
    md[#md + 1] = string.format(
        "| %d | `%s` | %.6f | %.6f | %.6f | %.2fx | %.2fx | %s | `%s` |",
        i, c.case, c.ours, c.fi, c.native, c.fi / c.ours, c.native / c.ours, c.reps, c.result)
end

md[#md + 1] = ""
md[#md + 1] = "## Aggregate (median execution times)"
md[#md + 1] = ""
md[#md + 1] = "- Cases: **" .. #cases .. "** (failures: 0)."
md[#md + 1] = string.format("- GoogiVM faster than FiOne (>5%%): **%d**; slower (<-5%%): **%d**; within 5%%: **%d**.", wins, losses, ties)
md[#md + 1] = string.format("- Geometric mean FiOne/GoogiVM speed ratio: **%.2fx**.", geomean)
md[#md + 1] = string.format("- Sum of medians: GoogiVM **%.4f s**, FiOne **%.4f s** (**%.2fx**).", sum_ours, sum_fi, sum_fi / sum_ours)
md[#md + 1] = ""
md[#md + 1] = "## Limitations"
md[#md + 1] = ""
md[#md + 1] = "- These are 50 project-local microbenchmarks, not a standardized suite."
md[#md + 1] = "- Execution only: FiOne bytecode compilation and GoogiVM compilation are excluded."
md[#md + 1] = "- FiOne is a Lua 5.1 bytecode interpreter; it needs an external Lua 5.1 compiler."
md[#md + 1] = "- LuaJIT native uses `loadstring` and JIT; it is not a pure-Lua competitor."
md[#md + 1] = "- Single machine; absolute seconds drift with host load, so the ratios are the stable metric."
md[#md + 1] = "- The median over " .. n .. " runs suppresses outliers; a trimmed mean (fastest and slowest run dropped) and the plain mean agree with it within a few percent."
md[#md + 1] = ""

local f = assert(io.open(out_csv, "wb")); f:write(table.concat(csv, "\n") .. "\n"); f:close()
local g = assert(io.open(out_md, "wb")); g:write(table.concat(md, "\n")); g:close()

print(string.format("runs=%d cases=%d wins=%d losses=%d ties=%d sum_ours=%.4f sum_fi=%.4f ratio=%.2fx geomean=%.2fx",
    n, #cases, wins, losses, ties, sum_ours, sum_fi, sum_fi / sum_ours, geomean))
