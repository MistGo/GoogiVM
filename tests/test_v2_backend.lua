-- Focused tests for the opt-in block-threaded closure slice.
-- The public API still uses run_closure; this module exercises the chain
-- builder directly so the first backend slice does not affect stable behavior.
return function(t)
    local rt = dofile("gvm_runtime.lua")
    local build = dofile("gvm_compiler.lua")
    local compile = build(rt)

    local function pack(...)
        return { n = select("#", ...), ... }
    end

    local cases = {
        { "return x * 2", 21, { 42 } },
        { "return x * 2 + 3", 10, { 23 } },
        { "return (x + 1) * (x - 2)", 5, { 18 } },
        { "local y = x * 2; return y, y + 1", 5, { 10, 11 } },
        { "return x, x + 1, x + 2", 7, { 7, 8, 9 } },
        { "local a = x .. '!'; return a .. '?'", "ab", { "ab!?" } },
        { "return", 1, {} },
    }

    for i = 1, #cases do
        local body, arg, expected = cases[i][1], cases[i][2], cases[i][3]
        local f, err = compile(
            "local function leaf(x) " .. body .. " end; return leaf", {})
        t:check(f ~= nil, "compile closure case " .. i .. ": " .. tostring(err))
        if f then
            local leaf = f()
            local proto = rt.closure_info[leaf][1]
            local block, berr = rt.scan_block(proto)
            t:check(block ~= nil, "scan block " .. i .. ": " .. tostring(berr))
            if block then
                local entry, cerr = rt.build_block_chain(proto, block)
                t:check(entry ~= nil, "build chain " .. i .. ": " .. tostring(cerr))
                if entry then
                    local got = pack(pcall(
                        rt.run_block_chain, proto, entry, arg))
                    t:check(got[1], "chain run " .. i .. ": " .. tostring(got[2]))
                    if got[1] then
                        local want = pack(pcall(leaf, arg))
                        t:check(want[1], "native run " .. i)
                        t:check(got.n == want.n,
                            "return count " .. i)
                        for j = 1, #expected do
                            t:check(got[j + 1] == expected[j],
                                "value " .. i .. "[" .. j .. "]")
                        end
                    end
                end
            end
        end
    end

    -- Control flow is not part of this slice yet; the builder must fail
    -- cleanly so the caller can fall back to run_closure.
    local f = assert(compile(
        "local function leaf(x) if x then return 1 else return 2 end end; return leaf",
        {}))
    local leaf = f()
    local proto = rt.closure_info[leaf][1]
    local block = rt.scan_block(proto)
    local entry = block and rt.build_block_chain(proto, block)
    t:check(entry == nil, "branching block must not build a chain")

    -- Opt-in integration: a nested leaf must be built through make_closure
    -- and still return the right values when called from the legacy root.
    local f2, err2 = compile(
        "local function leaf(x) return x * 2 end; return leaf", {},
        { backend = "closure" })
    t:check(f2 ~= nil, "closure backend compile: " .. tostring(err2))
    if f2 then
        local leaf2 = f2()
        local p2 = rt.closure_info[leaf2][1]
        t:check(p2.backend == "closure", "prototype backend marker")
        t:check(leaf2(21) == 42, "closure backend call")
    end

    -- Unsupported control flow must fall back to the legacy body.
    local f3, err3 = compile(
        "local function leaf(x) if x then return 1 else return 2 end end;" ..
        " return leaf", {}, { backend = "closure" })
    t:check(f3 ~= nil, "fallback compile: " .. tostring(err3))
    if f3 then
        local leaf3 = f3()
        t:check(leaf3(true) == 1 and leaf3(false) == 2,
            "closure backend fallback")
    end

    local bad, berr = compile("return 1", {}, { backend = "nope" })
    t:check(bad == nil and tostring(berr):find("backend") ~= nil,
        "invalid backend option is rejected")
end
