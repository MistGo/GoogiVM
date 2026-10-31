-- Compares the experimental closure backend with the legacy interpreter.
-- Run from the repository root:
--   luajit -joff benchmarks/bench_closure_backend.lua
--   luajit benchmarks/bench_closure_backend.lua

local rt = dofile("gvm_runtime.lua")
local build = dofile("gvm_compiler.lua")
local compile = build(rt)

local function best_of(samples, fn)
    local best, result
    for _ = 1, samples or 5 do
        local t0 = os.clock()
        result = fn()
        local dt = os.clock() - t0
        if not best or dt < best then best = dt end
    end
    return best, result
end

local function bench_leaf(backend, n)
    local f = assert(compile(
        "local function leaf(x) return x*2+1 end; return leaf", {},
        { backend = backend }))
    local leaf = f()
    return best_of(5, function()
        local s = 0
        for i = 1, n do s = s + leaf(i) end
        return s
    end)
end

local function bench_loop(backend, n)
    local f = assert(compile(
        "local function f(n) local s=0; for i=1,n do s=s+i end; return s end; return f",
        {}, { backend = backend }))
    local fn = f()
    return best_of(5, function() return fn(n) end)
end

local tl, sl = bench_leaf("legacy", 3000000)
local tc, sc = bench_leaf("closure", 3000000)
print(string.format("leaf call        legacy %.4f s  closure %.4f s  ratio %.2fx  %s",
    tl, tc, tl / tc, sl == sc and "same" or "DIFF"))

local ll, ls = bench_loop("legacy", 1000000)
local lc, cs = bench_loop("closure", 1000000)
print(string.format("numeric for sum  legacy %.4f s  closure %.4f s  ratio %.2fx  %s",
    ll, lc, ll / lc, ls == cs and "same" or "DIFF"))
