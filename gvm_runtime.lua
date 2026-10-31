--[[
  gvm_runtime.lua — GoogiVM execution runtime.

  Owns prototypes, closures, explicit VM frames, upvalues/cells, calls,
  operators, metamethod dispatch, limits and tracebacks.

  This module is pure Lua 5.1. It is loaded once by custom_loadstring_full.lua.
]]
--[[
  GoogiVM (custom_loadstring_full.lua)
  Pure-Lua Lua 5.1 compiler and bytecode interpreter.
  Does not use load, loadstring, FFI, debug, io, or os.

  API:
    local custom_loadstring = dofile("custom_loadstring_full.lua")
    local chunk, err = custom_loadstring(source, env, options)

  Supported:
    - while, repeat/until, numeric for, generic for
    - varargs (...), nested functions, closures/upvalues, tail calls
    - table constructors (nested, named/keyed/list fields)
    - multiple assignment and multiple returns
    - method calls/definitions, local function
    - all Lua 5.1 operators and host metamethod semantics
    - syntax and runtime errors with source-line mapping

  Lua 5.1 does not include bitwise operators; expose a library such as
  `bit` through `env` if needed.
]]

local str_find = string.find
local str_match = string.match
local str_sub = string.sub
local str_byte = string.byte
local str_char = string.char
local str_gsub = string.gsub
local tconcat = table.concat
local tostring = tostring
local tonumber = tonumber
local type = type
local error = error
local pcall = pcall
local select = select
local setmetatable = setmetatable
local getfenv = getfenv
local setfenv = setfenv
local getmetatable = getmetatable
local next = next
local ipairs = ipairs
local ipairs_iter = ipairs and select(1, ipairs({}))
local unpack = unpack or table.unpack

local function pack(...)
    return { n = select("#", ...), ... }
end

local closure_info = setmetatable({}, { __mode = "k" })

-- Default execution policy. All limits can be overridden per chunk through
-- the optional third argument to custom_loadstring.
local DEFAULT_LIMITS = {
    maxSourceBytes = 4 * 1024 * 1024,
    maxCodeSlots = 8 * 1024 * 1024,
    maxInstructions = 50 * 1000 * 1000,
    maxCallDepth = 10000,
    maxStack = 1000000,
    maxArgs = 1000,
    maxReturns = 1000,
}

