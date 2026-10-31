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

    -- Control flow: branches, loops and the instruction budget.
    local control = {
        { "if-true",
          "local function f(x) if x then return 1 else return 2 end end; return f",
          true, 1 },
        { "if-false",
          "local function f(x) if x then return 1 else return 2 end end; return f",
          false, 2 },
        { "while",
          "local function f(x) local s=0; while s < x do s=s+1 end; return s end; return f",
          5, 5 },
        { "repeat",
          "local function f(x) local s=0; repeat s=s+1 until s>=x; return s end; return f",
          5, 5 },
        { "numeric-for",
          "local function f(x) local s=0; for i=1,x do s=s+i end; return s end; return f",
          5, 15 },
        { "for-if",
          "local function f(x) local s=0; for i=1,x do if i%2==0 then s=s+i end end; return s end; return f",
          5, 6 },
        { "and-or",
          "local function f(x) return x and 10 or 20 end; return f",
          false, 20 },
        { "nil-eq",
          "local function f(x) if x == nil then return 1 else return 2 end end; return f",
          nil, 1 },
        { "break",
          "local function f(x) local s=0; for i=1,x do if i==3 then break end; " ..
          "s=s+i end; return s end; return f", 5, 3 },
        { "negative-for",
          "local function f(x) local s=0; for i=x,1,-1 do s=s+i end; " ..
          "return s end; return f", 5, 15 },
    }

    for i = 1, #control do
        local name, src, arg, expected = control[i][1], control[i][2], control[i][3], control[i][4]
        local f, err = compile(src, {}, { backend = "closure" })
        t:check(f ~= nil, "control compile " .. name .. ": " .. tostring(err))
        if f then
            local fn = f()
            local proto = rt.closure_info[fn][1]
            local entry, perr = rt.build_program(proto)
            t:check(entry ~= nil, "control chain " .. name .. ": " .. tostring(perr))
            local ok, got = pcall(fn, arg)
            t:check(ok and got == expected,
                "control run " .. name .. ": " .. tostring(got))
        end
    end

    -- Calls: native targets, interpreted targets and multiple results.
    local call_src = "local function call(f,x) return f(x) end; return call"
    local callf, cerr = compile(call_src, { math = math }, { backend = "closure" })
    t:check(callf ~= nil, "call compile: " .. tostring(cerr))
    if callf then
        local call = callf()
        local cp = rt.closure_info[call][1]
        local ce, cee = rt.build_program(cp)
        t:check(ce ~= nil, "call chain: " .. tostring(cee))
        t:check(call(math.sqrt, 9) == 3, "call native target")
        local leaff = assert(compile(
            "local function leaf(x) return x * 2 end; return leaf", {},
            { backend = "closure" }))
        local leaf = leaff()
        t:check(call(leaf, 21) == 42, "call interpreted target")
        local function pair(x) return x, x + 1 end
        local got = pack(pcall(call, pair, 5))
        t:check(got[1] and got.n == 3 and got[2] == 5 and got[3] == 6,
            "call multiple returns")
    end

    local extra_src = "local function call(f,x) return f(x), 99 end; return call"
    local extraf, eerr = compile(extra_src, {}, { backend = "closure" })
    t:check(extraf ~= nil, "extra compile: " .. tostring(eerr))
    if extraf then
        local call = extraf()
        local function pair(x) return x, x + 1 end
        local got = pack(pcall(call, pair, 5))
        t:check(got[1] and got.n == 3 and got[2] == 5 and got[3] == 99,
            "call result adjustment")
    end

    -- Closures, cells and shared upvalues.
    local up_src = "local function make() local x=1; return function() x=x+1; return x end end; return make"
    local upf, uerr = compile(up_src, {}, { backend = "closure" })
    t:check(upf ~= nil, "upvalue compile: " .. tostring(uerr))
    if upf then
        local fn = upf()()
        local p = rt.closure_info[fn][1]
        local ce, cee = rt.build_program(p)
        t:check(ce ~= nil, "upvalue chain: " .. tostring(cee))
        t:check(fn() == 2 and fn() == 3, "shared upvalue mutation")
    end

    local shared_src = "local function make() local x=1; " ..
        "local function inc() x=x+1 end; local function get() return x end; " ..
        "inc(); inc(); return get end; return make"
    local sharedf, serr = compile(shared_src, {}, { backend = "closure" })
    t:check(sharedf ~= nil, "shared compile: " .. tostring(serr))
    if sharedf then
        local get = sharedf()()
        t:check(get() == 3, "shared cell between closures")
    end

    -- Table construction, indexed access and method calls.
    local table_src = "local function f(x) local t={a=1,[x]=2,3,4}; " ..
        "return t.a,t[x],t[1],t[2] end; return f"
    local tablef, terr = compile(table_src, {}, { backend = "closure" })
    t:check(tablef ~= nil, "table compile: " .. tostring(terr))
    if tablef then
        local f = tablef()
        local p = rt.closure_info[f][1]
        local ce, cee = rt.build_program(p)
        t:check(ce ~= nil, "table chain: " .. tostring(cee))
        local got = pack(f(5))
        t:check(got[1] == 1 and got[2] == 2 and got[3] == 3 and got[4] == 4,
            "table literal/index")
    end

    local self_src = "local function f(x) local t={x=x}; " ..
        "function t:get() return self.x end; return t:get() end; return f"
    local selff, serr2 = compile(self_src, {}, { backend = "closure" })
    t:check(selff ~= nil, "self compile: " .. tostring(serr2))
    if selff then
        t:check(selff()(7) == 7, "method SELF call")
    end

    local vararg_table_src = "local function pair() return 1,2 end; " ..
        "local function f() local t={pair()}; return t[1],t[2] end; return f"
    local vtf, vterr = compile(vararg_table_src, {}, { backend = "closure" })
    t:check(vtf ~= nil, "multi table compile: " .. tostring(vterr))
    if vtf then
        local got = pack(vtf()())
        t:check(got[1] == 1 and got[2] == 2, "table multi-return tail")
    end

    -- Globals and generic for.
    local genv = { x = 1 }
    local gf, gerr = compile(
        "local function f() x=x+1; return x end; return f",
        genv, { backend = "closure" })
    t:check(gf ~= nil, "global compile: " .. tostring(gerr))
    if gf then
        local f = gf()
        local p = rt.closure_info[f][1]
        local ce, cee = rt.build_program(p)
        t:check(ce ~= nil, "global chain: " .. tostring(cee))
        t:check(f() == 2 and genv.x == 2, "global read/write")
    end

    local mathf, merr = compile(
        "local function f() return math.sqrt(9) end; return f",
        { math = math }, { backend = "closure" })
    t:check(mathf ~= nil, "global field compile: " .. tostring(merr))
    if mathf then
        t:check(mathf()() == 3, "global field call")
    end

    local pairsf, perr = compile(
        "local function f(t) local s=0; for k,v in pairs(t) do s=s+v end; " ..
        "return s end; return f", { pairs = pairs }, { backend = "closure" })
    t:check(pairsf ~= nil, "pairs compile: " .. tostring(perr))
    if pairsf then
        local f = pairsf()
        local p = rt.closure_info[f][1]
        local ce, cee = rt.build_program(p)
        t:check(ce ~= nil, "pairs chain: " .. tostring(cee))
        t:check(f({ a = 1, b = 2, c = 3 }) == 6, "pairs sum")
    end

    local ipairsf, ierr = compile(
        "local function f(t) local s=0; for i,v in ipairs(t) do s=s+v end; " ..
        "return s end; return f", { ipairs = ipairs }, { backend = "closure" })
    t:check(ipairsf ~= nil, "ipairs compile: " .. tostring(ierr))
    if ipairsf then
        t:check(ipairsf()({ 1, 2, 3 }) == 6, "ipairs sum")
    end

    -- Varargs in returns, parameter adjustment and table tails.
    local vararg_src = "local function f(a,...) return a,... end; return f"
    local vf, verr = compile(vararg_src, {}, { backend = "closure" })
    t:check(vf ~= nil, "vararg compile: " .. tostring(verr))
    if vf then
        local f = vf()
        local p = rt.closure_info[f][1]
        t:check(p.isvararg, "vararg prototype marker")
        local got = pack(f(1, 2, 3))
        t:check(got.n == 3 and got[1] == 1 and got[2] == 2 and got[3] == 3,
            "vararg return expansion")
    end

    local vtable_src = "local function f(...) local t={...}; " ..
        "return t[1],t[2],t[3] end; return f"
    local vtf2, vterr2 = compile(vtable_src, {}, { backend = "closure" })
    t:check(vtf2 ~= nil, "vararg table compile: " .. tostring(vterr2))
    if vtf2 then
        local got = pack(vtf2()(4, 5, 6))
        t:check(got.n == 3 and got[1] == 4 and got[2] == 5 and got[3] == 6,
            "vararg table expansion")
    end

    local rootf, rerr = compile("return ...", {}, { backend = "closure" })
    t:check(rootf ~= nil, "vararg root compile: " .. tostring(rerr))
    if rootf then
        local got = pack(rootf(7, 8))
        t:check(got.n == 2 and got[1] == 7 and got[2] == 8,
            "vararg root return")
    end

    local arglim, aerr = compile(
        "local function f(...) return ... end; return f", {},
        { backend = "closure", maxArgs = 2 })
    t:check(arglim ~= nil, "args limit compile: " .. tostring(aerr))
    if arglim then
        local ok, err = pcall(arglim(), 1, 2, 3)
        t:check(not ok and tostring(err):find("too many arguments") ~= nil,
            "closure maxArgs")
    end

    local retlim, rerr = compile(
        "local function f() return 1,2,3 end; return f", {},
        { backend = "closure", maxReturns = 2 })
    t:check(retlim ~= nil, "returns limit compile: " .. tostring(rerr))
    if retlim then
        local ok, err = pcall(retlim())
        t:check(not ok and tostring(err):find("too many return values") ~= nil,
            "closure maxReturns")
    end

    local stacklim, sterr = compile(
        "local function f() local a,b,c,d=1,2,3,4; return a end; return f",
        {}, { backend = "closure", maxStack = 2 })
    t:check(stacklim ~= nil, "stack limit compile: " .. tostring(sterr))
    if stacklim then
        local ok, err = pcall(stacklim())
        t:check(not ok and tostring(err):find("stack limit") ~= nil,
            "closure maxStack")
    end

    -- Explicit frame suspension: tail calls, non-tail calls and depth limits.
    local tail_src = "local function f(n) if n==0 then return 0 end; " ..
        "return f(n-1) end; return f"
    local tailf, terr2 = compile(tail_src, {}, { backend = "closure" })
    t:check(tailf ~= nil, "tail frame compile: " .. tostring(terr2))
    if tailf then
        t:check(tailf()(100000) == 0, "tail frame reuse")
    end

    local rec_src = "local function f(n) if n==0 then return 0 end; " ..
        "return 1+f(n-1) end; return f"
    local recf, rerr2 = compile(rec_src, {}, { backend = "closure" })
    t:check(recf ~= nil, "non-tail frame compile: " .. tostring(rerr2))
    if recf then
        t:check(recf()(1000) == 1000, "non-tail frame stack")
    end

    local depthf, derr = compile(rec_src, {},
        { backend = "closure", maxCallDepth = 3 })
    t:check(depthf ~= nil, "depth compile: " .. tostring(derr))
    if depthf then
        local ok, err = pcall(depthf(), 10)
        t:check(not ok and tostring(err):find("call depth") ~= nil,
            "closure maxCallDepth")
    end

    -- Chain traceback: source location and no host module path.
    local tracef, trerr = compile(
        "local function f() return 1 + nil end; return f", {},
        { backend = "closure", sourceName = "trace.lua" })
    t:check(tracef ~= nil, "trace compile: " .. tostring(trerr))
    if tracef then
        local ok, err = pcall(tracef())
        t:check(not ok and tostring(err):find("trace.lua:") ~= nil and
            not tostring(err):find("gvm_runtime.lua") ,
            "closure traceback location")
    end

    -- Fresh loop cells and guest protected calls.
    local cell_src = "local function f() local fs={}; " ..
        "for i=1,3 do fs[i]=function() return i end end; " ..
        "return fs[1](),fs[2](),fs[3]() end; return f"
    local cellf, cerr2 = compile(cell_src, {}, { backend = "closure" })
    t:check(cellf ~= nil, "loop cell compile: " .. tostring(cerr2))
    if cellf then
        local got = pack(cellf()())
        t:check(got[1] == 1 and got[2] == 2 and got[3] == 3,
            "fresh loop cell per iteration")
    end

    local pcall_src = "local function bad() return 1+nil end; " ..
        "local function f() local ok,err=pcall(bad); " ..
        "return ok, tostring(err):find('arithmetic') ~= nil end; return f"
    local pcallf, pcerr = compile(pcall_src,
        { pcall = pcall, tostring = tostring }, { backend = "closure" })
    t:check(pcallf ~= nil, "pcall compile: " .. tostring(pcerr))
    if pcallf then
        local got = pack(pcallf()())
        t:check(got[1] == false and got[2] == true, "guest pcall formatting")
    end

    local xpcall_src = "local function bad() return 1+nil end; " ..
        "local function f() local ok,err=xpcall(bad,function(e) " ..
        "return 'handled' end); return ok,err end; return f"
    local xpf, xperr = compile(xpcall_src, { xpcall = xpcall },
        { backend = "closure" })
    t:check(xpf ~= nil, "xpcall compile: " .. tostring(xperr))
    if xpf then
        local got = pack(xpf()())
        t:check(got[1] == false and got[2] == "handled", "guest xpcall handler")
    end

    -- Host metamethod dispatch through chain closures.
    local meta_env = { setmetatable = setmetatable, tostring = tostring }
    local index_src = "local function f() local t=setmetatable({},{__index=" ..
        "function(_,k) return k..'!' end}); return t.x end; return f"
    local indexf, indexerr = compile(index_src, meta_env,
        { backend = "closure" })
    t:check(indexf ~= nil, "metaindex compile: " .. tostring(indexerr))
    if indexf then
        t:check(indexf()() == "x!", "metamethod __index")
    end

    local add_src = "local function f() local mt={__add=function(a,b) " ..
        "return a.n+b.n end}; local a=setmetatable({n=2},mt); " ..
        "return (a+a) end; return f"
    local addf, adderr = compile(add_src, meta_env,
        { backend = "closure" })
    t:check(addf ~= nil, "metaadd compile: " .. tostring(adderr))
    if addf then
        t:check(addf()() == 4, "metamethod __add")
    end

    local call_src = "local function f() local t=setmetatable({n=3}," ..
        "{__call=function(self,x) return self.n+x end}); return t(4) " ..
        "end; return f"
    local callmf, callerr = compile(call_src, meta_env,
        { backend = "closure" })
    t:check(callmf ~= nil, "metacall compile: " .. tostring(callerr))
    if callmf then
        t:check(callmf()() == 7, "metamethod __call")
    end

    -- Fused data opcodes in the chain backend.
    local fused_src = "local function f(x) local t={a=1,[x]=2}; " ..
        "return x*2+3,t.a,t[x] end; return f"
    local fusedf, ferr = compile(fused_src, {},
        { backend = "closure", fused = true })
    t:check(fusedf ~= nil, "fused compile: " .. tostring(ferr))
    if fusedf then
        local f = fusedf()
        local p = rt.closure_info[f][1]
        local ce, cee = rt.build_program(p)
        t:check(ce ~= nil, "fused chain: " .. tostring(cee))
        local got = pack(f(5))
        t:check(got[1] == 13 and got[2] == 1 and got[3] == 2,
            "fused arithmetic/table opcodes")
    end

    local fused_loop_src = "local function f(x) local t={}; local s=0; " ..
        "for i=1,x do t[i]=i; s=s+t[i] end; return s end; return f"
    local flf, flerr = compile(fused_loop_src, {},
        { backend = "closure", fused = true })
    t:check(flf ~= nil, "fused loop compile: " .. tostring(flerr))
    if flf then
        local f = flf()
        local p = rt.closure_info[f][1]
        local ce, cee = rt.build_program(p)
        t:check(ce ~= nil, "fused loop chain: " .. tostring(cee))
        t:check(f(5) == 15, "fused table/sum loop")
    end

    local badfused, bferr = compile("return 1", {}, { fused = "yes" })
    t:check(badfused == nil and tostring(bferr):find("fused") ~= nil,
        "invalid fused option is rejected")

    local lim, lerr = compile(
        "local function f(x) local s=0; for i=1,x do s=s+i end; " ..
        "return s end; return f", {}, { backend = "closure", maxInstructions = 20 })
    t:check(lim ~= nil, "limit compile: " .. tostring(lerr))
    if lim then
        local ok, err = pcall(lim(), 5)
        t:check(not ok and tostring(err):find("instruction limit") ~= nil,
            "closure instruction budget")
    end

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