-- Fused ("super") opcodes produced by the post-compile peephole pass.
-- All are >= 52; normal opcodes remain 1..51.
local FOP = {
    MOVLOCAL = 52,
    MOVLOCAL_NOP = 53,
    MOVLOCAL_CELL = 54,
    SETLOCAL_K = 55,
    SETLOCAL_INDEX = 56,
    SETLOCAL_FIELD = 57,

    ADD_RR = 58, ADD_RK = 59,
    SUB_RR = 60, SUB_RK = 61,
    MUL_RR = 62, MUL_RK = 63,
    DIV_RR = 64, DIV_RK = 65,
    MOD_RR = 66, MOD_RK = 67,
    POW_RR = 68, POW_RK = 69,

    EQ_RR = 70, EQ_RK = 71,
    NE_RR = 72, NE_RK = 73,
    LT_RR = 74, LT_RK = 75,
    LE_RR = 76, LE_RK = 77,
    GT_RR = 78, GT_RK = 79,
    GE_RR = 80, GE_RK = 81,

    EQ_K = 82, NE_K = 83, LT_K = 84, LE_K = 85, GT_K = 86, GE_K = 87,
    INDEX_RR = 88, INDEX_RK = 89, FIELD_R = 90,

    SETINDEX_RR = 91, SETINDEX_RK = 92,
    SETFIELD_RV = 93, SETFIELD_RK = 94,

    -- 95-101 were folded into ASSIGN_RR/RK/INDEX (154-156).

    JMPF_LOCAL = 102, JMPNIL_LOCAL = 103,

    -- 104-109 and 120-131 were folded into JMPF_CMP_* (151-153).

    FORLOOP_MOV = 110, FORLOOP_CELL = 111,
    FORLOOP_ADD_RR = 112, FORLOOP_ADD_RK = 113,
    FORLOOP_ADD_INDEX = 114,
    FORLOOP_SETINDEX_RR = 115, FORLOOP_SETINDEX_RK = 116,
    FORLOOP_SUB_RR = 117, FORLOOP_SUB_RK = 118,
    JMPF_MOD_EQ_K = 119,

    TFOR_2 = 132,
    TFOR_1 = 133,
    NEWTABLE_LOCAL = 134,
    SETLIST_R = 135,
    SETLIST_K = 136,
    SETLIST_ADD_RK = 137,
    NEWTABLE_FIELD_R = 138,
    NEWTABLE_FIELD_K = 139,
    NEWTABLE_SETINDEX_R = 140,
    NEWTABLE_LIST3_ADD_RK = 141,
    JMPF_MOD_RR_EQ_K = 142,
    ADD_ASSIGN_BINOP_RR = 143,
    SETLOCAL_BOOL = 144,
    FORLOOP_MOD_RR_EQ_K = 145,
    FORLOOP_NEWTABLE_SETINDEX_R = 146,

    TESTF_CMP_RR = 147, TESTF_CMP_RK = 148,
    TESTT_CMP_RR = 149, TESTT_CMP_RK = 150,
    JMPF_CMP_RR = 151, JMPF_CMP_RK = 152, JMPF_CMP_K = 153,

    -- Compound assignment collapsed to one opcode per shape; the arithmetic
    -- operator travels in the dead slot at C[pc + 4] as the base opcode
    -- number (ADD=13 .. CONCAT=19).
    ASSIGN_RR = 154, ASSIGN_RK = 155, ASSIGN_INDEX = 156,

    -- `a, b = b, a`
    SWAP = 157,

    -- `x = (x + y) % k`, e.g. s = (s + i) % 7
    ASSIGN_MOD_ADD_RK = 158,

    -- `t[x % k] = v`
    SETINDEX_MOD_RK = 159,

    -- `local cell = { v = x }; local f = function() ... end`
    CLOSURE_CELL = 160,

    -- `t[cell.v] = function() ... end` (closure over a boxed loop variable)
    SETINDEX_CLOSURE_CELL = 161,

    -- `for ... do s = s <op> operand end` for ops other than + and -.
    -- The arithmetic kind is stored in the dead slot C[body + 16].
    FORLOOP_ASSIGN_RR = 162, FORLOOP_ASSIGN_RK = 163,

    -- Left-to-right arithmetic chains: `k <op> a`, `<stack> <op> a`, `<stack> <op> k`.
    -- The arithmetic kind (13..19) is stored in the dead slot C[pc + 4].
    PUSH_OP_RK = 164, PUSH_OP_RS = 165, PUSH_OP_KS = 166,

    -- `dest = a <op> b` where the destination is not the left operand.
    -- The arithmetic kind (13..19) is stored in the dead slot C[pc + 4].
    ASSIGN_TO_RR = 167, ASSIGN_TO_RK = 168,

    JMPT_CMP_RR_LT = 169, JMPT_CMP_RR_LE = 170,
    JMPT_CMP_RR_GT = 171, JMPT_CMP_RR_GE = 172,
    JMPT_CMP_RR_EQ = 173, JMPT_CMP_RR_NE = 174,
    JMPT_CMP_RK_LT = 175, JMPT_CMP_RK_LE = 176,
    JMPT_CMP_RK_GT = 177, JMPT_CMP_RK_GE = 178,
    JMPT_CMP_RK_EQ = 179, JMPT_CMP_RK_NE = 180,

    CALL_U_RR2 = 181, CALL_U_RR1 = 182,
    CALL_R_RR2 = 183, CALL_R_RR1 = 184,

    -- `{v, v + k1, v + k2}` built directly into an existing local.
    NEWTABLE_LIST3_RK = 185,
    -- `t[i], t[j] = t[j], t[i]`.
    SWAP_INDEX = 186,

    ADD_RR_ADD_K = 187, MUL_DIV_K = 188,
    ADD_R_ADD_K = 189, DIV_RET = 190,
    -- `env.name.field` pushed as one value (for `math.sqrt`, `string.sub`, ...).
    GETGLOBAL_FIELD = 191,
    -- `PUSH_OP_RS` immediately followed by `ADD`.
    PUSH_OP_RS_ADD = 192,

    -- Generic form: operands are encoded as +reg or -upvalue.
    SETINDEX_MUL3 = 193,
    -- `t[k] = t[k] +/- a * t[k2]`; a is +reg/-upvalue, k2 is +reg/-const.
    SETINDEX_MUL2 = 194,
    -- Numeric for whose body is `t[i] = true` (sieve).
    FORLOOP_SETTRUE = 195,
    -- dest = k * a * b + c (mandelbrot inner loop).
    ASSIGN_MUL3_ADD = 196,

    -- `t[a + k]` and `dest = c + b * a` on the expression stack.
    INDEX_ADD_RK = 198, MUL_ADD_SETLOCAL = 199,
    -- Indexed comparison followed by JMPF: `t[k] <op> v` / `t[k] <op> k2`.
    INDEX_CMP_JMPF = 200,
    -- `dest = (a - b) + c` (mandelbrot's zr update).
    ASSIGN_SUB_ADD = 201,
    -- `(a + b) <op> k` followed by JMPF, and `t[a][b]`.
    ADD_JMPF_K = 202, INDEX_INDEX_RR = 203,
    -- `dest = c + b * a` immediately followed by the numeric-for back-edge.
    MUL_ADD_SETLOCAL_FORLOOP = 204,
    -- `v[j + k]` pushed immediately before a two-argument upvalue call.
    INDEX_ADD_RK_CALL_U_RR2 = 205,
    -- `acc = acc + v * (a / b)` at the end of a numeric for.
    DIV_MUL_ADD_SETLOCAL_FORLOOP = 206,
    -- `k / x` with the constant folded out of the inlined stack.
    DIV_K = 207,
    DIV_K_MUL_ADD_SETLOCAL_FORLOOP = 208,

}

local run_closure
local active_trace = nil

-- LuaJIT 2.1 can intermittently miscompile the base comparison path inside
-- the large VM function. Keeping comparisons in a tiny, non-JIT function is
-- cheap compared to making the entire interpreter non-JIT.
local function compare_op(op, a, b)
    if op == 23 then
        return a == b
    elseif op == 24 then
        return a ~= b
    elseif op == 25 then
        return a < b
    elseif op == 26 then
        return a <= b
    elseif op == 27 then
        return a > b
    else
        return a >= b
    end
end
if type(jit) == "table" and jit.off then
    jit.off(compare_op)
end

-- Ordered comparisons on two numbers are the overwhelmingly common case inside
-- hot loops. Doing them inline keeps those loops traceable by LuaJIT instead of
-- bouncing through the jit-disabled compare_op on every iteration. Anything
-- else (strings, metamethods) still goes through compare_op unchanged.
local function cmp_lt(a, b)
    if type(a) == "number" and type(b) == "number" then
        return a < b
    end
    return compare_op(25, a, b)
end

local function cmp_le(a, b)
    if type(a) == "number" and type(b) == "number" then
        return a <= b
    end
    return compare_op(26, a, b)
end

local function cmp_gt(a, b)
    if type(a) == "number" and type(b) == "number" then
        return a > b
    end
    return compare_op(27, a, b)
end

local function cmp_ge(a, b)
    if type(a) == "number" and type(b) == "number" then
        return a >= b
    end
    return compare_op(28, a, b)
end

-- Generic form used by the fused compare+test opcodes, which carry the
-- comparison opcode as a separate operand.
local function cmp_value(op, a, b)
    if op == 23 then
        return a == b
    elseif op == 24 then
        return a ~= b
    elseif op == 25 then
        return cmp_lt(a, b)
    elseif op == 26 then
        return cmp_le(a, b)
    elseif op == 27 then
        return cmp_gt(a, b)
    else
        return cmp_ge(a, b)
    end
end

-- Messages already carrying a sandbox location are prefixed with this byte so
-- nested handlers do not re-prefix them. It is stripped at every boundary the
-- guest or the host can observe.
local LOCATION_MARK = "\1"

local function sandbox_message(err)
    if type(err) ~= "string" then
        return err
    end
    if str_sub(err, 1, 1) == LOCATION_MARK then
        return str_sub(err, 2)
    end
    -- Drop a host location prefix ("file.lua:12: " or "C:\...\vm.lua:12: ")
    -- without inventing a sandbox location.
    local body = str_match(err, "^.-:%d+: ([^\n]*)")
    return body or err
end

local last_native_fn = nil
local native_name_cache = setmetatable({}, { __mode = "k" })

local function native_name_of(fn, env)
    if type(fn) ~= "function" or type(env) ~= "table" then
        return nil
    end
    local name = native_name_cache[fn]
    if name then
        return name
    end
    for k, v in pairs(env) do
        if v == fn then
            if type(k) == "string" then
                name = k
                break
            end
        elseif type(v) == "table" then
            for k2, v2 in pairs(v) do
                if v2 == fn and type(k2) == "string" then
                    name = k2
                    break
                end
            end
            if name then
                break
            end
        end
    end
    if name then
        native_name_cache[fn] = name
    end
    return name
end

local function append_trace(out, trace)
    local frames = trace.frames
    local fi = trace.fi
    if not frames or not fi then
        return out
    end

    local function frame_line(fr)
        local fl = fr.line
        if not fl then
            local fpc = fr.pc or 1
            fl = fr.p.lines and fr.p.lines[fpc]
        end
        return fl
    end

    local function inline_site(fp, pc)
        local sites = fp.inline_sites
        if sites and pc then
            for i = #sites, 1, -1 do
                local site = sites[i]
                if pc >= site.start and pc <= site.finish then
                    return site
                end
            end
        end
        return nil
    end

    out = out .. "\nstack traceback:"

    -- `error` is a native function, so the native LuaJIT shape starts with
    -- a C frame.  Other runtime errors start at the innermost Lua frame.
    if last_native_fn == error then
        out = out .. "\n\t[C]: in function 'error'"
    end

    for i = fi, 1, -1 do
        local fr = frames[i]
        if fr then
            local fl
            if i == fi and trace[1] then
                fl = fr.p.lines and fr.p.lines[trace[1]]
            end
            fl = fl or frame_line(fr)
            if fl then
                local fp = fr.p
                local src = fp.sourceName or "<string>"
                local site
                if i == fi and trace[1] then
                    site = inline_site(fp, trace[1])
                end
                if site then
                    local inline_name = site.name
                    if inline_name then
                        out = out .. "\n\t" .. src .. ":" .. fl ..
                            ": in function '" .. inline_name .. "'"
                    else
                        out = out .. "\n\t" .. src .. ":" .. fl ..
                            ": in function <" .. src .. ":" .. fl .. ">"
                    end
                    fl = site.call_line or fl
                end
                local label
                if i == 1 and not fr.not_main then
                    label = "in main chunk"
                elseif fp.name then
                    label = "in function '" .. fp.name .. "'"
                else
                    label = "in function <" .. src .. ":" .. fl .. ">"
                end
                out = out .. "\n\t" .. src .. ":" .. fl .. ": " .. label
            end
        end
    end
    return out
end

local function format_runtime_error(err, trace, with_trace)
    if type(err) ~= "string" then
        return err
    end
    if str_sub(err, 1, 1) == LOCATION_MARK then
        local out = str_sub(err, 2)
        if with_trace and trace and trace.cur then
            local head = str_match(out, "^([^\n]*):%d+: ")
            out = append_trace(out, trace, head)
        end
        return out
    end
    if not trace or not trace.cur then
        return err
    end
    local p = trace.cur.p
    local pc = trace[1] or 1
    local line = p.lines and p.lines[pc]
    if not line then
        return err
    end

    -- Host errors start with "file.lua:NN: " (possibly a Windows path such as
    -- "C:\mods\vm.lua:1771: ..."). Replace that with the interpreted source
    -- location so host paths never leak into the sandbox.
    local msg = str_match(err, "^.-:%d+: ([^\n]*)") or err

    -- Host argument errors name the dispatcher local `f` (or `?` when the
    -- function was called through pcall); restore the real name if known.
    if last_native_fn and
       (str_find(msg, "to 'f'", 1, true) or str_find(msg, "to '?'", 1, true)) then
        local name = native_name_of(last_native_fn, trace.cur.env)
        if name then
            msg = str_gsub(msg, "to 'f'", "to '" .. name .. "'", 1)
            msg = str_gsub(msg, "to '%?'", "to '" .. name .. "'", 1)
        end
    end

    local out = (p.sourceName or "<string>") .. ":" .. line .. ": " .. msg

    if with_trace ~= false then
        out = append_trace(out, trace, (p.sourceName or "<string>") .. ":" .. line)
    end
    return out
end

local function sandbox_error(err, trace, with_trace)
    local formatted = format_runtime_error(err, trace, with_trace)
    if formatted ~= err then
        return formatted
    end
    return sandbox_message(err)
end

-- Forward declarations: defined after get_closure_env/set_closure_env below.
local sandbox_getfenv, sandbox_setfenv

-- Kept outside run_closure so the dispatch loop stays small enough for the
-- LuaJIT trace compiler.
local function protected_call(is_xpcall, target, handler, tr, outer_trace,
                              S, fpos, top, caller_env, frames, fi)
    local target_info = closure_info[target]
    local te = target_info and tr or outer_trace
    local rs

    -- getfenv/setfenv must never reach the host implementation: the host would
    -- happily return a native function's environment, which is the host _G.
    local guarded, new_e
    if getfenv and target == getfenv then
        guarded = function(a)
            return sandbox_getfenv(a, caller_env, frames, fi)
        end
    elseif setfenv and target == setfenv then
        guarded = function(a, b)
            local r
            r, new_e = sandbox_setfenv(a, b, frames, fi)
            return r
        end
    end
    if guarded then
        -- pcall(target, ...) stores args from fpos+2; xpcall(target, handler, ...)
        -- shifts them by the handler slot.
        local first = is_xpcall and (fpos + 3) or (fpos + 2)
        local nargs = top - first + 1
        if is_xpcall then
            local function finish(err)
                local msg = sandbox_error(err, te, false)
                if handler == nil then
                    return msg
                end
                if closure_info[handler] then
                    return run_closure(handler, {}, msg)
                end
                return handler(msg)
            end
            if nargs < 1 then
                rs = pack(xpcall(guarded, finish))
            elseif nargs == 1 then
                rs = pack(xpcall(guarded, finish, S[first]))
            else
                rs = pack(xpcall(guarded, finish, S[first], S[first + 1]))
            end
        else
            if nargs < 1 then
                rs = pack(pcall(guarded))
            elseif nargs == 1 then
                rs = pack(pcall(guarded, S[first]))
            else
                rs = pack(pcall(guarded, S[first], S[first + 1]))
            end
            if not rs[1] then
                rs[2] = sandbox_error(rs[2], te, false)
            end
        end
        rs.new_e = new_e
        return rs
    end

    if not is_xpcall then
        if target_info then
            rs = pack(pcall(run_closure, target, tr, unpack(S, fpos + 2, top)))
        else
            last_native_fn = target
            rs = pack(pcall(target, unpack(S, fpos + 2, top)))
        end
        if not rs[1] then
            rs[2] = sandbox_error(rs[2], te, false)
        end
        return rs
    end

    local args = { n = 0 }
    local n = 0
    for j = fpos + 3, top do
        n = n + 1
        args[n] = S[j]
    end
    args.n = n

    local function finish(err)
        local msg = sandbox_error(err, te, false)
        if handler == nil then
            return msg
        end
        if closure_info[handler] then
            return run_closure(handler, {}, msg)
        end
        return handler(msg)
    end

    if target_info then
        rs = pack(xpcall(function()
            return run_closure(target, tr, unpack(args, 1, n))
        end, finish))
    else
        last_native_fn = target
        rs = pack(xpcall(function()
            return target(unpack(args, 1, n))
        end, finish))
    end
    return rs
end

-- Filled in after the legacy interpreter; make_closure consults it only when
-- a prototype explicitly opts into the v2 closure backend.
local closure_backend = {}
local chain_map = setmetatable({}, { __mode = "k" })

local function make_closure(proto, upvals, fenv, set_native_env)
    local info
    local chain
    if proto.backend == "closure" and closure_backend.build_program then
        chain = closure_backend.build_program(proto)
    end
    local function closure(...)
        if chain then
            return closure_backend.run_chain(proto, chain, info, ...)
        end
        if info[4] then
            return run_closure(closure, nil, ...)
        end
        local trace = {}
        local result = pack(pcall(run_closure, closure, trace, ...))
        if result[1] then
            return unpack(result, 2, result.n)
        end
        error(sandbox_error(result[2], trace, true), 0)
    end
    local env = fenv or proto.env
    local native_env = false
    -- Only the root chunk needs a native Lua fenv for host getfenv/setfenv.
    -- Nested closures resolve getfenv/setfenv through closure_info instead.
    if set_native_env and setfenv then
        native_env = pcall(setfenv, closure, env)
    end
    info = upvals
    info[1] = proto
    info[2] = env
    info[3] = native_env
    info[4] = not set_native_env
    closure_info[closure] = info
    if chain then
        chain_map[closure] = chain
    end
    return closure
end

local function get_closure_env(fn)
    local info = closure_info[fn]
    if not info then
        return nil
    end
    if info[3] and getfenv then
        return getfenv(fn)
    end
    return info[2]
end

local function set_closure_env(fn, newenv)
    local info = closure_info[fn]
    if not info then
        return false
    end
    info[2] = newenv
    if info[3] and setfenv then
        info[3] = pcall(setfenv, fn, newenv)
    end
    return true
end

-- Sandbox-safe getfenv/setfenv. Both the CALLD special case and guest
-- pcall/xpcall route through these, so a native function environment (the
-- host _G) can never be reached from interpreted code.
sandbox_getfenv = function(arg, caller_env, frames, fi)
    if arg == nil then
        arg = 1
    end
    if type(arg) == "number" then
        if arg == 0 then
            return caller_env
        end
        if arg < 0 then
            error("bad argument #1 to 'getfenv' (invalid level)", 0)
        end
        local idx = fi - arg + 1
        if idx < 1 then
            error("bad argument #1 to 'getfenv' (invalid level)", 0)
        end
        return frames[idx].env
    elseif type(arg) == "function" then
        if closure_info[arg] then
            return get_closure_env(arg)
        end
        error("getfenv: native function environments are disabled", 0)
    end
    error("bad argument #1 to 'getfenv' (number or function expected)", 0)
end

sandbox_setfenv = function(target, newenv, frames, fi)
    if type(newenv) ~= "table" then
        error("bad argument #2 to 'setfenv' (table expected)", 0)
    end
    if type(target) == "number" then
        if target <= 0 then
            error("cannot change environment of thread", 0)
        end
        local idx = fi - target + 1
        if idx < 1 then
            error("invalid level", 0)
        end
        local fr = frames[idx]
        set_closure_env(fr.cl, newenv)
        local new_e
        for j = 1, fi do
            if frames[j].cl == fr.cl then
                frames[j].env = newenv
                if j == fi then
                    new_e = newenv
                end
            end
        end
        return fr.cl, new_e
    elseif type(target) == "function" then
        if closure_info[target] then
            set_closure_env(target, newenv)
            local new_e
            for j = 1, fi do
                if frames[j].cl == target then
                    frames[j].env = newenv
                    if j == fi then
                        new_e = newenv
                    end
                end
            end
            return target, new_e
        end
        error("setfenv: native function environments are disabled", 0)
    end
    error("bad argument #1 to 'setfenv' (number or function expected)", 0)
end

-- The `F_*` opcode aliases are resolved to numeric literals by retree2.lua
-- when the dispatch tree is generated. They are intentionally not written to
-- `_G`: the linear source is an input to the generator, not a runtime module.

run_closure = function(fn, trace, ...)
    trace = trace or {}
    active_trace = trace
    local CELL, NOP = 8, 50

    local info = closure_info[fn]
    local p = info[1]
    local limits = info[1].limits or {}
    local maxInstructions = limits.maxInstructions
    local instructionBudget = maxInstructions
    if instructionBudget == math.huge then instructionBudget = nil end
    local args = pack(...)
    local nargs = args.n
    if limits.maxArgs and nargs > limits.maxArgs then
        error("too many arguments", 0)
    end

    local S = {}
    local top = 0
    local frames = {}
    local fi = 1
    local free_frames = {}
    local free_frame_count = 0

    local base = 1
    local maxreg = p.maxreg
    local va = nil

    if p.isvararg then
        local nv = nargs - p.numparams
        if nv > 0 then
            va = { n = nv }
            for i = 1, nv do
                va[i] = args[p.numparams + i]
            end
        end
    end

    for i = 1, p.numparams do
        S[i] = args[i]
    end
    for i = p.numparams + 1, maxreg do
        S[i] = nil
    end
    top = maxreg
    if limits.maxStack and top > limits.maxStack then
        error("stack limit exceeded", 0)
    end

    local cenv = info[2]
    if info[3] and getfenv then
        cenv = getfenv(fn)
    end

    local cur = {
        p = p, ups = info, base = base, pc = 1,
        ret_sp = 0, wanted = -1, va = va, env = cenv, cl = fn,
        line = nil,
    }
    frames[1] = cur
    trace.p = p
    trace.cur = cur
    trace.frames = frames
    trace.fi = fi
    trace[1] = 1

    local C = p.code
    local K = p.consts
    local U = info
    local e = cenv
    local pc = p.entry or 1
    local has_jit = type(jit) == "table" and (jit.status == nil or jit.status() == true)

    while true do
        if instructionBudget then
            instructionBudget = instructionBudget - 1
            if instructionBudget == 0 then
                error("instruction limit exceeded", 0)
            end
        end

        trace[1] = pc
        local op = C[pc]

        if op >= 52 then
            -- Fast-path ordering for the hottest fused opcodes.

            -- Balanced dispatch tree (generated): ~5 compares instead of ~90.
            if op < 140 then
                if op < 83 then
                    if op < 67 then
                        if op < 59 then
                            if op < 55 then
                                if op == 52 then
                                    S[base + C[pc + 1] - 1] = S[base + C[pc + 2] - 1]
                                    pc = pc + 8
                                elseif op == 53 then
                                    S[base + C[pc + 1] - 1] = S[base + C[pc + 2] - 1]
                                    pc = pc + 12
                                elseif op == 54 then
                                    S[base + C[pc + 1] - 1] =
                                        { v = S[base + C[pc + 2] - 1] }
                                    pc = pc + 12
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op == 55 then
                                    S[base + C[pc + 1] - 1] = K[C[pc + 2]]
                                    pc = pc + 8
                                elseif op == 56 then
                                    local dest = base + C[pc + 1] - 1
                                    local t = S[base + C[pc + 2] - 1]
                                    local k = S[base + C[pc + 3] - 1]
                                    S[dest] = t[k]
                                    pc = pc + 16
                                elseif op == 57 then
                                    local dest = base + C[pc + 1] - 1
                                    local t = S[base + C[pc + 2] - 1]
                                    S[dest] = t[K[C[pc + 3]]]
                                    pc = pc + 12
                                elseif op == 58 then
                                    top = top + 1
                                    S[top] = S[base + C[pc + 1] - 1] + S[base + C[pc + 2] - 1]
                                    pc = pc + 12
                                else
                                    error("bad fused bytecode", 0)
                                end
                            end
                        else
                            if op < 62 then
                                if op == 59 then
                                    top = top + 1
                                    S[top] = S[base + C[pc + 1] - 1] + K[C[pc + 2]]
                                    pc = pc + 12
                                elseif op == 60 then
                                    top = top + 1
                                    S[top] = S[base + C[pc + 1] - 1] - S[base + C[pc + 2] - 1]
                                    pc = pc + 12
                                elseif op == 61 then
                                    top = top + 1
                                    S[top] = S[base + C[pc + 1] - 1] - K[C[pc + 2]]
                                    pc = pc + 12
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op < 64 then
                                    if op == 62 then
                                        top = top + 1
                                        S[top] = S[base + C[pc + 1] - 1] * S[base + C[pc + 2] - 1]
                                        pc = pc + 12
                                    elseif op == 63 then
                                        top = top + 1
                                        S[top] = S[base + C[pc + 1] - 1] * K[C[pc + 2]]
                                        pc = pc + 12
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                else
                                    if op == 64 then
                                        top = top + 1
                                        S[top] = S[base + C[pc + 1] - 1] / S[base + C[pc + 2] - 1]
                                        pc = pc + 12
                                    elseif op == 65 then
                                        top = top + 1
                                        S[top] = S[base + C[pc + 1] - 1] / K[C[pc + 2]]
                                        pc = pc + 12
                                    elseif op == 66 then
                                        top = top + 1
                                        S[top] = S[base + C[pc + 1] - 1] % S[base + C[pc + 2] - 1]
                                        pc = pc + 12
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                end
                            end
                        end
                    else
                        if op < 74 then
                            if op < 70 then
                                if op == 67 then
                                    top = top + 1
                                    S[top] = S[base + C[pc + 1] - 1] % K[C[pc + 2]]
                                    pc = pc + 12
                                elseif op == 68 then
                                    top = top + 1
                                    S[top] = S[base + C[pc + 1] - 1] ^ S[base + C[pc + 2] - 1]
                                    pc = pc + 12
                                elseif op == 69 then
                                    top = top + 1
                                    S[top] = S[base + C[pc + 1] - 1] ^ K[C[pc + 2]]
                                    pc = pc + 12
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op == 70 then
                                    top = top + 1
                                    S[top] = (S[base + C[pc + 1] - 1] == S[base + C[pc + 2] - 1])
                                    pc = pc + 12
                                elseif op == 71 then
                                    top = top + 1
                                    S[top] = (S[base + C[pc + 1] - 1] == K[C[pc + 2]])
                                    pc = pc + 12
                                elseif op == 72 then
                                    top = top + 1
                                    S[top] = (S[base + C[pc + 1] - 1] ~= S[base + C[pc + 2] - 1])
                                    pc = pc + 12
                                elseif op == 73 then
                                    top = top + 1
                                    S[top] = (S[base + C[pc + 1] - 1] ~= K[C[pc + 2]])
                                    pc = pc + 12
                                else
                                    error("bad fused bytecode", 0)
                                end
                            end
                        else
                            if op < 78 then
                                if op == 74 then
                                    top = top + 1
                                    S[top] = (S[base + C[pc + 1] - 1] < S[base + C[pc + 2] - 1])
                                    pc = pc + 12
                                elseif op == 75 then
                                    top = top + 1
                                    S[top] = (S[base + C[pc + 1] - 1] < K[C[pc + 2]])
                                    pc = pc + 12
                                elseif op == 76 then
                                    top = top + 1
                                    S[top] = (S[base + C[pc + 1] - 1] <= S[base + C[pc + 2] - 1])
                                    pc = pc + 12
                                elseif op == 77 then
                                    top = top + 1
                                    S[top] = (S[base + C[pc + 1] - 1] <= K[C[pc + 2]])
                                    pc = pc + 12
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op < 80 then
                                    if op == 78 then
                                        top = top + 1
                                        S[top] = (S[base + C[pc + 1] - 1] > S[base + C[pc + 2] - 1])
                                        pc = pc + 12
                                    elseif op == 79 then
                                        top = top + 1
                                        S[top] = (S[base + C[pc + 1] - 1] > K[C[pc + 2]])
                                        pc = pc + 12
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                else
                                    if op == 80 then
                                        top = top + 1
                                        S[top] = (S[base + C[pc + 1] - 1] >= S[base + C[pc + 2] - 1])
                                        pc = pc + 12
                                    elseif op == 81 then
                                        top = top + 1
                                        S[top] = (S[base + C[pc + 1] - 1] >= K[C[pc + 2]])
                                        pc = pc + 12
                                    elseif op == 82 then
                                        S[top] = (S[top] == K[C[pc + 1]])
                                        pc = pc + 8
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                end
                            end
                        end
                    end
                else
                    if op < 111 then
                        if op < 90 then
                            if op < 86 then
                                if op == 83 then
                                    S[top] = (S[top] ~= K[C[pc + 1]])
                                    pc = pc + 8
                                elseif op == 84 then
                                    S[top] = (S[top] < K[C[pc + 1]])
                                    pc = pc + 8
                                elseif op == 85 then
                                    S[top] = (S[top] <= K[C[pc + 1]])
                                    pc = pc + 8
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op == 86 then
                                    S[top] = (S[top] > K[C[pc + 1]])
                                    pc = pc + 8
                                elseif op == 87 then
                                    S[top] = (S[top] >= K[C[pc + 1]])
                                    pc = pc + 8
                                elseif op == 88 then
                                    local t = S[base + C[pc + 1] - 1]
                                    local k = S[base + C[pc + 2] - 1]
                                    top = top + 1
                                    S[top] = t[k]
                                    pc = pc + 12
                                elseif op == 89 then
                                    local t = S[base + C[pc + 1] - 1]
                                    top = top + 1
                                    S[top] = t[K[C[pc + 2]]]
                                    pc = pc + 12
                                else
                                    error("bad fused bytecode", 0)
                                end
                            end
                        else
                            if op < 93 then
                                if op == 90 then
                                    local t = S[base + C[pc + 1] - 1]
                                    top = top + 1
                                    S[top] = t[K[C[pc + 2]]]
                                    pc = pc + 8
                                elseif op == 91 then
                                    local t = S[base + C[pc + 1] - 1]
                                    local k = S[base + C[pc + 2] - 1]
                                    t[k] = S[base + C[pc + 3] - 1]
                                    pc = pc + 24
                                elseif op == 92 then
                                    local t = S[base + C[pc + 1] - 1]
                                    local k = S[base + C[pc + 2] - 1]
                                    t[k] = K[C[pc + 3]]
                                    pc = pc + 24
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op < 102 then
                                    if op == 93 then
                                        local t = S[base + C[pc + 1] - 1]
                                        t[K[C[pc + 2]]] = S[base + C[pc + 3] - 1]
                                        pc = pc + 16
                                    elseif op == 94 then
                                        local t = S[base + C[pc + 1] - 1]
                                        t[K[C[pc + 2]]] = K[C[pc + 3]]
                                        pc = pc + 16
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                else
                                    if op == 102 then
                                        if not S[base + C[pc + 1] - 1] then
                                            pc = C[pc + 2]
                                        else
                                            pc = pc + 8
                                        end
                                    elseif op == 103 then
                                        if S[base + C[pc + 1] - 1] == nil then
                                            pc = C[pc + 2]
                                        else
                                            pc = pc + 8
                                        end
                                    elseif op == 110 then
                                        local r = base + C[pc + 1] - 1
                                        local step = S[r + 2]
                                        local limit = S[r + 1]
                                        local idx = S[r] + step
                                        if (step > 0 and idx <= limit) or
                                           (step < 0 and idx >= limit) then
                                            S[r] = idx
                                            S[base + C[pc + 2] - 1] = idx
                                            pc = C[pc + 3]
                                        else
                                            pc = pc + 4
                                        end
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                end
                            end
                        end
                    else
                        if op < 119 then
                            if op < 114 then
                                if op == 111 then
                                    local r = base + C[pc + 1] - 1
                                    local step = S[r + 2]
                                    local limit = S[r + 1]
                                    local idx = S[r] + step
                                    if (step > 0 and idx <= limit) or
                                       (step < 0 and idx >= limit) then
                                        S[r] = idx
                                        S[base + C[pc + 2] - 1] = { v = idx }
                                        pc = C[pc + 3]
                                    else
                                        pc = pc + 4
                                    end
                                elseif op == 112 then
                                    local r = base + C[pc + 1] - 1
                                    local step = S[r + 2]
                                    local limit = S[r + 1]
                                    local idx = S[r] + step
                                    if (step > 0 and idx <= limit) or
                                       (step < 0 and idx >= limit) then
                                        S[r] = idx
                                        S[base + C[pc + 2] - 1] = idx
                                        local body = C[pc + 3]
                                        trace[1] = body + 12
                                        local a = base + C[body + 13] - 1
                                        local b = base + C[body + 14] - 1
                                        S[a] = S[a] + S[b]
                                        local nxt = body + 28
                                        if nxt ~= pc then pc = nxt end
                                    else
                                        pc = pc + 4
                                    end
                                elseif op == 113 then
                                    local r = base + C[pc + 1] - 1
                                    local step = S[r + 2]
                                    local limit = S[r + 1]
                                    local idx = S[r] + step
                                    if (step > 0 and idx <= limit) or
                                       (step < 0 and idx >= limit) then
                                        S[r] = idx
                                        S[base + C[pc + 2] - 1] = idx
                                        local body = C[pc + 3]
                                        trace[1] = body + 12
                                        local a = base + C[body + 13] - 1
                                        S[a] = S[a] + K[C[body + 14]]
                                        local nxt = body + 28
                                        if nxt ~= pc then pc = nxt end
                                    else
                                        pc = pc + 4
                                    end
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op < 116 then
                                    if op == 114 then
                                        local r = base + C[pc + 1] - 1
                                        local step = S[r + 2]
                                        local limit = S[r + 1]
                                        local idx = S[r] + step
                                        if (step > 0 and idx <= limit) or
                                           (step < 0 and idx >= limit) then
                                            S[r] = idx
                                            S[base + C[pc + 2] - 1] = idx
                                            local body = C[pc + 3]
                                            trace[1] = body + 12
                                            local a = base + C[body + 13] - 1
                                            local t = S[base + C[body + 14] - 1]
                                            local k = S[base + C[body + 15] - 1]
                                            S[a] = S[a] + t[k]
                                            local nxt = body + 36
                                            if nxt ~= pc then pc = nxt end
                                        else
                                            pc = pc + 4
                                        end
                                    elseif op == 115 then
                                        local r = base + C[pc + 1] - 1
                                        local step = S[r + 2]
                                        local limit = S[r + 1]
                                        local idx = S[r] + step
                                        if (step > 0 and idx <= limit) or
                                           (step < 0 and idx >= limit) then
                                            S[r] = idx
                                            S[base + C[pc + 2] - 1] = idx
                                            local body = C[pc + 3]
                                            trace[1] = body + 12
                                            local t = S[base + C[body + 13] - 1]
                                            local k = S[base + C[body + 14] - 1]
                                            t[k] = S[base + C[body + 15] - 1]
                                            local nxt = body + 36
                                            if nxt ~= pc then pc = nxt end
                                        else
                                            pc = pc + 4
                                        end
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                else
                                    if op == 116 then
                                        local r = base + C[pc + 1] - 1
                                        local step = S[r + 2]
                                        local limit = S[r + 1]
                                        local idx = S[r] + step
                                        if (step > 0 and idx <= limit) or
                                           (step < 0 and idx >= limit) then
                                            S[r] = idx
                                            S[base + C[pc + 2] - 1] = idx
                                            local body = C[pc + 3]
                                            trace[1] = body + 12
                                            local t = S[base + C[body + 13] - 1]
                                            local k = S[base + C[body + 14] - 1]
                                            t[k] = K[C[body + 15]]
                                            local nxt = body + 36
                                            if nxt ~= pc then pc = nxt end
                                        else
                                            pc = pc + 4
                                        end
                                    elseif op == 117 then
                                        local r = base + C[pc + 1] - 1
                                        local step = S[r + 2]
                                        local limit = S[r + 1]
                                        local idx = S[r] + step
                                        if (step > 0 and idx <= limit) or
                                           (step < 0 and idx >= limit) then
                                            S[r] = idx
                                            S[base + C[pc + 2] - 1] = idx
                                            local body = C[pc + 3]
                                            trace[1] = body + 12
                                            local a = base + C[body + 13] - 1
                                            local b = base + C[body + 14] - 1
                                            S[a] = S[a] - S[b]
                                            local nxt = body + 28
                                            if nxt ~= pc then pc = nxt end
                                        else
                                            pc = pc + 4
                                        end
                                    elseif op == 118 then
                                        local r = base + C[pc + 1] - 1
                                        local step = S[r + 2]
                                        local limit = S[r + 1]
                                        local idx = S[r] + step
                                        if (step > 0 and idx <= limit) or
                                           (step < 0 and idx >= limit) then
                                            S[r] = idx
                                            S[base + C[pc + 2] - 1] = idx
                                            local body = C[pc + 3]
                                            trace[1] = body + 12
                                            local a = base + C[body + 13] - 1
                                            S[a] = S[a] - K[C[body + 14]]
                                            local nxt = body + 28
                                            if nxt ~= pc then pc = nxt end
                                        else
                                            pc = pc + 4
                                        end
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                end
                            end
                        else
                            if op < 135 then
                                if op == 119 then
                                    local v = S[base + C[pc + 1] - 1] % K[C[pc + 2]]
                                    if v == K[C[pc + 3]] then
                                        pc = pc + 24
                                    else
                                        pc = C[pc + 14]
                                    end
                                elseif op == 132 then
                                    local r = base + C[pc + 1] - 1
                                    local f = S[r]
                                    if f == ipairs_iter then
                                        local idx = S[r + 2] + 1
                                        local val = S[r + 1][idx]
                                        if val ~= nil then
                                            S[r + 2] = idx
                                            if C[pc + 2] == 0 then
                                                S[r + 3] = idx
                                                S[r + 4] = val
                                            else
                                                S[r + 3] = C[pc + 36] == CELL and { v = idx } or idx
                                                S[r + 4] = C[pc + 28] == CELL and { v = val } or val
                                            end
                                            pc = pc + 56
                                        else
                                            pc = C[pc + 53]
                                        end
                                    elseif f == next then
                                        local k, val = next(S[r + 1], S[r + 2])
                                        if k ~= nil then
                                            S[r + 2] = k
                                            if C[pc + 2] == 0 then
                                                S[r + 3] = k
                                                S[r + 4] = val
                                            else
                                                S[r + 3] = C[pc + 36] == CELL and { v = k } or k
                                                S[r + 4] = C[pc + 28] == CELL and { v = val } or val
                                            end
                                            pc = pc + 56
                                        else
                                            pc = C[pc + 53]
                                        end
                                    elseif not closure_info[f] and f ~= getfenv and f ~= setfenv then
                                        local k, val = f(S[r + 1], S[r + 2])
                                        if k ~= nil then
                                            S[r + 2] = k
                                            if C[pc + 2] == 0 then
                                                S[r + 3] = k
                                                S[r + 4] = val
                                            else
                                                S[r + 3] = C[pc + 36] == CELL and { v = k } or k
                                                S[r + 4] = C[pc + 28] == CELL and { v = val } or val
                                            end
                                            pc = pc + 56
                                        else
                                            pc = C[pc + 53]
                                        end
                                    else
                                        top = top + 1
                                        S[top] = f
                                        pc = pc + 4
                                    end
                                elseif op == 133 then
                                    local r = base + C[pc + 1] - 1
                                    local f = S[r]
                                    if f == ipairs_iter then
                                        local idx = S[r + 2] + 1
                                        local val = S[r + 1][idx]
                                        if val ~= nil then
                                            S[r + 2] = idx
                                            if C[pc + 2] == 0 then
                                                S[r + 3] = idx
                                            else
                                                S[r + 3] = { v = idx }
                                            end
                                            pc = pc + 48
                                        else
                                            pc = C[pc + 45]
                                        end
                                    elseif f == next then
                                        local k = next(S[r + 1], S[r + 2])
                                        if k ~= nil then
                                            S[r + 2] = k
                                            if C[pc + 2] == 0 then
                                                S[r + 3] = k
                                            else
                                                S[r + 3] = { v = k }
                                            end
                                            pc = pc + 48
                                        else
                                            pc = C[pc + 45]
                                        end
                                    elseif not closure_info[f] and f ~= getfenv and f ~= setfenv then
                                        local k = f(S[r + 1], S[r + 2])
                                        if k ~= nil then
                                            S[r + 2] = k
                                            if C[pc + 2] == 0 then
                                                S[r + 3] = k
                                            else
                                                S[r + 3] = { v = k }
                                            end
                                            pc = pc + 48
                                        else
                                            pc = C[pc + 45]
                                        end
                                    else
                                        top = top + 1
                                        S[top] = f
                                        pc = pc + 4
                                    end
                                elseif op == 134 then
                                    S[base + C[pc + 1] - 1] = {}
                                    pc = pc + 8
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op < 137 then
                                    if op == 135 then
                                        local t = S[base + C[pc + 1] - 1]
                                        t[C[pc + 2]] = S[base + C[pc + 3] - 1]
                                        pc = pc + 12
                                    elseif op == 136 then
                                        local t = S[base + C[pc + 1] - 1]
                                        t[C[pc + 2]] = K[C[pc + 3]]
                                        pc = pc + 12
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                else
                                    if op == 137 then
                                        local t = S[base + C[pc + 1] - 1]
                                        t[C[pc + 2]] = S[base + C[pc + 3] - 1] + K[C[pc + 9]]
                                        pc = pc + 20
                                    elseif op == 138 then
                                        local t = { [K[C[pc + 1]]] = S[base + C[pc + 2] - 1] }
                                        if C[pc + 3] > 0 then
                                            S[base + C[pc + 3] - 1] = t
                                            pc = pc + 24
                                        else
                                            top = top + 1
                                            S[top] = t
                                            pc = pc + 20
                                        end
                                    elseif op == 139 then
                                        local t = { [K[C[pc + 1]]] = K[C[pc + 2]] }
                                        if C[pc + 3] > 0 then
                                            S[base + C[pc + 3] - 1] = t
                                            pc = pc + 24
                                        else
                                            top = top + 1
                                            S[top] = t
                                            pc = pc + 20
                                        end
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                end
                            end
                        end
                    end
                end
            else
                if op < 171 then
                    if op < 155 then
                        if op < 147 then
                            if op < 143 then
                                if op == 140 then
                                    local t = S[base + C[pc + 1] - 1]
                                    local k = S[base + C[pc + 2] - 1]
                                    t[k] = { [K[C[pc + 25]]] = S[base + C[pc + 3] - 1] }
                                    pc = pc + 40
                                elseif op == 141 then
                                    local v = S[base + C[pc + 2] - 1]
                                    local t = {
                                        v,
                                        v + K[C[pc + 29]],
                                        v + K[C[pc + 49]],
                                    }
                                    local c = C[pc + 3]
                                    if c > 0 then
                                        local sreg = base + c - 1
                                        S[sreg] = S[sreg] + t[K[C[pc + 77]]]
                                        pc = pc + 96
                                    else
                                        S[base + C[pc + 1] - 1] = t
                                        pc = pc + 72
                                    end
                                elseif op == 142 then
                                    local v = S[base + C[pc + 1] - 1] % S[base + C[pc + 2] - 1]
                                    if v == K[C[pc + 3]] then
                                        pc = pc + 24
                                    else
                                        pc = C[pc + 14]
                                    end
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op == 143 then
                                    local dest = base + C[pc + 1] - 1
                                    local a = S[base + C[pc + 2] - 1]
                                    local b = S[base + C[pc + 3] - 1]
                                    local bop = C[pc + 12]
                                    if bop == 13 then
                                        if type(a) == "number" and type(b) == "number" then
                                            S[dest] = S[dest] + (a + b)
                                            pc = pc + 24
                                        elseif getmetatable then
                                            local mt = (type(a) == "table" and getmetatable(a)) or
                                                       (type(b) == "table" and getmetatable(b))
                                            local mm = type(mt) == "table" and mt.__add
                                            local mci = mm and closure_info[mm]
                                            if mci and not mci[1].isvararg then
                                                local cp = mci[1]
                                                if limits.maxCallDepth and fi >= limits.maxCallDepth then
                                                    error("call depth limit exceeded", 0)
                                                end
                                                top = top + 1
                                                S[top] = S[dest]
                                                local fpos = top + 1
                                                S[fpos] = a
                                                S[fpos + 1] = b
                                                local cmax = cp.maxreg
                                                for j = 3, cmax do
                                                    S[fpos + j - 1] = nil
                                                end
                                                cur.pc = pc + 16
                                                cur.line = p.lines and p.lines[pc]
                                                frames[fi] = cur
                                                local nfree = free_frame_count
                                                local frame
                                                if nfree > 0 then
                                                    frame = free_frames[nfree]
                                                    free_frames[nfree] = nil
                                                    free_frame_count = nfree - 1
                                                else
                                                    frame = {}
                                                end
                                                frame.p = cp
                                                frame.ups = mci
                                                frame.base = fpos
                                                frame.pc = 1
                                                frame.ret_sp = top
                                                frame.wanted = 1
                                                frame.va = nil
                                                frame.env = mci[2]
                                                frame.cl = mm
                                                frame.line = nil
                                                cur = frame
                                                fi = fi + 1
                                                frames[fi] = cur
                                                trace.cur = cur
                                                trace.fi = fi
                                                p = cp
                                                C = cp.code
                                                K = cp.consts
                                                U = mci
                                                e = mci[2]
                                                base = fpos
                                                maxreg = cmax
                                                va = nil
                                                pc = cp.entry or 1
                                                top = fpos + cmax - 1
                                            else
                                                S[dest] = S[dest] + (a + b)
                                                pc = pc + 24
                                            end
                                        else
                                            S[dest] = S[dest] + (a + b)
                                            pc = pc + 24
                                        end
                                    elseif bop == 14 then
                                        S[dest] = S[dest] + (a - b)
                                        pc = pc + 24
                                    else
                                        S[dest] = S[dest] + (a * b)
                                        pc = pc + 24
                                    end
                                elseif op == 144 then
                                    S[base + C[pc + 1] - 1] = (C[pc + 2] == 1)
                                    pc = pc + 8
                                elseif op == 145 then
                                    local r = base + C[pc + 1] - 1
                                    local step = S[r + 2]
                                    local limit = S[r + 1]
                                    local idx = S[r] + step
                                    if (step > 0 and idx <= limit) or
                                       (step < 0 and idx >= limit) then
                                        S[r] = idx
                                        S[base + C[pc + 2] - 1] = idx
                                        local body = C[pc + 3]
                                        trace[1] = body + 12
                                        local v = S[base + C[body + 13] - 1] % S[base + C[body + 14] - 1]
                                        if v == K[C[body + 15]] then
                                            pc = body + 36
                                        else
                                            local nxt = C[body + 26]
                                            if nxt ~= pc then pc = nxt end
                                        end
                                    else
                                        pc = pc + 4
                                    end
                                elseif op == 146 then
                                    local r = base + C[pc + 1] - 1
                                    local step = S[r + 2]
                                    local limit = S[r + 1]
                                    local idx = S[r] + step
                                    if (step > 0 and idx <= limit) or
                                       (step < 0 and idx >= limit) then
                                        S[r] = idx
                                        S[base + C[pc + 2] - 1] = idx
                                        local body = C[pc + 3]
                                        trace[1] = body + 12
                                        local t = S[base + C[body + 13] - 1]
                                        local k = S[base + C[body + 14] - 1]
                                        t[k] = { [K[C[body + 37]]] = S[base + C[body + 15] - 1] }
                                        local nxt = body + 52
                                        if nxt ~= pc then pc = nxt end
                                    else
                                        pc = pc + 4
                                    end
                                else
                                    error("bad fused bytecode", 0)
                                end
                            end
                        else
                            if op < 150 then
                                if op == 147 then
                                    local cop = C[pc + 4]
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = S[base + C[pc + 2] - 1]
                                    local v
                                    if cop == 25 then v = cmp_lt(a, b)
                                    elseif cop == 26 then v = cmp_le(a, b)
                                    elseif cop == 27 then v = cmp_gt(a, b)
                                    elseif cop == 28 then v = cmp_ge(a, b)
                                    elseif cop == 23 then v = a == b
                                    else v = a ~= b end
                                    if v then
                                        pc = pc + 16
                                    else
                                        top = top + 1
                                        S[top] = v
                                        pc = C[pc + 3]
                                    end
                                elseif op == 148 then
                                    local cop = C[pc + 4]
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = K[C[pc + 2]]
                                    local v
                                    if cop == 25 then v = cmp_lt(a, b)
                                    elseif cop == 26 then v = cmp_le(a, b)
                                    elseif cop == 27 then v = cmp_gt(a, b)
                                    elseif cop == 28 then v = cmp_ge(a, b)
                                    elseif cop == 23 then v = a == b
                                    else v = a ~= b end
                                    if v then
                                        pc = pc + 16
                                    else
                                        top = top + 1
                                        S[top] = v
                                        pc = C[pc + 3]
                                    end
                                elseif op == 149 then
                                    local cop = C[pc + 4]
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = S[base + C[pc + 2] - 1]
                                    local v
                                    if cop == 25 then v = cmp_lt(a, b)
                                    elseif cop == 26 then v = cmp_le(a, b)
                                    elseif cop == 27 then v = cmp_gt(a, b)
                                    elseif cop == 28 then v = cmp_ge(a, b)
                                    elseif cop == 23 then v = a == b
                                    else v = a ~= b end
                                    if v then
                                        top = top + 1
                                        S[top] = v
                                        pc = C[pc + 3]
                                    else
                                        pc = pc + 16
                                    end
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op < 152 then
                                    if op == 150 then
                                        local cop = C[pc + 4]
                                        local a = S[base + C[pc + 1] - 1]
                                        local b = K[C[pc + 2]]
                                        local v
                                        if cop == 25 then v = cmp_lt(a, b)
                                        elseif cop == 26 then v = cmp_le(a, b)
                                        elseif cop == 27 then v = cmp_gt(a, b)
                                        elseif cop == 28 then v = cmp_ge(a, b)
                                        elseif cop == 23 then v = a == b
                                        else v = a ~= b end
                                        if v then
                                            top = top + 1
                                            S[top] = v
                                            pc = C[pc + 3]
                                        else
                                            pc = pc + 16
                                        end
                                    elseif op == 151 then
                                        local cop = C[pc + 4]
                                        local a = S[base + C[pc + 1] - 1]
                                        local b = S[base + C[pc + 2] - 1]
                                        local v
                                        if cop == 25 then v = cmp_lt(a, b)
                                        elseif cop == 26 then v = cmp_le(a, b)
                                        elseif cop == 27 then v = cmp_gt(a, b)
                                        elseif cop == 28 then v = cmp_ge(a, b)
                                        elseif cop == 23 then v = a == b
                                        else v = a ~= b end
                                        if not v then
                                            pc = C[pc + 3]
                                        else
                                            pc = pc + 16
                                        end
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                else
                                    if op == 152 then
                                        local cop = C[pc + 4]
                                        local a = S[base + C[pc + 1] - 1]
                                        local b = K[C[pc + 2]]
                                        local v
                                        if cop == 25 then v = cmp_lt(a, b)
                                        elseif cop == 26 then v = cmp_le(a, b)
                                        elseif cop == 27 then v = cmp_gt(a, b)
                                        elseif cop == 28 then v = cmp_ge(a, b)
                                        elseif cop == 23 then v = a == b
                                        else v = a ~= b end
                                        if not v then
                                            pc = C[pc + 3]
                                        else
                                            pc = pc + 16
                                        end
                                    elseif op == 153 then
                                        local cop = C[pc + 4]
                                        local a = S[top]
                                        S[top] = nil
                                        top = top - 1
                                        local b = K[C[pc + 1]]
                                        local v
                                        if cop == 25 then v = cmp_lt(a, b)
                                        elseif cop == 26 then v = cmp_le(a, b)
                                        elseif cop == 27 then v = cmp_gt(a, b)
                                        elseif cop == 28 then v = cmp_ge(a, b)
                                        elseif cop == 23 then v = a == b
                                        else v = a ~= b end
                                        if not v then
                                            pc = C[pc + 2]
                                        else
                                            pc = pc + 12
                                        end
                                    elseif op == 154 then
                                        local a = base + C[pc + 1] - 1
                                        local b = S[base + C[pc + 2] - 1]
                                        local v = S[a]
                                        local k = C[pc + 4]
                                        if k == 13 then v = v + b
                                        elseif k == 14 then v = v - b
                                        elseif k == 15 then v = v * b
                                        elseif k == 16 then v = v / b
                                        elseif k == 17 then v = v % b
                                        elseif k == 18 then v = v ^ b
                                        else v = v .. b end
                                        S[a] = v
                                        pc = pc + 16
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                end
                            end
                        end
                    else
                        if op < 162 then
                            if op < 158 then
                                if op == 155 then
                                    local a = base + C[pc + 1] - 1
                                    local b = K[C[pc + 2]]
                                    local v = S[a]
                                    local k = C[pc + 4]
                                    if k == 13 then v = v + b
                                    elseif k == 14 then v = v - b
                                    elseif k == 15 then v = v * b
                                    elseif k == 16 then v = v / b
                                    elseif k == 17 then v = v % b
                                    elseif k == 18 then v = v ^ b
                                    else v = v .. b end
                                    S[a] = v
                                    pc = pc + 16
                                elseif op == 156 then
                                    local a = base + C[pc + 1] - 1
                                    local b = S[base + C[pc + 2] - 1][S[base + C[pc + 3] - 1]]
                                    local v = S[a]
                                    local k = C[pc + 4]
                                    if k == 13 then v = v + b
                                    elseif k == 14 then v = v - b
                                    elseif k == 15 then v = v * b
                                    elseif k == 16 then v = v / b
                                    elseif k == 17 then v = v % b
                                    elseif k == 18 then v = v ^ b
                                    else v = v .. b end
                                    S[a] = v
                                    pc = pc + 24
                                elseif op == 157 then
                                    local a = base + C[pc + 1] - 1
                                    local b = base + C[pc + 2] - 1
                                    local t = S[a]
                                    S[a] = S[b]
                                    S[b] = t
                                    pc = pc + 16
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op == 158 then
                                    local a = base + C[pc + 1] - 1
                                    local b = base + C[pc + 2] - 1
                                    S[a] = (S[a] + S[b]) % K[C[pc + 3]]
                                    pc = pc + 24
                                elseif op == 159 then
                                    local t = S[base + C[pc + 1] - 1]
                                    local k = S[base + C[pc + 2] - 1] % K[C[pc + 3]]
                                    t[k] = S[base + C[pc + 4] - 1]
                                    pc = pc + 32
                                elseif op == 160 then
                                    local cellreg = base + C[pc + 1] - 1
                                    local cp = p.protos[C[pc + 4]]
                                    local ud = cp.updesc
                                    local nup = #ud
                                    local cell
                                    local d1 = ud[1]
                                    local merged = nup == 1 and d1.instack == 1 and
                                                   base + d1.idx - 1 == cellreg
                                    if merged then
                                        cell = { v = S[base + C[pc + 2] - 1], cp, e, false, true }
                                        cell[5] = cell
                                    else
                                        cell = { v = S[base + C[pc + 2] - 1] }
                                    end
                                    S[cellreg] = cell
                                    local ups
                                    if merged then
                                        ups = cell
                                    else
                                        ups = { cp, e, false, true }
                                        for j = 1, nup do
                                            local d = ud[j]
                                            if d.instack == 1 then
                                                ups[j + 4] = S[base + d.idx - 1]
                                            else
                                                ups[j + 4] = U[d.idx + 4]
                                            end
                                        end
                                    end
                                    S[base + C[pc + 3] - 1] = make_closure(cp, ups, e, false)
                                    pc = pc + 20
                                elseif op == 161 then
                                    local cellreg = base + C[pc + 1] - 1
                                    local cp = p.protos[C[pc + 4]]
                                    local ud = cp.updesc
                                    local nup = #ud
                                    local cell
                                    local d1 = ud[1]
                                    local merged = nup == 1 and d1.instack == 1 and
                                                   base + d1.idx - 1 == cellreg
                                    if merged then
                                        -- The whole closure captures nothing but this very cell, so
                                        -- the closure record can double as the cell: one table
                                        -- instead of two, and the upvalue slot points back at it.
                                        cell = { v = S[base + C[pc + 2] - 1], cp, e, false, true }
                                        cell[5] = cell
                                    else
                                        cell = { v = S[base + C[pc + 2] - 1] }
                                    end
                                    S[cellreg] = cell
                                    local ups
                                    if merged then
                                        ups = cell
                                    else
                                        ups = { cp, e, false, true }
                                        for j = 1, nup do
                                            local d = ud[j]
                                            if d.instack == 1 then
                                                ups[j + 4] = S[base + d.idx - 1]
                                            else
                                                ups[j + 4] = U[d.idx + 4]
                                            end
                                        end
                                    end
                                    local t = S[base + C[pc + 3] - 1]
                                    t[cell.v] = make_closure(cp, ups, e, false)
                                    pc = pc + 36
                                else
                                    error("bad fused bytecode", 0)
                                end
                            end
                        else
                            if op < 166 then
                                if op == 162 then
                                    local r = base + C[pc + 1] - 1
                                    local step = S[r + 2]
                                    local limit = S[r + 1]
                                    local idx = S[r] + step
                                    if (step > 0 and idx <= limit) or
                                       (step < 0 and idx >= limit) then
                                        S[r] = idx
                                        S[base + C[pc + 2] - 1] = idx
                                        local body = C[pc + 3]
                                        trace[1] = body + 12
                                        local a = base + C[body + 13] - 1
                                        local b = base + C[body + 14] - 1
                                        local kind = C[body + 16]
                                        if kind == 15 then
                                            S[a] = S[a] * S[b]
                                        elseif kind == 16 then
                                            S[a] = S[a] / S[b]
                                        elseif kind == 17 then
                                            S[a] = S[a] % S[b]
                                        elseif kind == 18 then
                                            S[a] = S[a] ^ S[b]
                                        else
                                            S[a] = S[a] .. S[b]
                                        end
                                        local nxt = body + 28
                                        if nxt ~= pc then pc = nxt end
                                    else
                                        pc = pc + 4
                                    end
                                elseif op == 163 then
                                    local r = base + C[pc + 1] - 1
                                    local step = S[r + 2]
                                    local limit = S[r + 1]
                                    local idx = S[r] + step
                                    if (step > 0 and idx <= limit) or
                                       (step < 0 and idx >= limit) then
                                        S[r] = idx
                                        S[base + C[pc + 2] - 1] = idx
                                        local body = C[pc + 3]
                                        trace[1] = body + 12
                                        local a = base + C[body + 13] - 1
                                        local kind = C[body + 16]
                                        if kind == 15 then
                                            S[a] = S[a] * K[C[body + 14]]
                                        elseif kind == 16 then
                                            S[a] = S[a] / K[C[body + 14]]
                                        elseif kind == 17 then
                                            S[a] = S[a] % K[C[body + 14]]
                                        elseif kind == 18 then
                                            S[a] = S[a] ^ K[C[body + 14]]
                                        else
                                            S[a] = S[a] .. K[C[body + 14]]
                                        end
                                        local nxt = body + 28
                                        if nxt ~= pc then pc = nxt end
                                    else
                                        pc = pc + 4
                                    end
                                elseif op == 164 then
                                    local kind = C[pc + 4]
                                    local x = K[C[pc + 1]]
                                    local y = S[base + C[pc + 2] - 1]
                                    top = top + 1
                                    if kind == 13 then S[top] = x + y                elseif kind == 14 then S[top] = x - y
                                    elseif kind == 15 then S[top] = x * y
                                    elseif kind == 16 then S[top] = x / y
                                    elseif kind == 17 then S[top] = x % y
                                    elseif kind == 18 then S[top] = x ^ y
                                    else S[top] = x .. y end
                                    pc = pc + 12
                                elseif op == 165 then
                                    local kind = C[pc + 4]
                                    local x = S[top]
                                    local y = S[base + C[pc + 1] - 1]
                                    if kind == 13 then S[top] = x + y                elseif kind == 14 then S[top] = x - y
                                    elseif kind == 15 then S[top] = x * y
                                    elseif kind == 16 then S[top] = x / y
                                    elseif kind == 17 then S[top] = x % y
                                    elseif kind == 18 then S[top] = x ^ y
                                    else S[top] = x .. y end
                                    pc = pc + 8
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op < 168 then
                                    if op == 166 then
                                        local kind = C[pc + 4]
                                        local x = S[top]
                                        local y = K[C[pc + 1]]
                                        if kind == 13 then S[top] = x + y                elseif kind == 14 then S[top] = x - y
                                        elseif kind == 15 then S[top] = x * y
                                        elseif kind == 16 then S[top] = x / y
                                        elseif kind == 17 then S[top] = x % y
                                        elseif kind == 18 then S[top] = x ^ y
                                        else S[top] = x .. y end
                                        pc = pc + 8
                                    elseif op == 167 then
                                        local kind = C[pc + 4]
                                        local x = S[base + C[pc + 2] - 1]
                                        local y = S[base + C[pc + 3] - 1]
                                        local d = base + C[pc + 1] - 1
                                        if kind == 13 then S[d] = x + y
                                        elseif kind == 14 then S[d] = x - y
                                        elseif kind == 15 then S[d] = x * y
                                        elseif kind == 16 then S[d] = x / y
                                        elseif kind == 17 then S[d] = x % y
                                        elseif kind == 18 then S[d] = x ^ y
                                        else S[d] = x .. y end
                                        pc = pc + 16
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                else
                                    if op == 168 then
                                        local kind = C[pc + 4]
                                        local x = S[base + C[pc + 2] - 1]
                                        local y = K[C[pc + 3]]
                                        local d = base + C[pc + 1] - 1
                                        if kind == 13 then S[d] = x + y
                                        elseif kind == 14 then S[d] = x - y
                                        elseif kind == 15 then S[d] = x * y
                                        elseif kind == 16 then S[d] = x / y
                                        elseif kind == 17 then S[d] = x % y
                                        elseif kind == 18 then S[d] = x ^ y
                                        else S[d] = x .. y end
                                        pc = pc + 16
                                    elseif op == 169 then
                                        local a = S[base + C[pc + 1] - 1]
                                        local b = S[base + C[pc + 2] - 1]
                                        if cmp_lt(a, b) then pc = C[pc + 3] else pc = pc + 4 end
                                    elseif op == 170 then
                                        local a = S[base + C[pc + 1] - 1]
                                        local b = S[base + C[pc + 2] - 1]
                                        if cmp_le(a, b) then pc = C[pc + 3] else pc = pc + 4 end
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                end
                            end
                        end
                    end
                else
                    if op < 189 then
                        if op < 178 then
                            if op < 174 then
                                if op == 171 then
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = S[base + C[pc + 2] - 1]
                                    if cmp_gt(a, b) then pc = C[pc + 3] else pc = pc + 4 end
                                elseif op == 172 then
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = S[base + C[pc + 2] - 1]
                                    if cmp_ge(a, b) then pc = C[pc + 3] else pc = pc + 4 end
                                elseif op == 173 then
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = S[base + C[pc + 2] - 1]
                                    if a == b then pc = C[pc + 3] else pc = pc + 4 end
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op == 174 then
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = S[base + C[pc + 2] - 1]
                                    if a ~= b then pc = C[pc + 3] else pc = pc + 4 end
                                elseif op == 175 then
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = K[C[pc + 2]]
                                    if cmp_lt(a, b) then pc = C[pc + 3] else pc = pc + 4 end
                                elseif op == 176 then
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = K[C[pc + 2]]
                                    if cmp_le(a, b) then pc = C[pc + 3] else pc = pc + 4 end
                                elseif op == 177 then
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = K[C[pc + 2]]
                                    if cmp_gt(a, b) then pc = C[pc + 3] else pc = pc + 4 end
                                else
                                    error("bad fused bytecode", 0)
                                end
                            end
                        else
                            if op < 182 then
                                if op == 178 then
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = K[C[pc + 2]]
                                    if cmp_ge(a, b) then pc = C[pc + 3] else pc = pc + 4 end
                                elseif op == 179 then
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = K[C[pc + 2]]
                                    if a == b then pc = C[pc + 3] else pc = pc + 4 end
                                elseif op == 180 then
                                    local a = S[base + C[pc + 1] - 1]
                                    local b = K[C[pc + 2]]
                                    if a ~= b then pc = C[pc + 3] else pc = pc + 4 end
                                elseif op == 181 then
                                    local u = C[pc + 1]
                                    local f = U[u + 4].v
                                    local a = S[base + C[pc + 2] - 1]
                                    local b = S[base + C[pc + 3] - 1]
                                    local nres = C[pc + 4]
                                    local fci = closure_info[f]
                                    if fci and not fci[1].isvararg then
                                        local cp = fci[1]
                                        local fpos = top + 1
                                        S[fpos] = a
                                        S[fpos + 1] = b
                                        local cmax = cp.maxreg
                                        for j = 3, cmax do S[fpos + j - 1] = nil end
                                        cur.pc = pc + 20
                                        cur.line = p.lines and p.lines[pc]
                                        frames[fi] = cur
                                        local nfree = free_frame_count
                                        local frame
                                        if nfree > 0 then
                                            frame = free_frames[nfree]
                                            free_frames[nfree] = nil
                                            free_frame_count = nfree - 1
                                        else
                                            frame = {}
                                        end
                                        frame.p = cp
                                        frame.ups = fci
                                        frame.base = fpos
                                        frame.pc = 1
                                        frame.ret_sp = top
                                        frame.wanted = nres
                                        frame.va = nil
                                        frame.env = fci[2]
                                        frame.cl = f
                                        frame.line = nil
                                        cur = frame
                                        fi = fi + 1
                                        frames[fi] = cur
                                        trace.cur = cur
                                        trace.fi = fi
                                        p = cp
                                        C = cp.code
                                        K = cp.consts
                                        U = fci
                                        e = fci[2]
                                        base = fpos
                                        maxreg = cmax
                                        va = nil
                                        pc = cp.entry or 1
                                        top = fpos + cmax - 1
                                    else
                                        local r = f(a, b)
                                        if nres == 1 then top = top + 1; S[top] = r end
                                        pc = pc + 20
                                    end
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op < 184 then
                                    if op == 182 then
                                        local u = C[pc + 1]
                                        local f = U[u + 4].v
                                        local a = S[base + C[pc + 2] - 1]
                                        local nres = C[pc + 4]
                                        local fci = closure_info[f]
                                        if fci and not fci[1].isvararg then
                                            local cp = fci[1]
                                            local fpos = top + 1
                                            S[fpos] = a
                                            local cmax = cp.maxreg
                                            for j = 2, cmax do S[fpos + j - 1] = nil end
                                            cur.pc = pc + 16
                                            cur.line = p.lines and p.lines[pc]
                                            frames[fi] = cur
                                            local nfree = free_frame_count
                                            local frame
                                            if nfree > 0 then
                                                frame = free_frames[nfree]
                                                free_frames[nfree] = nil
                                                free_frame_count = nfree - 1
                                            else
                                                frame = {}
                                            end
                                            frame.p = cp
                                            frame.ups = fci
                                            frame.base = fpos
                                            frame.pc = 1
                                            frame.ret_sp = top
                                            frame.wanted = nres
                                            frame.va = nil
                                            frame.env = fci[2]
                                            frame.cl = f
                                            frame.line = nil
                                            cur = frame
                                            fi = fi + 1
                                            frames[fi] = cur
                                            trace.cur = cur
                                            trace.fi = fi
                                            p = cp
                                            C = cp.code
                                            K = cp.consts
                                            U = fci
                                            e = fci[2]
                                            base = fpos
                                            maxreg = cmax
                                            va = nil
                                            pc = cp.entry or 1
                                            top = fpos + cmax - 1
                                        else
                                            local r = f(a)
                                            if nres == 1 then top = top + 1; S[top] = r end
                                            pc = pc + 16
                                        end
                                    elseif op == 183 then
                                        local f = S[base + C[pc + 1] - 1]
                                        local a = S[base + C[pc + 2] - 1]
                                        local b = S[base + C[pc + 3] - 1]
                                        local nres = C[pc + 4]
                                        local fci = closure_info[f]
                                        if fci and not fci[1].isvararg then
                                            local cp = fci[1]
                                            local fpos = top + 1
                                            S[fpos] = a
                                            S[fpos + 1] = b
                                            local cmax = cp.maxreg
                                            for j = 3, cmax do S[fpos + j - 1] = nil end
                                            cur.pc = pc + 20
                                            cur.line = p.lines and p.lines[pc]
                                            frames[fi] = cur
                                            local nfree = free_frame_count
                                            local frame
                                            if nfree > 0 then
                                                frame = free_frames[nfree]
                                                free_frames[nfree] = nil
                                                free_frame_count = nfree - 1
                                            else
                                                frame = {}
                                            end
                                            frame.p = cp
                                            frame.ups = fci
                                            frame.base = fpos
                                            frame.pc = 1
                                            frame.ret_sp = top
                                            frame.wanted = nres
                                            frame.va = nil
                                            frame.env = fci[2]
                                            frame.cl = f
                                            frame.line = nil
                                            cur = frame
                                            fi = fi + 1
                                            frames[fi] = cur
                                            trace.cur = cur
                                            trace.fi = fi
                                            p = cp
                                            C = cp.code
                                            K = cp.consts
                                            U = fci
                                            e = fci[2]
                                            base = fpos
                                            maxreg = cmax
                                            va = nil
                                            pc = cp.entry or 1
                                            top = fpos + cmax - 1
                                        else
                                            local r = f(a, b)
                                            if nres == 1 then top = top + 1; S[top] = r end
                                            pc = pc + 20
                                        end
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                else
                                    if op == 184 then
                                        local f = S[base + C[pc + 1] - 1]
                                        local a = S[base + C[pc + 2] - 1]
                                        local nres = C[pc + 4]
                                        local fci = closure_info[f]
                                        if fci and not fci[1].isvararg then
                                            local cp = fci[1]
                                            local fpos = top + 1
                                            S[fpos] = a
                                            local cmax = cp.maxreg
                                            for j = 2, cmax do S[fpos + j - 1] = nil end
                                            cur.pc = pc + 16
                                            cur.line = p.lines and p.lines[pc]
                                            frames[fi] = cur
                                            local nfree = free_frame_count
                                            local frame
                                            if nfree > 0 then
                                                frame = free_frames[nfree]
                                                free_frames[nfree] = nil
                                                free_frame_count = nfree - 1
                                            else
                                                frame = {}
                                            end
                                            frame.p = cp
                                            frame.ups = fci
                                            frame.base = fpos
                                            frame.pc = 1
                                            frame.ret_sp = top
                                            frame.wanted = nres
                                            frame.va = nil
                                            frame.env = fci[2]
                                            frame.cl = f
                                            frame.line = nil
                                            cur = frame
                                            fi = fi + 1
                                            frames[fi] = cur
                                            trace.cur = cur
                                            trace.fi = fi
                                            p = cp
                                            C = cp.code
                                            K = cp.consts
                                            U = fci
                                            e = fci[2]
                                            base = fpos
                                            maxreg = cmax
                                            va = nil
                                            pc = cp.entry or 1
                                            top = fpos + cmax - 1
                                        else
                                            local r = f(a)
                                            if nres == 1 then top = top + 1; S[top] = r end
                                            pc = pc + 16
                                        end
                                    elseif op == 185 then
                                        local v = S[base + C[pc + 2] - 1]
                                        S[base + C[pc + 1] - 1] = {
                                            v,
                                            v + K[C[pc + 3]],
                                            v + K[C[pc + 4]],
                                        }
                                        pc = pc + 60
                                    elseif op == 186 then
                                        local t = S[base + C[pc + 1] - 1]
                                        local i = S[base + C[pc + 2] - 1]
                                        local j = S[base + C[pc + 3] - 1]
                                        local a = t[i]
                                        local b = t[j]
                                        t[j] = a
                                        t[i] = b
                                        pc = pc + 64
                                    elseif op == 187 then
                                        top = top + 1
                                        S[top] = S[base + C[pc + 1] - 1] + S[base + C[pc + 2] - 1] + K[C[pc + 3]]
                                        pc = pc + 20
                                    elseif op == 188 then
                                        local a = S[top - 1]
                                        local b = S[top]
                                        S[top] = nil
                                        top = top - 1
                                        S[top] = (a * b) / K[C[pc + 1]]
                                        pc = pc + 12
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                end
                            end
                        end
                    else
                        if op < 200 then
                            if op < 194 then
                                if op == 189 then
                                    S[top] = S[top] + S[base + C[pc + 1] - 1] + K[C[pc + 2]]
                                    pc = pc + 16
                                elseif op == 190 then
                                    local res = S[top - 1] / S[top]
                                    S[top] = nil
                                    S[top - 1] = nil
                                    top = top - 2
                                    local dret = cur.ret_sp
                                    S[dret + 1] = res
                                    top = dret + 1
                                    local finished = cur
                                    frames[fi] = nil
                                    fi = fi - 1
                                    if fi == 0 then
                                        active_trace = nil
                                        return res
                                    end
                                    if free_frame_count < 64 then
                                        free_frame_count = free_frame_count + 1
                                        free_frames[free_frame_count] = finished
                                    end
                                    cur = frames[fi]
                                    trace.cur = cur
                                    trace.fi = fi
                                    p = cur.p
                                    C = p.code
                                    K = p.consts
                                    U = cur.ups
                                    e = cur.env
                                    base = cur.base
                                    maxreg = p.maxreg
                                    va = cur.va
                                    pc = cur.pc
                                elseif op == 191 then
                                    local g = e[K[C[pc + 1]]]
                                    top = top + 1
                                    S[top] = g[K[C[pc + 2]]]
                                    pc = pc + 8
                                elseif op == 192 then
                                    local x = S[top]
                                    local y = S[base + C[pc + 1] - 1]
                                    local kind = C[pc + 2]
                                    local v
                                    if kind == 13 then v = x + y
                                    elseif kind == 14 then v = x - y
                                    elseif kind == 15 then v = x * y
                                    elseif kind == 16 then v = x / y
                                    elseif kind == 17 then v = x % y
                                    elseif kind == 18 then v = x ^ y
                                    else v = x .. y end
                                    local prev = S[top - 1]
                                    S[top] = nil
                                    S[top - 1] = prev + v
                                    top = top - 1
                                    pc = pc + 12
                                elseif op == 193 then
                                    local t = S[base + C[pc + 1] - 1]
                                    local k = S[base + C[pc + 2] - 1]
                                    local xd = C[pc + 4]
                                    local yd = C[pc + 5]
                                    local zd = C[pc + 6]
                                    local x, y, z
                                    if xd > 0 then x = S[base + xd - 1] else x = U[-xd + 4].v end
                                    if yd > 0 then y = S[base + yd - 1] else y = U[-yd + 4].v end
                                    if zd > 0 then z = S[base + zd - 1] else z = U[-zd + 4].v end
                                    local v = x * y * z
                                    if C[pc + 3] == 0 then
                                        t[k] = t[k] - v
                                    else
                                        t[k] = t[k] + v
                                    end
                                    pc = pc + 40
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op < 196 then
                                    if op == 194 then
                                        local t = S[base + C[pc + 1] - 1]
                                        local k = S[base + C[pc + 2] - 1]
                                        local ad = C[pc + 4]
                                        local kd = C[pc + 5]
                                        local a
                                        if ad > 0 then a = S[base + ad - 1] else a = U[-ad + 4].v end
                                        local k2
                                        if kd > 0 then k2 = S[base + kd - 1] else k2 = K[-kd] end
                                        local v = a * t[k2]
                                        if C[pc + 3] == 0 then
                                            t[k] = t[k] - v
                                        else
                                            t[k] = t[k] + v
                                        end
                                        pc = pc + 40
                                    elseif op == 195 then
                                        local r = base + C[pc + 1] - 1
                                        local step = S[r + 2]
                                        local limit = S[r + 1]
                                        local idx = S[r] + step
                                        if (step > 0 and idx <= limit) or
                                           (step < 0 and idx >= limit) then
                                            S[r] = idx
                                            S[base + C[pc + 2] - 1] = idx
                                            local body = C[pc + 3]
                                            local t = S[base + C[body + 1] - 1]
                                            t[idx] = true
                                            -- The body is fused into this instruction: stay here so
                                            -- the next dispatch performs the next iteration.
                                        else
                                            pc = pc + 4
                                        end
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                else
                                    if op == 196 then
                                        local dest = base + C[pc + 1] - 1
                                        local b = S[base + C[pc + 3] - 1]
                                        local c = S[base + C[pc + 4] - 1]
                                        local d = S[base + C[pc + 5] - 1]
                                        S[dest] = K[C[pc + 2]] * b * c + d
                                        pc = pc + 32
                                    elseif op == 198 then
                                        local t = S[base + C[pc + 1] - 1]
                                        local k = S[base + C[pc + 2] - 1] + K[C[pc + 3]]
                                        top = top + 1
                                        S[top] = t[k]
                                        pc = pc + 20
                                    elseif op == 199 then
                                        local a = S[top]
                                        local b = S[top - 1]
                                        local c = S[top - 2]
                                        S[top] = nil
                                        S[top - 1] = nil
                                        S[top - 2] = nil
                                        S[base + C[pc + 1] - 1] = c + (b * a)
                                        top = top - 3
                                        pc = pc + 12
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                end
                            end
                        else
                            if op < 204 then
                                if op == 200 then
                                    local td = C[pc + 1]
                                    local t
                                    if td > 0 then t = S[base + td - 1] else t = U[-td + 4].v end
                                    local kd = C[pc + 2]
                                    local k
                                    if kd > 0 then k = S[base + kd - 1] else k = K[-kd] end
                                    local vd = C[pc + 3]
                                    local v
                                    if vd > 0 then v = S[base + vd - 1] else v = K[-vd] end
                                    local x = t[k]
                                    local kind = C[pc + 4]
                                    local res
                                    if kind == 23 then res = x == v
                                    elseif kind == 24 then res = x ~= v
                                    elseif kind == 25 then res = cmp_lt(x, v)
                                    elseif kind == 26 then res = cmp_le(x, v)
                                    elseif kind == 27 then res = cmp_gt(x, v)
                                    elseif kind == 28 then res = cmp_ge(x, v)
                                    else error("bad compare kind", 0) end
                                    if res then pc = pc + 24 else pc = C[pc + 5] end
                                elseif op == 201 then
                                    local dest = base + C[pc + 1] - 1
                                    local a = S[base + C[pc + 2] - 1]
                                    local b = S[base + C[pc + 3] - 1]
                                    local c = S[base + C[pc + 4] - 1]
                                    S[dest] = (a - b) + c
                                    pc = pc + 24
                                elseif op == 202 then
                                    local x = S[base + C[pc + 1] - 1] + S[base + C[pc + 2] - 1]
                                    local v = K[C[pc + 3]]
                                    local kind = C[pc + 4]
                                    local res
                                    if kind == 23 then res = x == v
                                    elseif kind == 24 then res = x ~= v
                                    elseif kind == 25 then res = cmp_lt(x, v)
                                    elseif kind == 26 then res = cmp_le(x, v)
                                    elseif kind == 27 then res = cmp_gt(x, v)
                                    elseif kind == 28 then res = cmp_ge(x, v)
                                    else error("bad compare kind", 0) end
                                    if res then pc = pc + 24 else pc = C[pc + 5] end
                                elseif op == 203 then
                                    local t = S[base + C[pc + 1] - 1]
                                    local k1 = S[base + C[pc + 2] - 1]
                                    local k2 = S[base + C[pc + 3] - 1]
                                    top = top + 1
                                    S[top] = t[k1][k2]
                                    pc = pc + 20
                                else
                                    error("bad fused bytecode", 0)
                                end
                            else
                                if op < 206 then
                                    if op == 204 then
                                        local a = S[top]
                                        local b = S[top - 1]
                                        local c = S[top - 2]
                                        S[top] = nil
                                        S[top - 1] = nil
                                        S[top - 2] = nil
                                        S[base + C[pc + 1] - 1] = c + (b * a)
                                        top = top - 3
                                        local r = base + C[pc + 2] - 1
                                        local step = S[r + 2]
                                        local limit = S[r + 1]
                                        local idx = S[r] + step
                                        if (step > 0 and idx <= limit) or
                                           (step < 0 and idx >= limit) then
                                            S[r] = idx
                                            S[base + C[pc + 3] - 1] = idx
                                            pc = C[pc + 4]
                                        else
                                            pc = pc + 16
                                        end
                                    elseif op == 205 then
                                        local t = S[base + C[pc + 1] - 1]
                                        local k = S[base + C[pc + 2] - 1] + K[C[pc + 3]]
                                        top = top + 1
                                        S[top] = t[k]
                                        local u = C[pc + 4]
                                        local f = U[u + 4].v
                                        local a = S[base + C[pc + 5] - 1]
                                        local b = S[base + C[pc + 6] - 1]
                                        local nres = C[pc + 7]
                                        local fci = closure_info[f]
                                        if fci and not fci[1].isvararg then
                                            local cp = fci[1]
                                            local fpos = top + 1
                                            S[fpos] = a
                                            S[fpos + 1] = b
                                            local cmax = cp.maxreg
                                            for j = 3, cmax do S[fpos + j - 1] = nil end
                                            cur.pc = pc + 40
                                            cur.line = p.lines and p.lines[pc]
                                            frames[fi] = cur
                                            local nfree = free_frame_count
                                            local frame
                                            if nfree > 0 then
                                                frame = free_frames[nfree]
                                                free_frames[nfree] = nil
                                                free_frame_count = nfree - 1
                                            else
                                                frame = {}
                                            end
                                            frame.p = cp
                                            frame.ups = fci
                                            frame.base = fpos
                                            frame.pc = 1
                                            frame.ret_sp = top
                                            frame.wanted = nres
                                            frame.va = nil
                                            frame.env = fci[2]
                                            frame.cl = f
                                            frame.line = nil
                                            cur = frame
                                            fi = fi + 1
                                            frames[fi] = cur
                                            trace.cur = cur
                                            trace.fi = fi
                                            p = cp
                                            C = cp.code
                                            K = cp.consts
                                            U = fci
                                            e = fci[2]
                                            base = fpos
                                            maxreg = cmax
                                            va = nil
                                            pc = cp.entry or 1
                                            top = fpos + cmax - 1
                                        else
                                            local r = f(a, b)
                                            if nres == 1 then top = top + 1; S[top] = r end
                                            pc = pc + 40
                                        end
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                else
                                    if op == 206 then
                                        local denom = S[top]
                                        local num = S[top - 1]
                                        local q = num / denom
                                        local v = S[top - 2]
                                        local t = S[top - 3]
                                        S[top] = nil
                                        S[top - 1] = nil
                                        S[top - 2] = nil
                                        S[top - 3] = nil
                                        S[base + C[pc + 1] - 1] = t + v * q
                                        top = top - 4
                                        local r = base + C[pc + 2] - 1
                                        local step = S[r + 2]
                                        local limit = S[r + 1]
                                        local idx = S[r] + step
                                        if (step > 0 and idx <= limit) or
                                           (step < 0 and idx >= limit) then
                                            S[r] = idx
                                            S[base + C[pc + 3] - 1] = idx
                                            pc = C[pc + 4]
                                        else
                                            pc = pc + 20
                                        end
                                    elseif op == 207 then
                                        S[top] = K[C[pc + 1]] / S[top]
                                        pc = pc + 4
                                    elseif op == 208 then
                                        local q = K[C[pc + 1]] / S[top]
                                        local v = S[top - 1]
                                        local t = S[top - 2]
                                        S[top] = nil
                                        S[top - 1] = nil
                                        S[top - 2] = nil
                                        S[base + C[pc + 2] - 1] = t + v * q
                                        top = top - 3
                                        local r = base + C[pc + 3] - 1
                                        local step = S[r + 2]
                                        local limit = S[r + 1]
                                        local idx = S[r] + step
                                        if (step > 0 and idx <= limit) or
                                           (step < 0 and idx >= limit) then
                                            S[r] = idx
                                            S[base + C[pc + 4] - 1] = idx
                                            pc = C[pc + 5]
                                        else
                                            pc = pc + 20
                                        end
                                    else
                                        error("bad fused bytecode", 0)
                                    end
                                end
                            end
                        end
                    end
                end
            end

        else
            if op < 26 then
                if op < 13 then
                    if op < 6 then
                        if op < 3 then
                            if op == 1 then
                            local k = K[C[pc + 1]]
                            top = top + 1
                            S[top] = k
                            pc = pc + 4
                            elseif op == 2 then
                            top = top + 1
                            S[top] = (C[pc + 1] == 1)
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        else
                            if op == 3 then
                            local n = C[pc + 1]
                            for i = 1, n do
                                top = top + 1
                                S[top] = nil
                            end
                            pc = pc + 4
                            elseif op == 4 then
                            top = top + 1
                            S[top] = S[base + C[pc + 1] - 1]
                            pc = pc + 4
                            elseif op == 5 then
                            S[base + C[pc + 1] - 1] = S[top]
                            S[top] = nil
                            top = top - 1
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        end
                    else
                        if op < 9 then
                            if op == 6 then
                            local cell = S[base + C[pc + 1] - 1]
                            top = top + 1
                            S[top] = cell.v
                            pc = pc + 4
                            elseif op == 7 then
                            local cell = S[base + C[pc + 1] - 1]
                            cell.v = S[top]
                            S[top] = nil
                            top = top - 1
                            pc = pc + 4
                            elseif op == 8 then
                            local i = base + C[pc + 1] - 1
                            S[i] = { v = S[i] }
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        else
                            if op == 9 then
                            top = top + 1
                            S[top] = U[C[pc + 1] + 4].v
                            pc = pc + 4
                            elseif op == 10 then
                            U[C[pc + 1] + 4].v = S[top]
                            S[top] = nil
                            top = top - 1
                            pc = pc + 4
                            elseif op == 11 then
                            top = top + 1
                            S[top] = e[K[C[pc + 1]]]
                            pc = pc + 4
                            elseif op == 12 then
                            e[K[C[pc + 1]]] = S[top]
                            S[top] = nil
                            top = top - 1
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        end
                    end
                else
                    if op < 19 then
                        if op < 15 then
                            if op == 13 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = a + b
                            pc = pc + 4
                            elseif op == 14 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = a - b
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        else
                            if op == 15 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = a * b
                            pc = pc + 4
                            elseif op == 16 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = a / b
                            pc = pc + 4
                            elseif op == 17 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = a % b
                            pc = pc + 4
                            elseif op == 18 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = a ^ b
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        end
                    else
                        if op < 22 then
                            if op == 19 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = a .. b
                            pc = pc + 4
                            elseif op == 20 then
                            S[top] = -S[top]
                            pc = pc + 4
                            elseif op == 21 then
                            S[top] = not S[top]
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        else
                            if op == 22 then
                            S[top] = #S[top]
                            pc = pc + 4
                            elseif op == 23 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = compare_op(op, a, b)
                            pc = pc + 4
                            elseif op == 24 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = compare_op(op, a, b)
                            pc = pc + 4
                            elseif op == 25 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = compare_op(op, a, b)
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        end
                    end
                end
            else
                if op < 38 then
                    if op < 31 then
                        if op < 28 then
                            if op == 26 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = compare_op(op, a, b)
                            pc = pc + 4
                            elseif op == 27 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = compare_op(op, a, b)
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        else
                            if op == 28 then
                            local b = S[top]
                            local a = S[top - 1]
                            S[top] = nil
                            top = top - 1
                            S[top] = compare_op(op, a, b)
                            pc = pc + 4
                            elseif op == 29 then
                            if not S[top] then
                                pc = C[pc + 1]
                            else
                                S[top] = nil
                                top = top - 1
                                pc = pc + 4
                            end
                            elseif op == 30 then
                            if S[top] then
                                pc = C[pc + 1]
                            else
                                S[top] = nil
                                top = top - 1
                                pc = pc + 4
                            end
                            else
                                error("bad bytecode", 0)
                            end
                        end
                    else
                        if op < 34 then
                            if op == 31 then
                            local v = S[top]
                            S[top] = nil
                            top = top - 1
                            if not v then
                                pc = C[pc + 1]
                            else
                                pc = pc + 4
                            end
                            elseif op == 32 then
                            pc = C[pc + 1]
                            elseif op == 33 then
                            local mreg = C[pc + 1]
                            local nres = C[pc + 2]
                            local tail = C[pc + 3] == 1
                            local fpos = S[base + mreg - 1]
                            local f = S[fpos]
                            local nargs = top - fpos
                            local ret_sp = fpos - 1
                            local fci = closure_info[f]

                            if limits.maxArgs and nargs > limits.maxArgs then
                                error("too many arguments", 0)
                            end
                            if limits.maxStack and top > limits.maxStack then
                                error("stack limit exceeded", 0)
                            end

                            if fci then
                                if not tail and limits.maxCallDepth and
                                   fi >= limits.maxCallDepth then
                                    error("call depth limit exceeded", 0)
                                end
                                local cp = fci[1]
                                local cpups = fci
                                local cva = nil
                                if cp.isvararg then
                                    local nv = nargs - cp.numparams
                                    if nv > 0 then
                                        cva = { n = nv }
                                        for j = 1, nv do
                                            cva[j] = S[fpos + cp.numparams + j]
                                        end
                                    end
                                end

                                -- A tail call reuses the frame, so it must also reuse the
                                -- frame's original stack region. Moving the function and its
                                -- arguments down to `base` keeps `top` bounded; otherwise the
                                -- base creeps upward on every iteration and deep tail
                                -- recursion eventually trips maxStack.
                                if tail and fpos ~= base then
                                    S[base] = f
                                    for j = 1, nargs do
                                        S[base + j] = S[fpos + j]
                                    end
                                    fpos = base
                                end

                                local np = cp.numparams
                                for j = 1, np do
                                    if j <= nargs then
                                        S[fpos + j - 1] = S[fpos + j]
                                    else
                                        S[fpos + j - 1] = nil
                                    end
                                end
                                local cmax = cp.maxreg
                                for j = np + 1, cmax do
                                    S[fpos + j - 1] = nil
                                end

                                local cenv = fci[2]
                                if fci[3] and getfenv then
                                    cenv = getfenv(f)
                                end

                                local call_ret_sp = tail and cur.ret_sp or ret_sp
                                local call_wanted = tail and cur.wanted or nres
                                if tail then
                                    -- Reuse the current frame table for a tail call.
                                    cur.p = cp
                                    cur.ups = cpups
                                    cur.base = fpos
                                    cur.pc = 1
                                    cur.ret_sp = call_ret_sp
                                    cur.wanted = call_wanted
                                    cur.va = cva
                                    cur.env = cenv
                                    cur.cl = f
                                    cur.line = nil
                                    frames[fi] = cur
                                else
                                    cur.pc = pc + 4
                                    cur.line = p.lines and p.lines[pc]
                                    frames[fi] = cur
                                    local nfree = free_frame_count
                                    local frame
                                    if nfree > 0 then
                                        frame = free_frames[nfree]
                                        free_frames[nfree] = nil
                                        free_frame_count = nfree - 1
                                    else
                                        frame = {}
                                    end
                                    frame.p = cp
                                    frame.ups = cpups
                                    frame.base = fpos
                                    frame.pc = 1
                                    frame.ret_sp = call_ret_sp
                                    frame.wanted = call_wanted
                                    frame.va = cva
                                    frame.env = cenv
                                    frame.cl = f
                                    frame.line = nil
                                    cur = frame
                                    fi = fi + 1
                                    frames[fi] = cur
                                end
                                trace.cur = cur
                                trace.fi = fi

                                p = cp
                                C = cp.code
                                K = cp.consts
                                U = cpups
                                e = cenv
                                base = fpos
                                maxreg = cmax
                                va = cva
                                pc = cp.entry or 1
                                top = fpos + cmax - 1
                            else
                                if getfenv and f == getfenv then
                                    local arg = (nargs == 0) and 1 or S[fpos + 1]
                                    local r = sandbox_getfenv(arg, e, frames, fi)
                                    top = ret_sp
                                    if nres ~= 0 then
                                        top = top + 1
                                        S[top] = r
                                        for j = 2, nres do
                                            top = top + 1
                                            S[top] = nil
                                        end
                                    end
                                elseif setfenv and f == setfenv then
                                    if nargs < 2 then
                                        error("bad argument count to 'setfenv'", 0)
                                    end
                                    local r, new_e = sandbox_setfenv(S[fpos + 1], S[fpos + 2], frames, fi)
                                    if new_e then
                                        e = new_e
                                    end
                                    top = ret_sp
                                    if nres ~= 0 then
                                        top = top + 1
                                        S[top] = r
                                        for j = 2, nres do
                                            top = top + 1
                                            S[top] = nil
                                        end
                                    end
                                elseif f == error then
                                    -- Reimplement `error(msg, level)` against interpreted
                                    -- frames so `level` selects the right sandbox location.
                                    last_native_fn = f
                                    local msg = S[fpos + 1]
                                    local level = S[fpos + 2]
                                    if type(msg) ~= "string" then
                                        error(msg, 0)
                                    end
                                    if type(level) ~= "number" then
                                        level = 1
                                    end
                                    if level == 0 then
                                        error(LOCATION_MARK .. msg, 0)
                                    end
                                    local idx = fi - level + 1
                                    local fr = (idx >= 1) and frames[idx] or nil
                                    local fl = fr and (idx == fi and p.lines and p.lines[pc] or fr.line)
                                    if fl then
                                        error(LOCATION_MARK ..
                                            (fr.p.sourceName or "<string>") .. ":" .. fl ..
                                            ": " .. msg, 0)
                                    end
                                    error(LOCATION_MARK .. msg, 0)
                                elseif (f == pcall or (xpcall and f == xpcall)) and
                                       nargs >= 1 then
                                    -- Guest pcall/xpcall must not leak host paths, whether the
                                    -- target is interpreted or a native function that calls
                                    -- back into interpreted callbacks (sort/gsub comparators).
                                    local target = S[fpos + 1]
                                    local tr = {}
                                    local rs = protected_call(f == xpcall, target,
                                        S[fpos + 2], tr, active_trace, S, fpos, top, e, frames, fi)
                                    if rs.new_e then
                                        e = rs.new_e
                                    end
                                    top = ret_sp
                                    if nres == 0 then
                                        -- discard all results
                                    elseif nres == 1 then
                                        top = ret_sp + 1
                                        S[top] = rs[1]
                                    elseif nres < 0 then
                                        for j = 1, rs.n do
                                            S[ret_sp + j] = rs[j]
                                        end
                                        top = ret_sp + rs.n
                                    else
                                        for j = 1, nres do
                                            S[ret_sp + j] = rs[j]
                                        end
                                        top = ret_sp + nres
                                    end
                                else
                                    last_native_fn = f
                                    if nres == 0 then
                                        if nargs == 0 then
                                            f()
                                        elseif nargs == 1 then
                                            f(S[fpos + 1])
                                        elseif nargs == 2 then
                                            f(S[fpos + 1], S[fpos + 2])
                                        else
                                            f(unpack(S, fpos + 1, top))
                                        end
                                        top = ret_sp
                                    elseif nres == 1 then
                                        local r
                                        if nargs == 0 then
                                            r = f()
                                        elseif nargs == 1 then
                                            r = f(S[fpos + 1])
                                        elseif nargs == 2 then
                                            r = f(S[fpos + 1], S[fpos + 2])
                                        else
                                            r = f(unpack(S, fpos + 1, top))
                                        end
                                        top = ret_sp + 1
                                        S[top] = r
                                    else
                                        local rs
                                        if nargs == 0 then
                                            rs = pack(f())
                                        elseif nargs == 1 then
                                            rs = pack(f(S[fpos + 1]))
                                        elseif nargs == 2 then
                                            rs = pack(f(S[fpos + 1], S[fpos + 2]))
                                        else
                                            rs = pack(f(unpack(S, fpos + 1, top)))
                                        end
                                        if limits.maxReturns and rs.n > limits.maxReturns then
                                            error("too many return values", 0)
                                        end
                                        top = ret_sp
                                        if nres < 0 then
                                            for j = 1, rs.n do
                                                S[ret_sp + j] = rs[j]
                                            end
                                            top = ret_sp + rs.n
                                        else
                                            for j = 1, nres do
                                                S[ret_sp + j] = rs[j]
                                            end
                                            top = ret_sp + nres
                                        end
                                    end
                                end
                                if tail then
                                    local exprbase = base + maxreg
                                    local n = top - ret_sp
                                    for j = 1, n do
                                        S[exprbase + j - 1] = S[ret_sp + j]
                                    end
                                    top = exprbase + n - 1
                                end
                                pc = pc + 4
                            end
                            else
                                error("bad bytecode", 0)
                            end
                        else
                            if op == 34 then
                            local n = C[pc + 1]
                            local exprbase = base + maxreg
                            local nret
                            if n < 0 then
                                nret = top - (exprbase - 1)
                            else
                                nret = n
                            end
                            if limits.maxReturns and nret > limits.maxReturns then
                                error("too many return values", 0)
                            end
                            local src = top - nret + 1
                            local dret = cur.ret_sp
                            for j = 1, nret do
                                S[dret + j] = S[src + j - 1]
                            end
                            local wanted = cur.wanted
                            local keep = nret
                            if wanted == 0 then
                                keep = 0
                            elseif wanted ~= -1 then
                                keep = wanted
                                for j = nret + 1, keep do
                                    S[dret + j] = nil
                                end
                            end
                            top = dret + keep

                            local finished = cur
                            frames[fi] = nil
                            fi = fi - 1
                            if fi == 0 then
                                active_trace = nil
                                if top == 0 then
                                    return
                                end
                                return unpack(S, 1, top)
                            end
                            if free_frame_count < 64 then
                                free_frame_count = free_frame_count + 1
                                free_frames[free_frame_count] = finished
                            end

                            cur = frames[fi]
                            trace.cur = cur
                            trace.fi = fi
                            p = cur.p
                            C = p.code
                            K = p.consts
                            U = cur.ups
                            e = cur.env
                            base = cur.base
                            maxreg = p.maxreg
                            va = cur.va
                            pc = cur.pc
                            elseif op == 35 then
                            local nres = C[pc + 1]
                            local n = va and va.n or 0
                            local varargCount = nres < 0 and n or nres
                            if limits.maxReturns and varargCount > limits.maxReturns then
                                error("too many return values", 0)
                            end
                            if limits.maxStack and top + varargCount > limits.maxStack then
                                error("stack limit exceeded", 0)
                            end
                            if nres < 0 then
                                for j = 1, n do
                                    top = top + 1
                                    S[top] = va[j]
                                end
                            else
                                for j = 1, nres do
                                    top = top + 1
                                    if j <= n then
                                        S[top] = va[j]
                                    else
                                        S[top] = nil
                                    end
                                end
                            end
                            pc = pc + 4
                            elseif op == 36 then
                            top = top + 1
                            S[top] = {}
                            pc = pc + 4
                            elseif op == 37 then
                            local t = S[top]
                            S[top] = t[K[C[pc + 1]]]
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        end
                    end
                else
                    if op < 44 then
                        if op < 40 then
                            if op == 38 then
                            local key = S[top]
                            S[top] = nil
                            top = top - 1
                            local t = S[top]
                            S[top] = t[key]
                            pc = pc + 4
                            elseif op == 39 then
                            local val = S[top]
                            S[top] = nil
                            top = top - 1
                            local t = S[base + C[pc + 1] - 1]
                            t[K[C[pc + 2]]] = val
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        else
                            if op == 40 then
                            local val = S[top]
                            S[top] = nil
                            top = top - 1
                            local t = S[base + C[pc + 1] - 1]
                            local key = S[base + C[pc + 2] - 1]
                            t[key] = val
                            pc = pc + 4
                            elseif op == 41 then
                            local t = S[top]
                            S[top] = t[K[C[pc + 1]]]
                            top = top + 1
                            S[top] = t
                            pc = pc + 4
                            elseif op == 42 then
                            local val = S[top]
                            S[top] = nil
                            top = top - 1
                            local t = S[base + C[pc + 1] - 1]
                            t[C[pc + 2]] = val
                            pc = pc + 4
                            elseif op == 43 then
                            local t = S[base + C[pc + 1] - 1]
                            local idx = C[pc + 2]
                            local marker = S[base + C[pc + 3] - 1]
                            local n = top - marker
                            for j = 1, n do
                                t[idx + j - 1] = S[marker + j]
                            end
                            for j = marker + 1, top do
                                S[j] = nil
                            end
                            top = marker
                            pc = pc + 4
                            else
                                error("bad bytecode", 0)
                            end
                        end
                    else
                        if op < 47 then
                            if op == 44 then
                            S[base + C[pc + 1] - 1] = top - C[pc + 2]
                            pc = pc + 4
                            elseif op == 45 then
                            local n = C[pc + 1]
                            for j = 1, n do
                                S[top] = nil
                                top = top - 1
                            end
                            pc = pc + 4
                            elseif op == 46 then
                            local r = base + C[pc + 1] - 1
                            local idx = tonumber(S[r])
                            local limit = tonumber(S[r + 1])
                            local step = tonumber(S[r + 2])
                            if not idx or not limit or not step then
                                error("'for' values must be numbers", 0)
                            end
                            S[r] = idx
                            S[r + 1] = limit
                            S[r + 2] = step
                            if step == 0 then
                                error("'for' step is zero", 0)
                            end
                            if (step > 0 and idx > limit) or
                               (step < 0 and idx < limit) then
                                pc = C[pc + 2]
                            else
                                pc = pc + 4
                            end
                            else
                                error("bad bytecode", 0)
                            end
                        else
                            if op < 49 then
                                if op == 47 then
                                local r = base + C[pc + 1] - 1
                                local step = S[r + 2]
                                local limit = S[r + 1]
                                local idx = S[r] + step
                                if (step > 0 and idx <= limit) or
                                   (step < 0 and idx >= limit) then
                                    S[r] = idx
                                    pc = C[pc + 2]
                                else
                                    pc = pc + 4
                                end
                                elseif op == 48 then
                                local cp = p.protos[C[pc + 1]]
                                local ud = cp.updesc
                                local ups = { cp, e, false, true }
                                for j = 1, #ud do
                                    local d = ud[j]
                                    if d.instack == 1 then
                                        ups[j + 4] = S[base + d.idx - 1]
                                    else
                                        ups[j + 4] = U[d.idx + 4]
                                    end
                                end
                                top = top + 1
                                S[top] = make_closure(cp, ups, e, false)
                                pc = pc + 4
                                else
                                    error("bad bytecode", 0)
                                end
                            else
                                if op == 49 then
                                S[base + C[pc + 1] - 1] = S[top - C[pc + 2]]
                                pc = pc + 4
                                elseif op == 50 then
                                pc = pc + 4
                                elseif op == 51 then
                                local v = S[top]
                                S[top] = nil
                                top = top - 1
                                if v == nil then
                                    pc = C[pc + 1]
                                else
                                    pc = pc + 4
                                end
                                else
                                    error("bad bytecode", 0)
                                end
                            end
                        end
                    end
                end
            end
        end
    end
end
-- v2 groundwork: walk one linear block using the compiler's slot lengths.
-- The current optimizer already knows the exact span of every instruction;
-- the closure backend must not guess it from the opcode number.
function closure_backend.scan_block(proto, start)
    local code = proto.code
    local len = proto.slotlen
    local n = proto.ncode or #code
    if not len then
        return nil, "prototype has no slot lengths"
    end
    start = start or proto.entry or 1
    if start < 1 or start > n or not len[start] then
        return nil, "invalid block start"
    end

    local ops = {}
    local pc = start
    while pc <= n do
        local slots = len[pc]
        if not slots or slots < 1 then
            return nil, "missing slot length at pc " .. tostring(pc)
        end
        local op = code[pc]
        ops[#ops + 1] = {
            pc = pc,
            op = op,
            a = code[pc + 1],
            b = code[pc + 2],
            c = code[pc + 3],
            slots = slots,
        }
        local nextpc = pc + slots * 4
        -- RET, JMP, JMPF, TESTF, TESTT, CALLD, FORPREP, FORLOOP, JMPNIL.
        if op == 34 or op == 32 or op == 31 or op == 29 or op == 30 or
           op == 33 or op == 46 or op == 47 or op == 51 then
            return {
                start = start,
                finish = pc,
                nextpc = nextpc,
                ops = ops,
            }
        end
        pc = nextpc
    end
    return {
        start = start,
        finish = pc,
        nextpc = pc,
        ops = ops,
    }
end

-- First closure-threaded slice: straight-line stack arithmetic and returns.
-- It is deliberately opt-in; unsupported opcodes make the builder fail and
-- the caller can keep using run_closure.
local ARITH = {
    [13] = function(x, y) return x + y end,
    [14] = function(x, y) return x - y end,
    [15] = function(x, y) return x * y end,
    [16] = function(x, y) return x / y end,
    [17] = function(x, y) return x % y end,
    [18] = function(x, y) return x ^ y end,
    [19] = function(x, y) return x .. y end,
}

local function arith_fn(kind)
    return ARITH[kind]
end

function closure_backend.build_block_chain(proto, block, entries)
    if proto.isvararg then
        return nil, "vararg prototype"
    end
    local K = proto.consts
    local ops = block.ops
    local next_pc = block.nextpc
    local next_op = nil
    for i = #ops, 1, -1 do
        local ins = ops[i]
        local op, a, b, c = ins.op, ins.a, ins.b, ins.c
        local nxt = next_op
        local handler
        if op == 50 then -- NOP
            handler = function(st) return nxt end
        elseif op == 1 then -- LOADK
            local k = K[a]
            handler = function(st)
                local top = st.top + 1
                st.top = top
                st.S[top] = k
                return nxt
            end
        elseif op == 2 then -- LOADBOOL
            local v = (a == 1)
            handler = function(st)
                local top = st.top + 1
                st.top = top
                st.S[top] = v
                return nxt
            end
        elseif op == 3 then -- LOADNIL
            local n = a
            handler = function(st)
                local top = st.top
                for j = 1, n do
                    top = top + 1
                    st.S[top] = nil
                end
                st.top = top
                return nxt
            end
        elseif op == 4 then -- GETLOCAL
            local idx = a
            handler = function(st)
                local top = st.top + 1
                st.top = top
                st.S[top] = st.S[idx]
                return nxt
            end
        elseif op == 5 then -- SETLOCAL
            local idx = a
            handler = function(st)
                local top = st.top
                st.S[idx] = st.S[top]
                st.S[top] = nil
                st.top = top - 1
                return nxt
            end
        elseif op >= 13 and op <= 19 then -- binary arithmetic/concat
            local fn = ({
                [13] = function(x, y) return x + y end,
                [14] = function(x, y) return x - y end,
                [15] = function(x, y) return x * y end,
                [16] = function(x, y) return x / y end,
                [17] = function(x, y) return x % y end,
                [18] = function(x, y) return x ^ y end,
                [19] = function(x, y) return x .. y end,
            })[op]
            handler = function(st)
                local top = st.top
                local y = st.S[top]
                local x = st.S[top - 1]
                st.S[top] = nil
                top = top - 1
                st.S[top] = fn(x, y)
                st.top = top
                return nxt
            end
        elseif op >= 23 and op <= 28 then -- comparisons
            local cmp = op
            handler = function(st)
                local top = st.top
                local y = st.S[top]
                local x = st.S[top - 1]
                st.S[top] = nil
                top = top - 1
                st.S[top] = compare_op(cmp, x, y)
                st.top = top
                return nxt
            end
        elseif op == 20 then -- UNM
            handler = function(st)
                st.S[st.top] = -st.S[st.top]
                return nxt
            end
        elseif op == 21 then -- NOT
            handler = function(st)
                st.S[st.top] = not st.S[st.top]
                return nxt
            end
        elseif op == 22 then -- LEN
            handler = function(st)
                st.S[st.top] = #st.S[st.top]
                return nxt
            end
        elseif op >= 58 and op <= 69 then -- arithmetic fusions
            local rr = (op % 2 == 0)
            local kind = 13 + math.floor((op - 58) / 2)
            local fn = arith_fn(kind)
            if not fn then
                return nil, "unsupported opcode " .. tostring(op)
            end
            local x = a
            local y = b
            if rr then
                handler = function(st)
                    local top = st.top + 1
                    st.top = top
                    st.S[top] = fn(st.S[x], st.S[y])
                    return nxt
                end
            else
                local k = K[y]
                handler = function(st)
                    local top = st.top + 1
                    st.top = top
                    st.S[top] = fn(st.S[x], k)
                    return nxt
                end
            end
        elseif op == 167 then -- ASSIGN_TO_RR
            local kind = proto.code[ins.pc + 4]
            local fn = arith_fn(kind)
            if not fn then
                return nil, "unsupported arithmetic kind"
            end
            local dst, x, y = a, b, c
            handler = function(st)
                st.S[dst] = fn(st.S[x], st.S[y])
                return nxt
            end
        elseif op == 168 then -- ASSIGN_TO_RK
            local kind = proto.code[ins.pc + 4]
            local fn = arith_fn(kind)
            if not fn then
                return nil, "unsupported arithmetic kind"
            end
            local dst, x, k = a, b, K[c]
            handler = function(st)
                st.S[dst] = fn(st.S[x], k)
                return nxt
            end
        elseif op == 164 then -- PUSH_OP_RK
            local kind = proto.code[ins.pc + 4]
            local fn = arith_fn(kind)
            if not fn then
                return nil, "unsupported arithmetic kind"
            end
            local x = K[a]
            local y = b
            handler = function(st)
                local top = st.top + 1
                st.top = top
                st.S[top] = fn(x, st.S[y])
                return nxt
            end
        elseif op == 165 then -- PUSH_OP_RS
            local kind = proto.code[ins.pc + 4]
            local fn = arith_fn(kind)
            if not fn then
                return nil, "unsupported arithmetic kind"
            end
            local y = a
            handler = function(st)
                local top = st.top
                st.S[top] = fn(st.S[top], st.S[y])
                return nxt
            end
        elseif op == 166 then -- PUSH_OP_KS
            local kind = proto.code[ins.pc + 4]
            local fn = arith_fn(kind)
            if not fn then
                return nil, "unsupported arithmetic kind"
            end
            local k = K[a]
            handler = function(st)
                local top = st.top
                st.S[top] = fn(st.S[top], k)
                return nxt
            end
        elseif op == 32 then -- JMP
            local target = a
            handler = function(st) return entries and entries[target] end
        elseif op == 31 then -- JMPF
            local target = a
            handler = function(st)
                local top = st.top
                local v = st.S[top]
                st.S[top] = nil
                st.top = top - 1
                if not v then return entries[target] end
                return entries[next_pc]
            end
        elseif op == 29 then -- TESTF
            local target = a
            handler = function(st)
                local top = st.top
                if not st.S[top] then return entries[target] end
                st.S[top] = nil
                st.top = top - 1
                return entries[next_pc]
            end
        elseif op == 30 then -- TESTT
            local target = a
            handler = function(st)
                local top = st.top
                if st.S[top] then return entries[target] end
                st.S[top] = nil
                st.top = top - 1
                return entries[next_pc]
            end
        elseif op == 51 then -- JMPNIL
            local target = a
            handler = function(st)
                local top = st.top
                local v = st.S[top]
                st.S[top] = nil
                st.top = top - 1
                if v == nil then return entries[target] end
                return entries[next_pc]
            end
        elseif op == 46 then -- FORPREP
            local r = a
            local target = b
            handler = function(st)
                local idx = tonumber(st.S[r])
                local limit = tonumber(st.S[r + 1])
                local step = tonumber(st.S[r + 2])
                if not idx or not limit or not step then
                    error("'for' values must be numbers", 0)
                end
                st.S[r] = idx
                st.S[r + 1] = limit
                st.S[r + 2] = step
                if step == 0 then
                    error("'for' step is zero", 0)
                end
                if (step > 0 and idx > limit) or
                   (step < 0 and idx < limit) then
                    return entries[target]
                end
                return entries[next_pc]
            end
        elseif op == 47 then -- FORLOOP
            local r = a
            local target = b
            handler = function(st)
                local step = st.S[r + 2]
                local limit = st.S[r + 1]
                local idx = st.S[r] + step
                if (step > 0 and idx <= limit) or
                   (step < 0 and idx >= limit) then
                    st.S[r] = idx
                    return entries[target]
                end
                return entries[next_pc]
            end
        elseif op == 34 then -- RET
            local nret = a
            if nret < 0 then
                return nil, "open return"
            end
            handler = function(st)
                local n = nret
                local ret = {}
                local src = st.top - n + 1
                for j = 1, n do
                    ret[j] = st.S[src + j - 1]
                end
                st.ret = ret
                st.nret = n
                return nil
            end
        else
            return nil, "unsupported opcode " .. tostring(op)
        end
        next_op = handler
    end
    return next_op
end

local function push_results(S, ret_sp, nres, rs)
    local top = ret_sp
    if nres < 0 then
        for j = 1, rs.n do
            top = top + 1
            S[top] = rs[j]
        end
    elseif nres > 0 then
        for j = 1, nres do
            top = top + 1
            if j <= rs.n then
                S[top] = rs[j]
            else
                S[top] = nil
            end
        end
    end
    return top
end

local function return_results(st, rs)
    local frames = st.frames
    local nf = #frames
    if nf > 0 then
        local caller = frames[nf]
        frames[nf] = nil
        st.S = caller.S
        st.ups = caller.ups
        st.env = caller.env
        st.va = caller.va
        st.proto = caller.p
        st.limits = caller.limits
        st.pc = caller.pc
        st.line = caller.line
        local top = push_results(caller.S, caller.ret_sp, caller.nres, rs)
        st.top = top
        if st.limits.maxStack and top > st.limits.maxStack then
            error("stack limit exceeded", 0)
        end
        return caller.cont
    end
    st.ret = rs
    st.nret = rs.n
    return nil
end

-- A true block closure: one Lua call executes the whole straight-line body
-- with an internal dispatch, then returns the next block or stops.
function closure_backend.build_block_closure(proto, block, entries, loop_info)
    local K = proto.consts
    local ops = block.ops
    local n = #ops
    if n == 0 then
        return nil, "empty block"
    end
    local term = ops[n]
    local top_op = term.op
    if not (top_op == 34 or top_op == 32 or top_op == 31 or
            top_op == 29 or top_op == 30 or top_op == 51 or
            top_op == 46 or top_op == 47 or top_op == 33) then
        return nil, "unsupported terminator " .. tostring(top_op)
    end
    local body_n = n - 1
    for i = 1, body_n do
        local op = ops[i].op
        local ok = op == 50 or op == 1 or op == 2 or op == 3 or op == 4 or
            op == 5 or op == 6 or op == 7 or op == 8 or op == 9 or op == 10 or
            op == 11 or op == 12 or op == 35 or (op >= 36 and op <= 43) or
            op == 44 or op == 45 or op == 48 or op == 49 or
            (op >= 13 and op <= 22) or (op >= 23 and op <= 28)
        if not ok then
            return nil, "unsupported block opcode " .. tostring(op)
        end
    end

    local function block_closure(st)
        st.pc = block.start
        st.line = proto.lines and proto.lines[block.start]
        if st.max then
            st.steps = st.steps + n
            if st.steps > st.max then
                error("instruction limit exceeded", 0)
            end
        end
        local S = st.S
        local top = st.top
        local i = 1
        while i <= body_n do
            local ins = ops[i]
            local op = ins.op
            if op == 50 then
                -- NOP
            elseif op == 1 then
                top = top + 1
                S[top] = K[ins.a]
            elseif op == 2 then
                top = top + 1
                S[top] = (ins.a == 1)
            elseif op == 3 then
                local count = ins.a
                for j = 1, count do
                    top = top + 1
                    S[top] = nil
                end
            elseif op == 4 then
                top = top + 1
                S[top] = S[ins.a]
            elseif op == 5 then
                S[ins.a] = S[top]
                S[top] = nil
                top = top - 1
            elseif op == 6 then -- GETCELL
                top = top + 1
                S[top] = S[ins.a].v
            elseif op == 7 then -- SETCELL
                S[ins.a].v = S[top]
                S[top] = nil
                top = top - 1
            elseif op == 8 then -- CELL
                local idx = ins.a
                S[idx] = { v = S[idx] }
            elseif op == 9 then -- GETUPVAL
                top = top + 1
                S[top] = st.ups[ins.a + 4].v
            elseif op == 10 then -- SETUPVAL
                st.ups[ins.a + 4].v = S[top]
                S[top] = nil
                top = top - 1
            elseif op == 11 then -- GETGLOBAL
                top = top + 1
                S[top] = st.env[K[ins.a]]
            elseif op == 12 then -- SETGLOBAL
                st.env[K[ins.a]] = S[top]
                S[top] = nil
                top = top - 1
            elseif op == 48 then -- CLOSURE
                local cp = proto.protos[ins.a]
                local ud = cp.updesc
                local ups = { cp, st.env, false, true }
                for j = 1, #ud do
                    local d = ud[j]
                    if d.instack == 1 then
                        ups[j + 4] = S[d.idx]
                    else
                        ups[j + 4] = st.ups[d.idx + 4]
                    end
                end
                top = top + 1
                S[top] = make_closure(cp, ups, st.env, false)
            elseif op == 36 then -- NEWTABLE
                top = top + 1
                S[top] = {}
            elseif op == 37 then -- FIELD
                local t = S[top]
                S[top] = t[K[ins.a]]
            elseif op == 38 then -- INDEX
                local key = S[top]
                S[top] = nil
                top = top - 1
                local t = S[top]
                S[top] = t[key]
            elseif op == 39 then -- SETFIELD
                local val = S[top]
                S[top] = nil
                top = top - 1
                local t = S[ins.a]
                t[K[ins.b]] = val
            elseif op == 40 then -- SETINDEX
                local val = S[top]
                S[top] = nil
                top = top - 1
                local t = S[ins.a]
                t[S[ins.b]] = val
            elseif op == 41 then -- SELF
                local t = S[top]
                S[top] = t[K[ins.a]]
                top = top + 1
                S[top] = t
            elseif op == 42 then -- SETLIST
                local val = S[top]
                S[top] = nil
                top = top - 1
                local t = S[ins.a]
                t[ins.b] = val
            elseif op == 43 then -- SETLISTMULTI
                local t = S[ins.a]
                local idx = ins.b
                local marker = S[ins.c]
                local count = top - marker
                for j = 1, count do
                    t[idx + j - 1] = S[marker + j]
                end
                for j = marker + 1, top do
                    S[j] = nil
                end
                top = marker
            elseif op == 44 then
                S[ins.a] = top - ins.b
            elseif op == 45 then
                local count = ins.a
                for j = 1, count do
                    S[top] = nil
                    top = top - 1
                end
            elseif op == 49 then
                S[ins.a] = S[top - ins.b]
            elseif op == 35 then -- VARARG
                local nres = ins.a
                local va = st.va
                local count = va and va.n or 0
                if nres < 0 then
                    for j = 1, count do
                        top = top + 1
                        S[top] = va[j]
                    end
                else
                    for j = 1, nres do
                        top = top + 1
                        if j <= count then
                            S[top] = va[j]
                        else
                            S[top] = nil
                        end
                    end
                end
            elseif op >= 13 and op <= 19 then
                local b = S[top]
                local a = S[top - 1]
                S[top] = nil
                top = top - 1
                if op == 13 then S[top] = a + b
                elseif op == 14 then S[top] = a - b
                elseif op == 15 then S[top] = a * b
                elseif op == 16 then S[top] = a / b
                elseif op == 17 then S[top] = a % b
                elseif op == 18 then S[top] = a ^ b
                else S[top] = a .. b end
            elseif op == 20 then
                S[top] = -S[top]
            elseif op == 21 then
                S[top] = not S[top]
            elseif op == 22 then
                S[top] = #S[top]
            else -- 23..28
                local b = S[top]
                local a = S[top - 1]
                S[top] = nil
                top = top - 1
                S[top] = compare_op(op, a, b)
            end
            i = i + 1
        end
        st.top = top
        if st.limits.maxStack and top > st.limits.maxStack then
            error("stack limit exceeded", 0)
        end

        local op = top_op
        if op == 34 then
            local nret = term.a
            if nret < 0 then
                nret = top - proto.maxreg
                if nret < 0 then nret = 0 end
            end
            if st.limits.maxReturns and nret > st.limits.maxReturns then
                error("too many return values", 0)
            end
            local ret = { n = nret }
            local src = top - nret + 1
            for j = 1, nret do
                ret[j] = S[src + j - 1]
            end
            return return_results(st, ret)
        elseif op == 32 then
            return entries[term.a]
        elseif op == 31 then
            local v = S[top]
            S[top] = nil
            st.top = top - 1
            if not v then return entries[term.a] end
            return entries[block.nextpc]
        elseif op == 29 then
            if not S[top] then return entries[term.a] end
            S[top] = nil
            st.top = top - 1
            return entries[block.nextpc]
        elseif op == 30 then
            if S[top] then return entries[term.a] end
            S[top] = nil
            st.top = top - 1
            return entries[block.nextpc]
        elseif op == 51 then
            local v = S[top]
            S[top] = nil
            st.top = top - 1
            if v == nil then return entries[term.a] end
            return entries[block.nextpc]
        elseif op == 33 then -- CALLD
            local mreg = term.a
            local nres = term.b
            local tail = term.c == 1
            local fpos = S[mreg]
            local f = S[fpos]
            local nargs = top - fpos
            if st.limits.maxArgs and nargs > st.limits.maxArgs then
                error("too many arguments", 0)
            end
            if st.limits.maxStack and top > st.limits.maxStack then
                error("stack limit exceeded", 0)
            end

            local target_entry = chain_map[f]
            local target_info = closure_info[f]
            if target_entry and target_info then
                local cp = target_info[1]
                local S2 = {}
                local np = cp.numparams
                for j = 1, np do
                    S2[j] = S[fpos + j]
                end
                for j = np + 1, cp.maxreg do
                    S2[j] = nil
                end
                local cva
                if cp.isvararg then
                    local nv = nargs - np
                    if nv > 0 then
                        cva = { n = nv }
                        for j = 1, nv do
                            cva[j] = S[fpos + np + j]
                        end
                    end
                end
                if cp.limits and cp.limits.maxStack and
                   cp.maxreg > cp.limits.maxStack then
                    error("stack limit exceeded", 0)
                end
                if not tail then
                    if st.limits.maxCallDepth and
                       #st.frames + 1 >= st.limits.maxCallDepth then
                        error("call depth limit exceeded", 0)
                    end
                    st.frames[#st.frames + 1] = {
                        S = S,
                        top = st.top,
                        ups = st.ups,
                        env = st.env,
                        va = st.va,
                        limits = st.limits,
                        p = proto,
                        pc = term.pc,
                        line = proto.lines and proto.lines[term.pc],
                        ret_sp = fpos - 1,
                        nres = nres,
                        cont = entries[block.nextpc],
                    }
                end
                st.S = S2
                st.top = cp.maxreg
                st.proto = cp
                st.ups = target_info
                st.env = target_info[2]
                st.va = cva
                st.limits = cp.limits or st.limits
                return target_entry
            end

            local rs = pack(f(unpack(S, fpos + 1, top)))
            if tail then
                return return_results(st, rs)
            end
            if st.limits.maxReturns and nres > st.limits.maxReturns then
                error("too many return values", 0)
            end
            top = push_results(S, fpos - 1, nres, rs)
            st.top = top
            if st.limits.maxStack and top > st.limits.maxStack then
                error("stack limit exceeded", 0)
            end
            return entries[block.nextpc]
        elseif op == 46 then
            local r = term.a
            local idx = tonumber(S[r])
            local limit = tonumber(S[r + 1])
            local step = tonumber(S[r + 2])
            if not idx or not limit or not step then
                error("'for' values must be numbers", 0)
            end
            S[r] = idx
            S[r + 1] = limit
            S[r + 2] = step
            if step == 0 then
                error("'for' step is zero", 0)
            end
            if (step > 0 and idx > limit) or
               (step < 0 and idx < limit) then
                return entries[term.b]
            end
            if loop_info then
                local cost = loop_info.cost or 1
                while true do
                    if st.max then
                        st.steps = st.steps + cost
                        if st.steps > st.max then
                            error("instruction limit exceeded", 0)
                        end
                    end
                    S[r] = idx
                    loop_info.body(S, idx)
                    idx = idx + step
                    if not ((step > 0 and idx <= limit) or
                            (step < 0 and idx >= limit)) then
                        break
                    end
                end
                return entries[loop_info.exit]
            end
            return entries[block.nextpc]
        else -- 47 FORLOOP
            local r = term.a
            local step = S[r + 2]
            local limit = S[r + 1]
            local idx = S[r] + step
            if (step > 0 and idx <= limit) or
               (step < 0 and idx >= limit) then
                S[r] = idx
                return entries[term.b]
            end
            return entries[block.nextpc]
        end
    end

    return block_closure
end

function closure_backend.build_program(proto)
    local n = proto.ncode or #proto.code
    local entry_pc = proto.entry or 1
    local entries, blocks, visiting = {}, {}, {}

    local function ensure(start)
        if entries[start] or visiting[start] then
            return true
        end
        if not start or start > n then
            return true
        end
        visiting[start] = true
        local block, err = closure_backend.scan_block(proto, start)
        if not block then
            visiting[start] = nil
            return nil, err
        end
        blocks[start] = block
        local term = block.ops[#block.ops]
        local op = term.op
        local function need(pc)
            if pc and pc <= n then
                return ensure(pc)
            end
            return true
        end
        local ok, e = true, nil
        if op == 34 then
            -- return
        elseif op == 32 then
            ok, e = need(term.a)
        elseif op == 31 or op == 29 or op == 30 or op == 51 then
            ok, e = need(term.a)
            if ok then ok, e = need(block.nextpc) end
        elseif op == 46 or op == 47 then
            ok, e = need(term.b)
            if ok then ok, e = need(block.nextpc) end
        elseif op == 33 then
            if term.c ~= 1 then
                ok, e = need(block.nextpc)
            end
        else
            ok, e = false, "unsupported terminator " .. tostring(op)
        end
        if not ok then
            visiting[start] = nil
            return nil, e
        end
        visiting[start] = nil
        return true
    end

    local ok, err = ensure(entry_pc)
    if not ok then
        return nil, err
    end

    -- Superinstruction fast path for `for i=1,n do acc=acc+i end`.
    -- Header initialization still runs in the header block; the whole loop
    -- body is then one direct closure instead of one block call per iteration.
    local loop_infos = {}
    for start, block in pairs(blocks) do
        local term = block.ops[#block.ops]
        local body = block.nextpc and blocks[block.nextpc]
        if term.op == 46 and body then
            local bt = body.ops[#body.ops]
            local o = body.ops
            if bt.op == 47 and bt.b == body.start and
               body.nextpc == term.b and #o == 8 and
               o[1].op == 4 and o[1].a == term.a and
               o[2].op == 5 and
               o[3].op == 50 and o[3].a == o[2].a and
               o[4].op == 4 and
               o[5].op == 4 and o[5].a == o[2].a and
               o[6].op == 13 and
               o[7].op == 5 and o[7].a == o[4].a then
                local acc = o[4].a
                local tmp = o[2].a
                if acc ~= term.a and acc ~= term.a + 1 and
                   acc ~= term.a + 2 and tmp ~= acc and tmp ~= term.a then
                    loop_infos[start] = {
                        exit = term.b,
                        cost = 7,
                        body = function(S, idx)
                            S[acc] = S[acc] + idx
                        end,
                    }
                end
            end
        end
    end

    for start, block in pairs(blocks) do
        local entry, berr = closure_backend.build_block_closure(
            proto, block, entries, loop_infos[start])
        if not entry then
            return nil, berr
        end
        entries[start] = entry
    end
    return entries[entry_pc]
end

local function chain_trace(proto, st)
    local p = st.proto or proto
    local frames = {}
    for i = 1, #st.frames do
        local fr = st.frames[i]
        frames[i] = { p = fr.p, pc = fr.pc, line = fr.line,
                      env = fr.env, not_main = true }
    end
    frames[#frames + 1] = {
        p = p,
        pc = st.pc or p.entry or 1,
        line = st.line,
        env = st.env,
        not_main = true,
    }
    return {
        [1] = st.pc or p.entry or 1,
        frames = frames,
        fi = #frames,
        cur = { p = p, env = st.env },
    }
end

function closure_backend.run_chain(proto, entry, upvals, ...)
    local args = pack(...)
    local limits = proto.limits or {}
    if limits.maxArgs and args.n > limits.maxArgs then
        error("too many arguments", 0)
    end
    if limits.maxStack and proto.maxreg > limits.maxStack then
        error("stack limit exceeded", 0)
    end
    local S = {}
    for i = 1, proto.numparams do
        S[i] = args[i]
    end
    for i = proto.numparams + 1, proto.maxreg do
        S[i] = nil
    end
    local va
    if proto.isvararg then
        local nv = args.n - proto.numparams
        if nv > 0 then
            va = { n = nv }
            for i = 1, nv do
                va[i] = args[proto.numparams + i]
            end
        end
    end
    local max = proto.limits and proto.limits.maxInstructions
    if max == math.huge then max = nil end
    local st = { S = S, top = proto.maxreg, ret = nil, nret = 0,
                 max = max, steps = 0, ups = upvals, va = va,
                 limits = limits, frames = {}, proto = proto,
                 env = (upvals and upvals[2]) or proto.env }
    local op = entry
    local ok, err = pcall(function()
        while op do
            op = op(st)
        end
    end)
    if not ok then
        error(sandbox_error(err, chain_trace(proto, st), true), 0)
    end
    if st.nret == 0 then
        return
    end
    return unpack(st.ret, 1, st.nret)
end

function closure_backend.run_block_chain(proto, entry, ...)
    return closure_backend.run_chain(proto, entry, nil, ...)
end

return {
    DEFAULT_LIMITS = DEFAULT_LIMITS,
    FOP = FOP,
    closure_info = closure_info,
    make_closure = make_closure,
    run_closure = run_closure,
    scan_block = closure_backend.scan_block,
    build_block_chain = closure_backend.build_block_chain,
    build_program = closure_backend.build_program,
    run_block_chain = closure_backend.run_block_chain,
}