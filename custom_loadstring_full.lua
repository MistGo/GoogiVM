--[[
  custom_loadstring_full.lua
  Полный Lua 5.1-совместимый компилятор/интерпретатор на чистом Lua.
  Без load/loadstring/ffi/debug/io/os.

  API:
    local custom_loadstring = dofile("custom_loadstring_full.lua")
    local chunk, err = custom_loadstring(source, env)

  Реализовано:
    - while, repeat/until, numeric for, generic for
    - varargs (...), nested functions, closures/upvalues
    - table constructors (nested, named/keyed/list fields)
    - multiple assignment and multiple returns
    - method calls/definitions, local function
    - all Lua 5.1 operators and native metamethod semantics
    - error on syntax: nil, "syntax error ..."

  Lua 5.1 не содержит побитовых операторов. Здесь реализованы все
  реальные операторы 5.1; побитовые функции при необходимости передаются
  через env (например, bit.band в LuaJIT).
]]

local str_find = string.find
local str_match = string.match
local str_sub = string.sub
local str_byte = string.byte
local str_char = string.char
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
local unpack = unpack or table.unpack

local function pack(...)
    return { n = select("#", ...), ... }
end

local closure_info = setmetatable({}, { __mode = "k" })

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

    ADD_ASSIGN_RR = 95, ADD_ASSIGN_RK = 96, ADD_ASSIGN_INDEX = 97,
    SUB_ASSIGN_RR = 98, SUB_ASSIGN_RK = 99,
    MUL_ASSIGN_RR = 100, MUL_ASSIGN_RK = 101,

    JMPF_LOCAL = 102, JMPNIL_LOCAL = 103,
    JMPF_EQ_K = 104, JMPF_NE_K = 105,
    JMPF_LT_K = 106, JMPF_LE_K = 107,
    JMPF_GT_K = 108, JMPF_GE_K = 109,

    FORLOOP_MOV = 110, FORLOOP_CELL = 111,
}

local run_closure

local function make_closure(proto, upvals, fenv)
    local function closure(...)
        return run_closure(closure, ...)
    end
    local env = fenv or proto.env
    local native_env = false
    if setfenv then
        native_env = pcall(setfenv, closure, env)
    end
    closure_info[closure] = {
        p = proto, u = upvals, env = env, fenv = native_env,
    }
    return closure
end

local function get_closure_env(fn)
    local info = closure_info[fn]
    if not info then
        return nil
    end
    if info.fenv and getfenv then
        return getfenv(fn)
    end
    return info.env
end

local function set_closure_env(fn, newenv)
    local info = closure_info[fn]
    if not info then
        return false
    end
    info.env = newenv
    if info.fenv and setfenv then
        info.fenv = pcall(setfenv, fn, newenv)
    end
    return true
end

run_closure = function(fn, ...)
    local LOADK, LOADBOOL, LOADNIL = 1, 2, 3
    local GETLOCAL, SETLOCAL, GETCELL, SETCELL, CELL = 4, 5, 6, 7, 8
    local GETUPVAL, SETUPVAL, GETGLOBAL, SETGLOBAL = 9, 10, 11, 12
    local ADD, SUB, MUL, DIV, MOD, POW = 13, 14, 15, 16, 17, 18
    local CONCAT, UNM, NOT, LEN = 19, 20, 21, 22
    local EQ, NE, LT, LE, GT, GE = 23, 24, 25, 26, 27, 28
    local TESTF, TESTT, JMPF, JMP, CALLD = 29, 30, 31, 32, 33
    local RET, VARARG, NEWTABLE, FIELD, INDEX = 34, 35, 36, 37, 38
    local SETFIELD, SETINDEX, SELF, SETLIST, SETLISTMULTI = 39, 40, 41, 42, 43
    local MARK, POP, FORPREP, FORLOOP, CLOSURE = 44, 45, 46, 47, 48
    local PEEK, NOP, JMPNIL = 49, 50, 51

    local F_MOVLOCAL, F_MOVLOCAL_NOP, F_MOVLOCAL_CELL = 52, 53, 54
    local F_SETLOCAL_K, F_SETLOCAL_INDEX, F_SETLOCAL_FIELD = 55, 56, 57
    local F_ADD_RR, F_ADD_RK, F_SUB_RR, F_SUB_RK = 58, 59, 60, 61
    local F_MUL_RR, F_MUL_RK, F_DIV_RR, F_DIV_RK = 62, 63, 64, 65
    local F_MOD_RR, F_MOD_RK, F_POW_RR, F_POW_RK = 66, 67, 68, 69
    local F_EQ_RR, F_EQ_RK, F_NE_RR, F_NE_RK = 70, 71, 72, 73
    local F_LT_RR, F_LT_RK, F_LE_RR, F_LE_RK = 74, 75, 76, 77
    local F_GT_RR, F_GT_RK, F_GE_RR, F_GE_RK = 78, 79, 80, 81
    local F_EQ_K, F_NE_K, F_LT_K, F_LE_K = 82, 83, 84, 85
    local F_GT_K, F_GE_K = 86, 87
    local F_INDEX_RR, F_INDEX_RK, F_FIELD_R = 88, 89, 90
    local F_SETINDEX_RR, F_SETINDEX_RK = 91, 92
    local F_SETFIELD_RV, F_SETFIELD_RK = 93, 94
    local F_ADD_ASSIGN_RR, F_ADD_ASSIGN_RK, F_ADD_ASSIGN_INDEX = 95, 96, 97
    local F_SUB_ASSIGN_RR, F_SUB_ASSIGN_RK = 98, 99
    local F_MUL_ASSIGN_RR, F_MUL_ASSIGN_RK = 100, 101
    local F_JMPF_LOCAL, F_JMPNIL_LOCAL = 102, 103
    local F_JMPF_EQ_K, F_JMPF_NE_K = 104, 105
    local F_JMPF_LT_K, F_JMPF_LE_K = 106, 107
    local F_JMPF_GT_K, F_JMPF_GE_K = 108, 109
    local F_FORLOOP_MOV, F_FORLOOP_CELL = 110, 111

    local info = closure_info[fn]
    local p = info.p
    local args = pack(...)
    local nargs = args.n

    local S = {}
    local top = 0
    local frames = {}
    local fi = 1

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

    local cenv = info.env
    if info.fenv and getfenv then
        cenv = getfenv(fn)
    end

    local cur = {
        p = p, ups = info.u, base = base, pc = 1,
        ret_sp = 0, wanted = -1, va = va, env = cenv, cl = fn,
    }
    frames[1] = cur

    local C = p.code
    local K = p.consts
    local U = info.u
    local e = cenv
    local pc = 1

    while true do
        local op = C[pc]

        if op >= 52 then
            -- Fast-path ordering for the hottest fused opcodes.
            if op == F_MOD_RK then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] % K[C[pc + 2]]
                pc = pc + 12

            elseif op == F_JMPF_EQ_K then
                local v = S[top]
                S[top] = nil
                top = top - 1
                if not (v == K[C[pc + 1]]) then
                    pc = C[pc + 2]
                else
                    pc = pc + 12
                end

            elseif op == F_FORLOOP_MOV then
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

            elseif op == F_FORLOOP_CELL then
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

            elseif op == F_ADD_ASSIGN_RR then
                local a = base + C[pc + 1] - 1
                local b = base + C[pc + 2] - 1
                S[a] = S[a] + S[b]
                pc = pc + 16

            elseif op == F_ADD_ASSIGN_RK then
                local a = base + C[pc + 1] - 1
                S[a] = S[a] + K[C[pc + 2]]
                pc = pc + 16

            elseif op == F_ADD_ASSIGN_INDEX then
                local a = base + C[pc + 1] - 1
                local t = S[base + C[pc + 2] - 1]
                local k = S[base + C[pc + 3] - 1]
                S[a] = S[a] + t[k]
                pc = pc + 24

            elseif op == F_SUB_ASSIGN_RR then
                local a = base + C[pc + 1] - 1
                local b = base + C[pc + 2] - 1
                S[a] = S[a] - S[b]
                pc = pc + 16

            elseif op == F_SUB_ASSIGN_RK then
                local a = base + C[pc + 1] - 1
                S[a] = S[a] - K[C[pc + 2]]
                pc = pc + 16

            elseif op == F_MUL_ASSIGN_RR then
                local a = base + C[pc + 1] - 1
                local b = base + C[pc + 2] - 1
                S[a] = S[a] * S[b]
                pc = pc + 16

            elseif op == F_MUL_ASSIGN_RK then
                local a = base + C[pc + 1] - 1
                S[a] = S[a] * K[C[pc + 2]]
                pc = pc + 16

            elseif op == F_MOVLOCAL_NOP then
                S[base + C[pc + 1] - 1] = S[base + C[pc + 2] - 1]
                pc = pc + 12

            elseif op == F_MOVLOCAL_CELL then
                S[base + C[pc + 1] - 1] =
                    { v = S[base + C[pc + 2] - 1] }
                pc = pc + 12

            elseif op == F_MOVLOCAL then
                S[base + C[pc + 1] - 1] = S[base + C[pc + 2] - 1]
                pc = pc + 8

            elseif op == F_SETINDEX_RR then
                local t = S[base + C[pc + 1] - 1]
                local k = S[base + C[pc + 2] - 1]
                t[k] = S[base + C[pc + 3] - 1]
                pc = pc + 24

            elseif op == F_SETINDEX_RK then
                local t = S[base + C[pc + 1] - 1]
                local k = S[base + C[pc + 2] - 1]
                t[k] = K[C[pc + 3]]
                pc = pc + 24

            elseif op == F_SETFIELD_RV then
                local t = S[base + C[pc + 1] - 1]
                t[K[C[pc + 2]]] = S[base + C[pc + 3] - 1]
                pc = pc + 16

            elseif op == F_SETFIELD_RK then
                local t = S[base + C[pc + 1] - 1]
                t[K[C[pc + 2]]] = K[C[pc + 3]]
                pc = pc + 16

            elseif op == F_SETLOCAL_INDEX then
                local dest = base + C[pc + 1] - 1
                local t = S[base + C[pc + 2] - 1]
                local k = S[base + C[pc + 3] - 1]
                S[dest] = t[k]
                pc = pc + 16

            elseif op == F_SETLOCAL_FIELD then
                local dest = base + C[pc + 1] - 1
                local t = S[base + C[pc + 2] - 1]
                S[dest] = t[K[C[pc + 3]]]
                pc = pc + 12

            elseif op == F_SETLOCAL_K then
                S[base + C[pc + 1] - 1] = K[C[pc + 2]]
                pc = pc + 8

            elseif op == F_INDEX_RR then
                local t = S[base + C[pc + 1] - 1]
                local k = S[base + C[pc + 2] - 1]
                top = top + 1
                S[top] = t[k]
                pc = pc + 12

            elseif op == F_INDEX_RK then
                local t = S[base + C[pc + 1] - 1]
                top = top + 1
                S[top] = t[K[C[pc + 2]]]
                pc = pc + 12

            elseif op == F_FIELD_R then
                local t = S[base + C[pc + 1] - 1]
                top = top + 1
                S[top] = t[K[C[pc + 2]]]
                pc = pc + 8

            elseif op == F_ADD_RR then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] + S[base + C[pc + 2] - 1]
                pc = pc + 12

            elseif op == F_ADD_RK then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] + K[C[pc + 2]]
                pc = pc + 12

            elseif op == F_SUB_RR then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] - S[base + C[pc + 2] - 1]
                pc = pc + 12

            elseif op == F_SUB_RK then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] - K[C[pc + 2]]
                pc = pc + 12

            elseif op == F_MUL_RR then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] * S[base + C[pc + 2] - 1]
                pc = pc + 12

            elseif op == F_MUL_RK then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] * K[C[pc + 2]]
                pc = pc + 12

            elseif op == F_DIV_RR then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] / S[base + C[pc + 2] - 1]
                pc = pc + 12

            elseif op == F_DIV_RK then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] / K[C[pc + 2]]
                pc = pc + 12

            elseif op == F_MOD_RR then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] % S[base + C[pc + 2] - 1]
                pc = pc + 12

            elseif op == F_MOD_RK then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] % K[C[pc + 2]]
                pc = pc + 12

            elseif op == F_POW_RR then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] ^ S[base + C[pc + 2] - 1]
                pc = pc + 12

            elseif op == F_POW_RK then
                top = top + 1
                S[top] = S[base + C[pc + 1] - 1] ^ K[C[pc + 2]]
                pc = pc + 12

            elseif op == F_EQ_RR then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] == S[base + C[pc + 2] - 1])
                pc = pc + 12

            elseif op == F_EQ_RK then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] == K[C[pc + 2]])
                pc = pc + 12

            elseif op == F_NE_RR then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] ~= S[base + C[pc + 2] - 1])
                pc = pc + 12

            elseif op == F_NE_RK then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] ~= K[C[pc + 2]])
                pc = pc + 12

            elseif op == F_LT_RR then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] < S[base + C[pc + 2] - 1])
                pc = pc + 12

            elseif op == F_LT_RK then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] < K[C[pc + 2]])
                pc = pc + 12

            elseif op == F_LE_RR then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] <= S[base + C[pc + 2] - 1])
                pc = pc + 12

            elseif op == F_LE_RK then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] <= K[C[pc + 2]])
                pc = pc + 12

            elseif op == F_GT_RR then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] > S[base + C[pc + 2] - 1])
                pc = pc + 12

            elseif op == F_GT_RK then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] > K[C[pc + 2]])
                pc = pc + 12

            elseif op == F_GE_RR then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] >= S[base + C[pc + 2] - 1])
                pc = pc + 12

            elseif op == F_GE_RK then
                top = top + 1
                S[top] = (S[base + C[pc + 1] - 1] >= K[C[pc + 2]])
                pc = pc + 12

            elseif op == F_EQ_K then
                S[top] = (S[top] == K[C[pc + 1]])
                pc = pc + 8

            elseif op == F_NE_K then
                S[top] = (S[top] ~= K[C[pc + 1]])
                pc = pc + 8

            elseif op == F_LT_K then
                S[top] = (S[top] < K[C[pc + 1]])
                pc = pc + 8

            elseif op == F_LE_K then
                S[top] = (S[top] <= K[C[pc + 1]])
                pc = pc + 8

            elseif op == F_GT_K then
                S[top] = (S[top] > K[C[pc + 1]])
                pc = pc + 8

            elseif op == F_GE_K then
                S[top] = (S[top] >= K[C[pc + 1]])
                pc = pc + 8

            elseif op == F_JMPF_LOCAL then
                if not S[base + C[pc + 1] - 1] then
                    pc = C[pc + 2]
                else
                    pc = pc + 8
                end

            elseif op == F_JMPNIL_LOCAL then
                if S[base + C[pc + 1] - 1] == nil then
                    pc = C[pc + 2]
                else
                    pc = pc + 8
                end

            elseif op == F_JMPF_EQ_K then
                local v = S[top]
                S[top] = nil
                top = top - 1
                if not (v == K[C[pc + 1]]) then
                    pc = C[pc + 2]
                else
                    pc = pc + 12
                end

            elseif op == F_JMPF_NE_K then
                local v = S[top]
                S[top] = nil
                top = top - 1
                if not (v ~= K[C[pc + 1]]) then
                    pc = C[pc + 2]
                else
                    pc = pc + 12
                end

            elseif op == F_JMPF_LT_K then
                local v = S[top]
                S[top] = nil
                top = top - 1
                if not (v < K[C[pc + 1]]) then
                    pc = C[pc + 2]
                else
                    pc = pc + 12
                end

            elseif op == F_JMPF_LE_K then
                local v = S[top]
                S[top] = nil
                top = top - 1
                if not (v <= K[C[pc + 1]]) then
                    pc = C[pc + 2]
                else
                    pc = pc + 12
                end

            elseif op == F_JMPF_GT_K then
                local v = S[top]
                S[top] = nil
                top = top - 1
                if not (v > K[C[pc + 1]]) then
                    pc = C[pc + 2]
                else
                    pc = pc + 12
                end

            elseif op == F_JMPF_GE_K then
                local v = S[top]
                S[top] = nil
                top = top - 1
                if not (v >= K[C[pc + 1]]) then
                    pc = C[pc + 2]
                else
                    pc = pc + 12
                end

            else
                error("bad fused bytecode", 0)
            end

        elseif op == LOADK then
            local k = K[C[pc + 1]]
            top = top + 1
            S[top] = k
            pc = pc + 4

        elseif op == LOADBOOL then
            top = top + 1
            S[top] = (C[pc + 1] == 1)
            pc = pc + 4

        elseif op == LOADNIL then
            local n = C[pc + 1]
            for i = 1, n do
                top = top + 1
                S[top] = nil
            end
            pc = pc + 4

        elseif op == GETLOCAL then
            top = top + 1
            S[top] = S[base + C[pc + 1] - 1]
            pc = pc + 4

        elseif op == SETLOCAL then
            S[base + C[pc + 1] - 1] = S[top]
            S[top] = nil
            top = top - 1
            pc = pc + 4

        elseif op == GETCELL then
            local cell = S[base + C[pc + 1] - 1]
            top = top + 1
            S[top] = cell.v
            pc = pc + 4

        elseif op == SETCELL then
            local cell = S[base + C[pc + 1] - 1]
            cell.v = S[top]
            S[top] = nil
            top = top - 1
            pc = pc + 4

        elseif op == CELL then
            local i = base + C[pc + 1] - 1
            S[i] = { v = S[i] }
            pc = pc + 4

        elseif op == GETUPVAL then
            top = top + 1
            S[top] = U[C[pc + 1]].v
            pc = pc + 4

        elseif op == SETUPVAL then
            U[C[pc + 1]].v = S[top]
            S[top] = nil
            top = top - 1
            pc = pc + 4

        elseif op == GETGLOBAL then
            top = top + 1
            S[top] = e[K[C[pc + 1]]]
            pc = pc + 4

        elseif op == SETGLOBAL then
            e[K[C[pc + 1]]] = S[top]
            S[top] = nil
            top = top - 1
            pc = pc + 4

        elseif op == ADD then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = a + b
            pc = pc + 4

        elseif op == SUB then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = a - b
            pc = pc + 4

        elseif op == MUL then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = a * b
            pc = pc + 4

        elseif op == DIV then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = a / b
            pc = pc + 4

        elseif op == MOD then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = a % b
            pc = pc + 4

        elseif op == POW then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = a ^ b
            pc = pc + 4

        elseif op == CONCAT then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = a .. b
            pc = pc + 4

        elseif op == UNM then
            S[top] = -S[top]
            pc = pc + 4

        elseif op == NOT then
            S[top] = not S[top]
            pc = pc + 4

        elseif op == LEN then
            S[top] = #S[top]
            pc = pc + 4

        elseif op == EQ then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = (a == b)
            pc = pc + 4

        elseif op == NE then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = (a ~= b)
            pc = pc + 4

        elseif op == LT then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = (a < b)
            pc = pc + 4

        elseif op == LE then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = (a <= b)
            pc = pc + 4

        elseif op == GT then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = (a > b)
            pc = pc + 4

        elseif op == GE then
            local b = S[top]
            local a = S[top - 1]
            S[top] = nil
            top = top - 1
            S[top] = (a >= b)
            pc = pc + 4

        elseif op == TESTF then
            if not S[top] then
                pc = C[pc + 1]
            else
                S[top] = nil
                top = top - 1
                pc = pc + 4
            end

        elseif op == TESTT then
            if S[top] then
                pc = C[pc + 1]
            else
                S[top] = nil
                top = top - 1
                pc = pc + 4
            end

        elseif op == JMPF then
            local v = S[top]
            S[top] = nil
            top = top - 1
            if not v then
                pc = C[pc + 1]
            else
                pc = pc + 4
            end

        elseif op == JMPNIL then
            local v = S[top]
            S[top] = nil
            top = top - 1
            if v == nil then
                pc = C[pc + 1]
            else
                pc = pc + 4
            end

        elseif op == JMP then
            pc = C[pc + 1]

        elseif op == CALLD then
            local mreg = C[pc + 1]
            local nres = C[pc + 2]
            local fpos = S[base + mreg - 1]
            local f = S[fpos]
            local nargs = top - fpos
            local ret_sp = fpos - 1
            local fci = closure_info[f]

            if fci then
                local cp = fci.p
                local cpups = fci.u
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

                local cenv = fci.env
                if fci.fenv and getfenv then
                    cenv = getfenv(f)
                end

                cur.pc = pc + 4
                frames[fi] = cur
                cur = {
                    p = cp, ups = cpups, base = fpos, pc = 1,
                    ret_sp = ret_sp, wanted = nres, va = cva,
                    env = cenv, cl = f,
                }
                fi = fi + 1
                frames[fi] = cur

                p = cp
                C = cp.code
                K = cp.consts
                U = cpups
                e = cenv
                base = fpos
                maxreg = cmax
                va = cva
                pc = 1
                top = fpos + cmax - 1
            else
                if getfenv and f == getfenv then
                    local arg
                    if nargs == 0 then
                        arg = 1
                    else
                        arg = S[fpos + 1]
                    end
                    local r
                    if type(arg) == "number" then
                        local lvl = arg
                        if lvl == 0 then
                            r = e
                        elseif lvl < 0 then
                            error("bad argument #1 to 'getfenv' (invalid level)", 0)
                        else
                            local idx = fi - lvl + 1
                            if idx < 1 then
                                error("bad argument #1 to 'getfenv' (invalid level)", 0)
                            end
                            r = frames[idx].env
                        end
                    elseif type(arg) == "function" then
                        local inf = closure_info[arg]
                        if inf then
                            r = get_closure_env(arg)
                        else
                            r = getfenv(arg)
                        end
                    else
                        error("bad argument #1 to 'getfenv' (number or function expected)", 0)
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
                elseif setfenv and f == setfenv then
                    if nargs < 2 then
                        error("bad argument count to 'setfenv'", 0)
                    end
                    local target = S[fpos + 1]
                    local newenv = S[fpos + 2]
                    if type(newenv) ~= "table" then
                        error("bad argument #2 to 'setfenv' (table expected)", 0)
                    end
                    local r
                    if type(target) == "number" then
                        local lvl = target
                        if lvl <= 0 then
                            error("cannot change environment of thread", 0)
                        end
                        local idx = fi - lvl + 1
                        if idx < 1 then
                            error("invalid level", 0)
                        end
                        local fr = frames[idx]
                        set_closure_env(fr.cl, newenv)
                        for j = 1, fi do
                            if frames[j].cl == fr.cl then
                                frames[j].env = newenv
                                if j == fi then
                                    e = newenv
                                end
                            end
                        end
                        r = fr.cl
                    elseif type(target) == "function" then
                        if closure_info[target] then
                            set_closure_env(target, newenv)
                            for j = 1, fi do
                                if frames[j].cl == target then
                                    frames[j].env = newenv
                                    if j == fi then
                                        e = newenv
                                    end
                                end
                            end
                        else
                            setfenv(target, newenv)
                        end
                        r = target
                    else
                        error("bad argument #1 to 'setfenv' (number or function expected)", 0)
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
                else
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
                pc = pc + 4
            end

        elseif op == RET then
            local n = C[pc + 1]
            local exprbase = base + maxreg
            local nret
            if n < 0 then
                nret = top - (exprbase - 1)
            else
                nret = n
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

            frames[fi] = nil
            fi = fi - 1
            if fi == 0 then
                if top == 0 then
                    return
                end
                return unpack(S, 1, top)
            end

            cur = frames[fi]
            p = cur.p
            C = p.code
            K = p.consts
            U = cur.ups
            e = cur.env
            base = cur.base
            maxreg = p.maxreg
            va = cur.va
            pc = cur.pc

        elseif op == VARARG then
            local nres = C[pc + 1]
            local n = va and va.n or 0
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

        elseif op == NEWTABLE then
            top = top + 1
            S[top] = {}
            pc = pc + 4

        elseif op == FIELD then
            local t = S[top]
            S[top] = t[K[C[pc + 1]]]
            pc = pc + 4

        elseif op == INDEX then
            local key = S[top]
            S[top] = nil
            top = top - 1
            local t = S[top]
            S[top] = t[key]
            pc = pc + 4

        elseif op == SETFIELD then
            local val = S[top]
            S[top] = nil
            top = top - 1
            local t = S[base + C[pc + 1] - 1]
            t[K[C[pc + 2]]] = val
            pc = pc + 4

        elseif op == SETINDEX then
            local val = S[top]
            S[top] = nil
            top = top - 1
            local t = S[base + C[pc + 1] - 1]
            local key = S[base + C[pc + 2] - 1]
            t[key] = val
            pc = pc + 4

        elseif op == SELF then
            local t = S[top]
            S[top] = t[K[C[pc + 1]]]
            top = top + 1
            S[top] = t
            pc = pc + 4

        elseif op == SETLIST then
            local val = S[top]
            S[top] = nil
            top = top - 1
            local t = S[base + C[pc + 1] - 1]
            t[C[pc + 2]] = val
            pc = pc + 4

        elseif op == SETLISTMULTI then
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

        elseif op == MARK then
            S[base + C[pc + 1] - 1] = top - C[pc + 2]
            pc = pc + 4

        elseif op == POP then
            local n = C[pc + 1]
            for j = 1, n do
                S[top] = nil
                top = top - 1
            end
            pc = pc + 4

        elseif op == FORPREP then
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

        elseif op == FORLOOP then
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

        elseif op == CLOSURE then
            local cp = p.protos[C[pc + 1]]
            local ud = cp.updesc
            local ups = {}
            for j = 1, #ud do
                local d = ud[j]
                if d.instack == 1 then
                    ups[j] = S[base + d.idx - 1]
                else
                    ups[j] = U[d.idx]
                end
            end
            top = top + 1
            S[top] = make_closure(cp, ups, e)
            pc = pc + 4

        elseif op == PEEK then
            S[base + C[pc + 1] - 1] = S[top - C[pc + 2]]
            pc = pc + 4

        elseif op == NOP then
            pc = pc + 4

        else
            error("bad bytecode", 0)
        end
    end
end

local function custom_loadstring(source, env)
    if type(source) ~= "string" then
        return nil, "script must be a string"
    end
    if env == nil then
        env = {}
    elseif type(env) ~= "table" then
        return nil, "environment must be a table"
    end

    local function compile()
        local len = #source
        local pos = 1
        local tk = ""
        local tv = nil
        local tp = 1

        local LOADK, LOADBOOL, LOADNIL = 1, 2, 3
        local GETLOCAL, SETLOCAL, GETCELL, SETCELL, CELL = 4, 5, 6, 7, 8
        local GETUPVAL, SETUPVAL, GETGLOBAL, SETGLOBAL = 9, 10, 11, 12
        local ADD, SUB, MUL, DIV, MOD, POW = 13, 14, 15, 16, 17, 18
        local CONCAT, UNM, NOT, LEN = 19, 20, 21, 22
        local EQ, NE, LT, LE, GT, GE = 23, 24, 25, 26, 27, 28
        local TESTF, TESTT, JMPF, JMP, CALLD = 29, 30, 31, 32, 33
        local RET, VARARG, NEWTABLE, FIELD, INDEX = 34, 35, 36, 37, 38
        local SETFIELD, SETINDEX, SELF, SETLIST, SETLISTMULTI = 39, 40, 41, 42, 43
        local MARK, POP, FORPREP, FORLOOP, CLOSURE = 44, 45, 46, 47, 48
        local PEEK, NOP, JMPNIL = 49, 50, 51

        local KWS = {
            ["and"] = true, ["break"] = true, ["do"] = true,
            ["else"] = true, ["elseif"] = true, ["end"] = true,
            ["false"] = true, ["for"] = true, ["function"] = true,
            ["if"] = true, ["in"] = true, ["local"] = true,
            ["nil"] = true, ["not"] = true, ["or"] = true,
            ["repeat"] = true, ["return"] = true, ["then"] = true,
            ["true"] = true, ["until"] = true, ["while"] = true,
        }

        local function line_of(p)
            local line = 1
            local i = 1
            while true do
                local n = str_find(source, "[\r\n]", i)
                if not n or n >= p then
                    return line
                end
                line = line + 1
                if str_sub(source, n, n) == "\r" and
                   str_sub(source, n + 1, n + 1) == "\n" then
                    i = n + 2
                else
                    i = n + 1
                end
            end
        end

        local function near()
            if tk == "eof" then
                return "<eof>"
            end
            local s = tostring(tv or tk)
            if #s > 40 then
                s = str_sub(s, 1, 37) .. "..."
            end
            return s
        end

        local function fail(msg)
            error("syntax error at line " .. line_of(tp) ..
                  " near '" .. near() .. "': " .. msg, 0)
        end

        local function long_open(p)
            local eq = str_match(source, "^%[(=*)%[", p)
            if eq ~= nil then
                return p + #eq + 2, eq
            end
            return nil, nil
        end

        local function skip_space()
            while true do
                local p = str_find(source, "[^ \t\r\n\f\v]", pos)
                if not p then
                    pos = len + 1
                    return
                end
                pos = p
                if str_sub(source, p, p) == "-" and
                   str_sub(source, p + 1, p + 1) == "-" then
                    local q = p + 2
                    local content, eq = long_open(q)
                    if content then
                        local close = str_find(source, "]" .. eq .. "]", content, true)
                        if not close then
                            tp = p
                            tv = "--"
                            fail("unfinished long comment")
                        end
                        pos = close + #eq + 2
                    else
                        local nl = str_find(source, "[\r\n]", q)
                        if not nl then
                            pos = len + 1
                            return
                        end
                        if str_sub(source, nl, nl) == "\r" and
                           str_sub(source, nl + 1, nl + 1) == "\n" then
                            pos = nl + 2
                        else
                            pos = nl + 1
                        end
                    end
                else
                    return
                end
            end
        end

        local esc = {
            a = "\a", b = "\b", f = "\f", n = "\n",
            r = "\r", t = "\t", v = "\v",
            ["\\"] = "\\", ['"'] = '"', ["'"] = "'",
        }

        local function read_string()
            local quote = str_sub(source, pos, pos)
            local p = pos + 1
            local start = p
            local parts = nil
            local pat = quote == '"' and '[\\"\r\n]' or "[\\'\r\n]"
            while true do
                local f = str_find(source, pat, p)
                if not f then
                    tp = pos
                    tv = quote
                    fail("unfinished string")
                end
                local ch = str_sub(source, f, f)
                if ch == quote then
                    local piece = str_sub(source, start, f - 1)
                    if parts then
                        parts[#parts + 1] = piece
                        tv = tconcat(parts)
                    else
                        tv = piece
                    end
                    pos = f + 1
                    tk = "string"
                    return
                elseif ch == "\n" or ch == "\r" then
                    tp = pos
                    tv = quote
                    fail("unfinished string")
                end

                local piece = str_sub(source, start, f - 1)
                if not parts then
                    parts = { piece }
                else
                    parts[#parts + 1] = piece
                end

                local e = str_sub(source, f + 1, f + 1)
                local rep = esc[e]
                if rep ~= nil then
                    parts[#parts + 1] = rep
                    p = f + 2
                elseif e == "\n" then
                    parts[#parts + 1] = "\n"
                    p = f + 2
                elseif e == "\r" then
                    parts[#parts + 1] = "\n"
                    if str_sub(source, f + 2, f + 2) == "\n" then
                        p = f + 3
                    else
                        p = f + 2
                    end
                elseif e >= "0" and e <= "9" then
                    local ds = str_match(source, "^%d%d?%d?", f + 1)
                    local n = tonumber(ds)
                    if n > 255 then
                        tp = f + 1
                        tv = ds
                        fail("decimal escape too large")
                    end
                    parts[#parts + 1] = str_char(n)
                    p = f + 1 + #ds
                else
                    tp = f + 1
                    tv = e
                    fail("invalid escape sequence")
                end
                start = p
            end
        end

        local function read_long_string()
            local start, eq = long_open(pos)
            local close = str_find(source, "]" .. eq .. "]", start, true)
            if not close then
                tp = pos
                tv = "["
                fail("unfinished long string")
            end
            local s = str_sub(source, start, close - 1)
            if str_sub(s, 1, 2) == "\r\n" then
                s = str_sub(s, 3)
            elseif str_sub(s, 1, 1) == "\n" or
                   str_sub(s, 1, 1) == "\r" then
                s = str_sub(s, 2)
            end
            pos = close + #eq + 2
            tk = "string"
            tv = s
        end

        local function read_number()
            local p = pos
            local c = str_sub(source, p, p)
            local q

            if c == "0" then
                local c2 = str_sub(source, p + 1, p + 1)
                if c2 == "x" or c2 == "X" then
                    q = str_find(source, "[^%x]", p + 2) or (len + 1)
                    local s = str_sub(source, p, q - 1)
                    local n = tonumber(str_sub(s, 3), 16)
                    if not n then
                        tp = p
                        tv = s
                        fail("malformed number")
                    end
                    pos = q
                    tk = "number"
                    tv = n
                    return
                end
            end

            if c == "." then
                q = str_find(source, "[^%d]", p + 1) or (len + 1)
            else
                q = str_find(source, "[^%d]", p) or (len + 1)
                if str_sub(source, q, q) == "." and
                   str_sub(source, q + 1, q + 1) ~= "." then
                    q = str_find(source, "[^%d]", q + 1) or (len + 1)
                end
            end

            local e = str_sub(source, q, q)
            if e == "e" or e == "E" then
                local ep = q + 1
                local sign = str_sub(source, ep, ep)
                if sign == "+" or sign == "-" then
                    ep = ep + 1
                end
                local d = str_sub(source, ep, ep)
                if d >= "0" and d <= "9" then
                    q = str_find(source, "[^%d]", ep) or (len + 1)
                end
            end

            local s = str_sub(source, p, q - 1)
            local n = tonumber(s)
            if not n then
                tp = p
                tv = s
                fail("malformed number")
            end
            pos = q
            tk = "number"
            tv = n
        end

        local function advance()
            skip_space()
            tp = pos
            if pos > len then
                tk = "eof"
                tv = nil
                return
            end

            local c = str_sub(source, pos, pos)

            if c == "_" or (c >= "a" and c <= "z") or
               (c >= "A" and c <= "Z") then
                local name = str_match(source, "^[%a_][%w_]*", pos)
                pos = pos + #name
                tv = name
                if KWS[name] then
                    tk = name
                else
                    tk = "name"
                end
                return
            end

            local b = str_byte(source, pos)
            if (b >= 48 and b <= 57) or
               (c == "." and str_sub(source, pos + 1, pos + 1) >= "0" and
                str_sub(source, pos + 1, pos + 1) <= "9") then
                read_number()
                return
            end

            if c == '"' or c == "'" then
                read_string()
                return
            end

            if c == "[" then
                local content = long_open(pos)
                if content then
                    read_long_string()
                    return
                end
            end

            local c2 = str_sub(source, pos + 1, pos + 1)
            local c3 = str_sub(source, pos + 2, pos + 2)
            if c == "." and c2 == "." and c3 == "." then
                tk = "..."
                tv = "..."
                pos = pos + 3
                return
            end
            if (c == "=" and c2 == "=") or
               (c == "~" and c2 == "=") or
               (c == "<" and c2 == "=") or
               (c == ">" and c2 == "=") or
               (c == "." and c2 == ".") then
                tk = c .. c2
                tv = tk
                pos = pos + 2
                return
            end

            if c == "+" or c == "-" or c == "*" or c == "/" or c == "%" or
               c == "^" or c == "#" or c == "<" or c == ">" or c == "=" or
               c == "(" or c == ")" or c == "[" or c == "]" or c == "{" or
               c == "}" or c == ";" or c == ":" or c == "," or c == "." then
                tk = c
                tv = c
                pos = pos + 1
                return
            end

            tv = c
            fail("unexpected character")
        end

        local function accept(kind)
            if tk == kind then
                advance()
                return true
            end
            return false
        end

        local function expect(kind)
            if tk ~= kind then
                fail("'" .. kind .. "' expected")
            end
            advance()
        end

        local all_protos = {}
        local fc

        local function new_fc(parent, isvararg, numparams)
            return {
                parent = parent,
                code = {}, ncode = 0,
                consts = {}, cmap = {}, kcount = 0,
                locals = {}, nlocals = 0,
                upvals = {},
                nextreg = 0, maxreg = 0,
                isvararg = isvararg, numparams = numparams,
                loop_depth = 0, loop_breaks = {},
            }
        end

        local function emit(op, a, b, c)
            local i = fc.ncode + 1
            local co = fc.code
            co[i] = op
            co[i + 1] = a or 0
            co[i + 2] = b or 0
            co[i + 3] = c or 0
            fc.ncode = i + 3
            return i
        end

        local function here()
            return fc.ncode + 1
        end

        local function patch_target(ins, target)
            fc.code[ins + 1] = target
        end

        local function patch_b(ins, target)
            fc.code[ins + 2] = target
        end

        local function patch_nres(ins, nres)
            if fc.code[ins] == VARARG then
                fc.code[ins + 1] = nres
            else
                fc.code[ins + 2] = nres
            end
        end

        local function addk(v)
            local idx = fc.cmap[v]
            if idx then
                return idx
            end
            idx = fc.kcount + 1
            fc.kcount = idx
            fc.consts[idx] = v
            fc.cmap[v] = idx
            return idx
        end

        local function reserve_reg()
            local r = fc.nextreg + 1
            fc.nextreg = r
            if r > fc.maxreg then
                fc.maxreg = r
            end
            return r
        end

        local function find_local(f, name)
            for i = f.nlocals, 1, -1 do
                local d = f.locals[i]
                if d.name == name then
                    return d
                end
            end
            return nil
        end

        local function mark_captured(desc)
            if desc.captured then
                return
            end
            desc.captured = true
            local f = desc.fc
            local co = f.code
            if desc.cell_pc then
                co[desc.cell_pc] = CELL
            end
            local acc = desc.access
            for i = 1, #acc do
                local p = acc[i]
                local op = co[p]
                if op == GETLOCAL then
                    co[p] = GETCELL
                elseif op == SETLOCAL then
                    co[p] = SETCELL
                end
            end
        end

        local function new_local(name)
            local d = {
                name = name,
                slot = reserve_reg(),
                captured = false,
                cell_pc = nil,
                access = {},
                fc = fc,
            }
            fc.nlocals = fc.nlocals + 1
            fc.locals[fc.nlocals] = d
            return d
        end

        local function emit_cell(desc)
            local p = emit(NOP, desc.slot, 0, 0)
            desc.cell_pc = p
            return p
        end

        local function emit_local_get(desc)
            local p
            if desc.captured then
                p = emit(GETCELL, desc.slot, 0, 0)
            else
                p = emit(GETLOCAL, desc.slot, 0, 0)
            end
            desc.access[#desc.access + 1] = p
            return p
        end

        local function emit_local_set(desc)
            local p
            if desc.captured then
                p = emit(SETCELL, desc.slot, 0, 0)
            else
                p = emit(SETLOCAL, desc.slot, 0, 0)
            end
            desc.access[#desc.access + 1] = p
            return p
        end

        local function find_upval(f, name)
            for i = 1, #f.upvals do
                if f.upvals[i].name == name then
                    return i
                end
            end
            return nil
        end

        local function add_upval(f, name, instack, idx)
            local old = find_upval(f, name)
            if old then
                return old
            end
            local n = #f.upvals + 1
            f.upvals[n] = { name = name, instack = instack, idx = idx }
            return n
        end

        local function resolve_upvalue(f, name)
            local parent = f.parent
            if not parent then
                return nil
            end
            local d = find_local(parent, name)
            if d then
                mark_captured(d)
                return add_upval(f, name, 1, d.slot)
            end
            local ui = find_upval(parent, name)
            if not ui then
                ui = resolve_upvalue(parent, name)
            end
            if ui then
                return add_upval(f, name, 0, ui)
            end
            return nil
        end

        local function resolve_var(name)
            local d = find_local(fc, name)
            if d then
                return "local", d
            end
            local ui = find_upval(fc, name)
            if not ui then
                ui = resolve_upvalue(fc, name)
            end
            if ui then
                return "upval", ui
            end
            return "global", addk(name)
        end

        local function emit_var_get(kind, ref)
            if kind == "local" then
                emit_local_get(ref)
            elseif kind == "upval" then
                emit(GETUPVAL, ref, 0, 0)
            else
                emit(GETGLOBAL, ref, 0, 0)
            end
        end

        local function enter_scope()
            return fc.nlocals, fc.nextreg
        end

        local function leave_scope(n, r)
            fc.nlocals = n
            fc.nextreg = r
        end

        local top_multi = false
        local last_multi_pc = nil

        local compile_expr
        local compile_table
        local parse_stmt
        local compile_funcbody
        local parse_block

        local function set_multi(pc)
            top_multi = true
            last_multi_pc = pc
        end

        local function clear_multi()
            top_multi = false
            last_multi_pc = nil
        end

        local function emit_loadnil(n)
            if n > 0 then
                emit(LOADNIL, n, 0, 0)
            end
        end

        local function emit_pop(n)
            if n > 0 then
                emit(POP, n, 0, 0)
            end
        end

        -- ========================================================
        -- Пост-компиляционный peephole: склеивает частые
        -- последовательности в супер-опкоды. Код не сдвигается:
        -- супер-опкод просто перепрыгивает "мёртвые" инструкции.
        -- ========================================================
        local function optimize_code(co, n)
            local targets = {}
            local dead = {}

            for pc = 1, n, 4 do
                local op = co[pc]
                if op == JMP or op == JMPF or op == TESTF or
                   op == TESTT or op == JMPNIL then
                    targets[co[pc + 1]] = true
                elseif op == FORPREP or op == FORLOOP then
                    targets[co[pc + 2]] = true
                end
            end

            local function can(pos, len)
                for i = 1, len - 1 do
                    local p = pos + i * 4
                    if dead[p] or targets[p] then
                        return false
                    end
                end
                return true
            end

            local function put(pos, op, a, b, c, len)
                co[pos] = op
                co[pos + 1] = a or 0
                co[pos + 2] = b or 0
                co[pos + 3] = c or 0
                for i = 1, len - 1 do
                    dead[pos + i * 4] = true
                end
            end

            local rr = {
                [ADD] = FOP.ADD_RR, [SUB] = FOP.SUB_RR,
                [MUL] = FOP.MUL_RR, [DIV] = FOP.DIV_RR,
                [MOD] = FOP.MOD_RR, [POW] = FOP.POW_RR,
                [EQ] = FOP.EQ_RR, [NE] = FOP.NE_RR,
                [LT] = FOP.LT_RR, [LE] = FOP.LE_RR,
                [GT] = FOP.GT_RR, [GE] = FOP.GE_RR,
            }
            local rk = {
                [ADD] = FOP.ADD_RK, [SUB] = FOP.SUB_RK,
                [MUL] = FOP.MUL_RK, [DIV] = FOP.DIV_RK,
                [MOD] = FOP.MOD_RK, [POW] = FOP.POW_RK,
                [EQ] = FOP.EQ_RK, [NE] = FOP.NE_RK,
                [LT] = FOP.LT_RK, [LE] = FOP.LE_RK,
                [GT] = FOP.GT_RK, [GE] = FOP.GE_RK,
            }
            local assign_rr = {
                [ADD] = FOP.ADD_ASSIGN_RR,
                [SUB] = FOP.SUB_ASSIGN_RR,
                [MUL] = FOP.MUL_ASSIGN_RR,
            }
            local assign_rk = {
                [ADD] = FOP.ADD_ASSIGN_RK,
                [SUB] = FOP.SUB_ASSIGN_RK,
                [MUL] = FOP.MUL_ASSIGN_RK,
            }
            local kop = {
                [EQ] = FOP.EQ_K, [NE] = FOP.NE_K,
                [LT] = FOP.LT_K, [LE] = FOP.LE_K,
                [GT] = FOP.GT_K, [GE] = FOP.GE_K,
            }
            local jmpk = {
                [EQ] = FOP.JMPF_EQ_K, [NE] = FOP.JMPF_NE_K,
                [LT] = FOP.JMPF_LT_K, [LE] = FOP.JMPF_LE_K,
                [GT] = FOP.JMPF_GT_K, [GE] = FOP.JMPF_GE_K,
            }

            local function try_stmt(pos)
                -- t[K] = V / t[K] = constant
                if co[pos] == GETLOCAL and co[pos + 4] == GETLOCAL and
                   co[pos + 8] == SETLOCAL and co[pos + 12] == SETLOCAL and
                   (co[pos + 16] == GETLOCAL or co[pos + 16] == LOADK) and
                   co[pos + 20] == SETINDEX and can(pos, 6) then
                    local t = co[pos + 1]
                    local k = co[pos + 5]
                    local keytemp = co[pos + 9]
                    local basetemp = co[pos + 13]
                    local v = co[pos + 17]
                    if co[pos + 21] == basetemp and
                       co[pos + 22] == keytemp and
                       t ~= keytemp and t ~= basetemp and
                       k ~= keytemp and k ~= basetemp and
                       v ~= keytemp and v ~= basetemp then
                        if co[pos + 16] == GETLOCAL then
                            put(pos, FOP.SETINDEX_RR, t, k, v, 6)
                        else
                            put(pos, FOP.SETINDEX_RK, t, k, v, 6)
                        end
                        return pos + 24
                    end
                end

                -- t.field = V / t.field = constant
                if co[pos] == GETLOCAL and co[pos + 4] == SETLOCAL and
                   (co[pos + 8] == GETLOCAL or co[pos + 8] == LOADK) and
                   co[pos + 12] == SETFIELD and can(pos, 4) then
                    local t = co[pos + 1]
                    local basetemp = co[pos + 5]
                    local v = co[pos + 9]
                    local key = co[pos + 14]
                    if co[pos + 13] == basetemp and
                       t ~= basetemp and v ~= basetemp then
                        if co[pos + 8] == GETLOCAL then
                            put(pos, FOP.SETFIELD_RV, t, key, v, 4)
                        else
                            put(pos, FOP.SETFIELD_RK, t, key, v, 4)
                        end
                        return pos + 16
                    end
                end

                -- target = target + table[key]
                if co[pos] == GETLOCAL and co[pos + 4] == GETLOCAL and
                   co[pos + 8] == GETLOCAL and co[pos + 12] == INDEX and
                   co[pos + 16] == ADD and co[pos + 20] == SETLOCAL and
                   co[pos + 21] == co[pos + 1] and can(pos, 6) then
                    local a = co[pos + 1]
                    local t = co[pos + 5]
                    local k = co[pos + 9]
                    if a ~= t and a ~= k and t ~= k then
                        put(pos, FOP.ADD_ASSIGN_INDEX, a, t, k, 6)
                        return pos + 24
                    end
                end

                -- target = target op operand, operand = local/constant
                if co[pos] == GETLOCAL and
                   (co[pos + 4] == GETLOCAL or co[pos + 4] == LOADK) and
                   co[pos + 12] == SETLOCAL and
                   co[pos + 13] == co[pos + 1] and can(pos, 4) then
                    local op = co[pos + 8]
                    if co[pos + 4] == GETLOCAL then
                        local fused = assign_rr[op]
                        if fused then
                            put(pos, fused, co[pos + 1], co[pos + 5], 0, 4)
                            return pos + 16
                        end
                    else
                        local fused = assign_rk[op]
                        if fused then
                            put(pos, fused, co[pos + 1], co[pos + 5], 0, 4)
                            return pos + 16
                        end
                    end
                end

                -- target = table[key]
                if co[pos] == GETLOCAL and co[pos + 4] == GETLOCAL and
                   co[pos + 8] == INDEX and co[pos + 12] == SETLOCAL and
                   can(pos, 4) then
                    local dest = co[pos + 13]
                    local t = co[pos + 1]
                    local k = co[pos + 5]
                    if dest ~= t and dest ~= k and t ~= k then
                        put(pos, FOP.SETLOCAL_INDEX, dest, t, k, 4)
                        return pos + 16
                    end
                end

                -- target = table.field
                if co[pos] == GETLOCAL and co[pos + 4] == FIELD and
                   co[pos + 8] == SETLOCAL and can(pos, 3) then
                    local dest = co[pos + 9]
                    local t = co[pos + 1]
                    local key = co[pos + 5]
                    if dest ~= t then
                        put(pos, FOP.SETLOCAL_FIELD, dest, t, key, 3)
                        return pos + 12
                    end
                end

                -- target = constant
                if co[pos] == LOADK and co[pos + 4] == SETLOCAL and
                   can(pos, 2) then
                    put(pos, FOP.SETLOCAL_K, co[pos + 5], co[pos + 1], 0, 2)
                    return pos + 8
                end

                -- loop variable: GETLOCAL; SETLOCAL raw; CELL/NOP
                if co[pos] == GETLOCAL and co[pos + 4] == SETLOCAL and
                   (co[pos + 8] == NOP or co[pos + 8] == CELL) and
                   can(pos, 3) then
                    local dest = co[pos + 5]
                    local src = co[pos + 1]
                    if dest ~= src then
                        if co[pos + 8] == CELL then
                            put(pos, FOP.MOVLOCAL_CELL, dest, src, 0, 3)
                        else
                            put(pos, FOP.MOVLOCAL_NOP, dest, src, 0, 3)
                        end
                        return pos + 12
                    end
                end

                -- target = source
                if co[pos] == GETLOCAL and co[pos + 4] == SETLOCAL and
                   can(pos, 2) then
                    local dest = co[pos + 5]
                    local src = co[pos + 1]
                    if dest ~= src then
                        put(pos, FOP.MOVLOCAL, dest, src, 0, 2)
                        return pos + 8
                    end
                end

                return nil
            end

            local function try_expr(pos)
                -- constant comparison directly followed by JMPF
                if co[pos] == LOADK and jmpk[co[pos + 4]] and
                   co[pos + 8] == JMPF and can(pos, 3) then
                    put(pos, jmpk[co[pos + 4]], co[pos + 1], co[pos + 9], 0, 3)
                    return pos + 12
                end

                -- local/global condition
                if co[pos] == GETLOCAL and co[pos + 4] == JMPF and
                   can(pos, 2) then
                    put(pos, FOP.JMPF_LOCAL, co[pos + 1], co[pos + 5], 0, 2)
                    return pos + 8
                end
                if co[pos] == GETLOCAL and co[pos + 4] == JMPNIL and
                   can(pos, 2) then
                    put(pos, FOP.JMPNIL_LOCAL, co[pos + 1], co[pos + 5], 0, 2)
                    return pos + 8
                end

                -- table[key]
                if co[pos] == GETLOCAL and
                   (co[pos + 4] == GETLOCAL or co[pos + 4] == LOADK) and
                   co[pos + 8] == INDEX and can(pos, 3) then
                    if co[pos + 4] == GETLOCAL then
                        put(pos, FOP.INDEX_RR, co[pos + 1], co[pos + 5], 0, 3)
                    else
                        put(pos, FOP.INDEX_RK, co[pos + 1], co[pos + 5], 0, 3)
                    end
                    return pos + 12
                end

                -- table.field
                if co[pos] == GETLOCAL and co[pos + 4] == FIELD and
                   can(pos, 2) then
                    put(pos, FOP.FIELD_R, co[pos + 1], co[pos + 5], 0, 2)
                    return pos + 8
                end

                -- local/local and local/constant arithmetic/comparison
                if co[pos] == GETLOCAL and
                   (co[pos + 4] == GETLOCAL or co[pos + 4] == LOADK) and
                   rr[co[pos + 8]] and can(pos, 3) then
                    if co[pos + 4] == GETLOCAL then
                        put(pos, rr[co[pos + 8]], co[pos + 1], co[pos + 5], 0, 3)
                    else
                        put(pos, rk[co[pos + 8]], co[pos + 1], co[pos + 5], 0, 3)
                    end
                    return pos + 12
                end

                -- stack value op constant
                if co[pos] == LOADK and kop[co[pos + 4]] and can(pos, 2) then
                    put(pos, kop[co[pos + 4]], co[pos + 1], 0, 0, 2)
                    return pos + 8
                end

                return nil
            end

            local pos = 1
            while pos <= n do
                if dead[pos] then
                    pos = pos + 4
                else
                    local np = try_stmt(pos)
                    if np then pos = np else pos = pos + 4 end
                end
            end

            -- Fold the per-iteration loop-variable copy into FORLOOP.
            -- The first iteration still uses the MOV instruction after FORPREP;
            -- every following iteration is copied by FORLOOP itself.
            for pc = 1, n, 4 do
                if co[pc] == FORLOOP then
                    local ctrl = co[pc + 1]
                    local body = co[pc + 2]
                    if body >= 1 and body <= n and
                       body + 12 <= n and not dead[body] then
                        local mop = co[body]
                        if (mop == FOP.MOVLOCAL_NOP or
                            mop == FOP.MOVLOCAL_CELL) and
                           co[body + 2] == ctrl then
                            local dest = co[body + 1]
                            if mop == FOP.MOVLOCAL_CELL then
                                co[pc] = FOP.FORLOOP_CELL
                            else
                                co[pc] = FOP.FORLOOP_MOV
                            end
                            co[pc + 1] = ctrl
                            co[pc + 2] = dest
                            co[pc + 3] = body + 12
                            targets[body + 12] = true
                        end
                    end
                end
            end

            pos = 1
            while pos <= n do
                if dead[pos] then
                    pos = pos + 4
                else
                    local np = try_expr(pos)
                    if np then pos = np else pos = pos + 4 end
                end
            end
        end

        local function parse_call_args(offset)
            local oldreg = fc.nextreg
            local mreg = reserve_reg()
            emit(MARK, mreg, offset, 0)

            if tk == "(" then
                advance()
                if tk ~= ")" then
                    while true do
                        compile_expr()
                        if tk == "," then
                            advance()
                        else
                            if top_multi then
                                patch_nres(last_multi_pc, -1)
                            end
                            break
                        end
                    end
                end
                expect(")")
            elseif tk == "{" then
                compile_table()
            elseif tk == "string" then
                local k = addk(tv)
                advance()
                emit(LOADK, k, 0, 0)
            else
                fail("function arguments expected")
            end

            local callpc = emit(CALLD, mreg, 1, 0)
            fc.nextreg = oldreg
            set_multi(callpc)
            return callpc
        end

        local function compile_suffix()
            while true do
                if tk == "." then
                    advance()
                    if tk ~= "name" then
                        fail("field name expected")
                    end
                    local k = addk(tv)
                    advance()
                    emit(FIELD, k, 0, 0)
                    clear_multi()
                elseif tk == "[" then
                    advance()
                    compile_expr()
                    expect("]")
                    emit(INDEX, 0, 0, 0)
                    clear_multi()
                elseif tk == "(" or tk == "{" or tk == "string" then
                    parse_call_args(0)
                elseif tk == ":" then
                    advance()
                    if tk ~= "name" then
                        fail("method name expected")
                    end
                    local k = addk(tv)
                    advance()
                    emit(SELF, k, 0, 0)
                    parse_call_args(1)
                else
                    return
                end
            end
        end

        local function compile_primary()
            if tk == "number" or tk == "string" then
                local k = addk(tv)
                advance()
                emit(LOADK, k, 0, 0)
                clear_multi()
            elseif tk == "nil" then
                advance()
                emit(LOADNIL, 1, 0, 0)
                clear_multi()
            elseif tk == "true" then
                advance()
                emit(LOADBOOL, 1, 0, 0)
                clear_multi()
            elseif tk == "false" then
                advance()
                emit(LOADBOOL, 0, 0, 0)
                clear_multi()
            elseif tk == "..." then
                if not fc.isvararg then
                    fail("cannot use '...' outside a vararg function")
                end
                advance()
                local p = emit(VARARG, 1, 0, 0)
                set_multi(p)
            elseif tk == "function" then
                advance()
                local idx = compile_funcbody(false)
                emit(CLOSURE, idx, 0, 0)
                clear_multi()
            elseif tk == "{" then
                compile_table()
                clear_multi()
            elseif tk == "name" then
                local name = tv
                advance()
                local kind, ref = resolve_var(name)
                emit_var_get(kind, ref)
                compile_suffix()
            elseif tk == "(" then
                advance()
                compile_expr()
                expect(")")
                clear_multi()
                compile_suffix()
            else
                fail("expression expected")
            end
        end

        local compile_unary

        local function compile_pow()
            compile_primary()
            if tk == "^" then
                advance()
                compile_unary()
                emit(POW, 0, 0, 0)
                clear_multi()
            end
        end

        compile_unary = function()
            if tk == "-" then
                advance()
                compile_unary()
                emit(UNM, 0, 0, 0)
                clear_multi()
            elseif tk == "not" then
                advance()
                compile_unary()
                emit(NOT, 0, 0, 0)
                clear_multi()
            elseif tk == "#" then
                advance()
                compile_unary()
                emit(LEN, 0, 0, 0)
                clear_multi()
            else
                compile_pow()
            end
        end

        local function compile_mul()
            compile_unary()
            while tk == "*" or tk == "/" or tk == "%" do
                local op = tk
                advance()
                compile_unary()
                if op == "*" then
                    emit(MUL, 0, 0, 0)
                elseif op == "/" then
                    emit(DIV, 0, 0, 0)
                else
                    emit(MOD, 0, 0, 0)
                end
                clear_multi()
            end
        end

        local function compile_add()
            compile_mul()
            while tk == "+" or tk == "-" do
                local op = tk
                advance()
                compile_mul()
                if op == "+" then
                    emit(ADD, 0, 0, 0)
                else
                    emit(SUB, 0, 0, 0)
                end
                clear_multi()
            end
        end

        local function compile_concat()
            compile_add()
            if tk == ".." then
                advance()
                compile_concat()
                emit(CONCAT, 0, 0, 0)
                clear_multi()
            end
        end

        local function compile_compare()
            compile_concat()
            while tk == "==" or tk == "~=" or tk == "<" or tk == "<=" or
                  tk == ">" or tk == ">=" do
                local op = tk
                advance()
                compile_concat()
                if op == "==" then
                    emit(EQ, 0, 0, 0)
                elseif op == "~=" then
                    emit(NE, 0, 0, 0)
                elseif op == "<" then
                    emit(LT, 0, 0, 0)
                elseif op == "<=" then
                    emit(LE, 0, 0, 0)
                elseif op == ">" then
                    emit(GT, 0, 0, 0)
                else
                    emit(GE, 0, 0, 0)
                end
                clear_multi()
            end
        end

        local function compile_and()
            compile_compare()
            local jumps = nil
            while tk == "and" do
                local j = emit(TESTF, 0, 0, 0)
                if not jumps then
                    jumps = {}
                end
                jumps[#jumps + 1] = j
                advance()
                compile_compare()
            end
            if jumps then
                local target = here()
                for i = 1, #jumps do
                    patch_target(jumps[i], target)
                end
                clear_multi()
            end
        end

        local function compile_or()
            compile_and()
            local jumps = nil
            while tk == "or" do
                local j = emit(TESTT, 0, 0, 0)
                if not jumps then
                    jumps = {}
                end
                jumps[#jumps + 1] = j
                advance()
                compile_and()
            end
            if jumps then
                local target = here()
                for i = 1, #jumps do
                    patch_target(jumps[i], target)
                end
                clear_multi()
            end
        end

        compile_expr = function()
            clear_multi()
            compile_or()
        end

        -- ========================================================
        -- Табличные конструкторы
        -- ========================================================
        compile_table = function()
            local oldreg = fc.nextreg
            local treg = reserve_reg()
            local mreg = reserve_reg()
            emit(NEWTABLE, 0, 0, 0)
            emit(SETLOCAL, treg, 0, 0)

            expect("{")
            local idx = 0

            local function is_named_field()
                if tk ~= "name" then
                    return false
                end
                local sp = pos
                local stk = tk
                local stv = tv
                local stp = tp
                advance()
                local named = (tk == "=")
                pos = sp
                tk = stk
                tv = stv
                tp = stp
                return named
            end

            local function finish_separator()
                if tk == "," or tk == ";" then
                    advance()
                elseif tk ~= "}" then
                    fail("',' or '}' expected")
                end
            end

            while tk ~= "}" do
                if tk == "[" then
                    advance()
                    local keyold = fc.nextreg
                    local keyreg = reserve_reg()
                    compile_expr()
                    expect("]")
                    emit(SETLOCAL, keyreg, 0, 0)
                    expect("=")
                    compile_expr()
                    emit(SETINDEX, treg, keyreg, 0)
                    fc.nextreg = keyold
                    finish_separator()
                elseif is_named_field() then
                    local key = addk(tv)
                    advance()
                    expect("=")
                    compile_expr()
                    emit(SETFIELD, treg, key, 0)
                    finish_separator()
                else
                    emit(MARK, mreg, 0, 0)
                    compile_expr()
                    idx = idx + 1

                    local last = false
                    if tk == "}" then
                        last = true
                    elseif tk == "," or tk == ";" then
                        advance()
                        last = (tk == "}")
                    else
                        fail("',' or '}' expected")
                    end

                    if last then
                        if top_multi then
                            patch_nres(last_multi_pc, -1)
                            emit(SETLISTMULTI, treg, idx, mreg)
                        else
                            emit(SETLIST, treg, idx, 0)
                        end
                        break
                    else
                        emit(SETLIST, treg, idx, 0)
                    end
                end
            end

            expect("}")
            emit(GETLOCAL, treg, 0, 0)
            fc.nextreg = oldreg
            clear_multi()
        end

        -- ========================================================
        -- Функции
        -- ========================================================
        compile_funcbody = function(implicit_self)
            local parent_fc = fc
            local child = new_fc(parent_fc, false, 0)
            fc = child

            local params = {}
            expect("(")
            if implicit_self then
                local d = new_local("self")
                child.numparams = 1
                params[#params + 1] = d
            end

            local vararg = false
            if tk ~= ")" then
                while true do
                    if tk == "..." then
                        vararg = true
                        advance()
                        break
                    elseif tk == "name" then
                        local d = new_local(tv)
                        child.numparams = child.numparams + 1
                        params[#params + 1] = d
                        advance()
                    else
                        fail("parameter name or '...' expected")
                    end
                    if tk == "," then
                        advance()
                        if tk == ")" then
                            fail("parameter expected after ','")
                        end
                    else
                        break
                    end
                end
            end
            expect(")")
            child.isvararg = vararg

            for i = 1, #params do
                emit_cell(params[i])
            end

            parse_block("end")
            expect("end")
            emit(RET, 0, 0, 0)
            optimize_code(child.code, child.ncode)

            local proto = {
                code = child.code,
                consts = child.consts,
                updesc = child.upvals,
                numparams = child.numparams,
                isvararg = child.isvararg,
                maxreg = child.maxreg,
                env = env,
                protos = all_protos,
            }
            all_protos[#all_protos + 1] = proto
            local idx = #all_protos

            fc = parent_fc
            return idx
        end

        -- ========================================================
        -- Выражения-списки
        -- ========================================================
        local function compile_exprlist_assign(n)
            clear_multi()
            local count = 0
            while true do
                compile_expr()
                count = count + 1
                if tk == "," then
                    advance()
                else
                    break
                end
            end

            if count <= n and top_multi then
                patch_nres(last_multi_pc, n - count + 1)
            elseif count < n then
                emit_loadnil(n - count)
            elseif count > n then
                emit_pop(count - n)
            end
            clear_multi()
        end

        local function compile_exprlist_all()
            clear_multi()
            local count = 0
            if tk == "eof" or tk == "end" or tk == "else" or
               tk == "elseif" or tk == "until" or tk == ";" then
                return 0
            end
            while true do
                compile_expr()
                count = count + 1
                if tk == "," then
                    advance()
                else
                    break
                end
            end
            if top_multi then
                patch_nres(last_multi_pc, -1)
                clear_multi()
                return -1
            end
            clear_multi()
            return count
        end

        -- ========================================================
        -- Выражения в statement-позиции: assignment или call
        -- ========================================================
        local function make_field_target(base_reg, key)
            return { kind = "field", base = base_reg, key = key }
        end

        local function make_index_target(base_reg, key_reg)
            return { kind = "index", base = base_reg, key = key_reg }
        end

        local function parse_prefix_stmt()
            local final_call_pc = nil

            if tk == "name" then
                local name = tv
                advance()
                local kind, ref = resolve_var(name)
                if tk == "=" or tk == "," then
                    return "target", { kind = kind, ref = ref }
                end
                emit_var_get(kind, ref)
            elseif tk == "(" then
                advance()
                compile_expr()
                expect(")")
                clear_multi()
            else
                fail("statement expected")
            end

            while true do
                if tk == "." then
                    advance()
                    if tk ~= "name" then
                        fail("field name expected")
                    end
                    local key = addk(tv)
                    advance()
                    if tk == "=" or tk == "," then
                        local breg = reserve_reg()
                        emit(SETLOCAL, breg, 0, 0)
                        return "target", make_field_target(breg, key)
                    end
                    emit(FIELD, key, 0, 0)
                    clear_multi()
                    final_call_pc = nil
                elseif tk == "[" then
                    advance()
                    compile_expr()
                    expect("]")
                    if tk == "=" or tk == "," then
                        local breg = reserve_reg()
                        local kreg = reserve_reg()
                        emit(SETLOCAL, kreg, 0, 0)
                        emit(SETLOCAL, breg, 0, 0)
                        return "target", make_index_target(breg, kreg)
                    end
                    emit(INDEX, 0, 0, 0)
                    clear_multi()
                    final_call_pc = nil
                elseif tk == "(" or tk == "{" or tk == "string" then
                    final_call_pc = parse_call_args(0)
                elseif tk == ":" then
                    advance()
                    if tk ~= "name" then
                        fail("method name expected")
                    end
                    local key = addk(tv)
                    advance()
                    emit(SELF, key, 0, 0)
                    final_call_pc = parse_call_args(1)
                else
                    break
                end
            end

            if final_call_pc then
                return "call", final_call_pc
            end
            fail("function call expected")
        end

        local function emit_store_target(target)
            local k = target.kind
            if k == "local" then
                emit_local_set(target.ref)
            elseif k == "upval" then
                emit(SETUPVAL, target.ref, 0, 0)
            elseif k == "global" then
                emit(SETGLOBAL, target.ref, 0, 0)
            elseif k == "field" then
                emit(SETFIELD, target.base, target.key, 0)
            elseif k == "index" then
                emit(SETINDEX, target.base, target.key, 0)
            else
                error("bad lvalue", 0)
            end
        end

        local function parse_assignment_or_call()
            local oldreg = fc.nextreg
            local kind, data = parse_prefix_stmt()

            if kind == "call" then
                if tk == "=" or tk == "," then
                    fail("cannot assign to a function call")
                end
                patch_nres(data, 0)
                clear_multi()
                fc.nextreg = oldreg
                return
            end

            local targets = { data }
            while tk == "," do
                advance()
                local k2, d2 = parse_prefix_stmt()
                if k2 ~= "target" then
                    fail("variable expected")
                end
                targets[#targets + 1] = d2
            end

            expect("=")
            compile_exprlist_assign(#targets)
            for i = #targets, 1, -1 do
                emit_store_target(targets[i])
            end
            fc.nextreg = oldreg
            clear_multi()
        end

        -- ========================================================
        -- Блоки и операторы
        -- ========================================================
        local function is_block_end()
            return tk == "eof" or tk == "end" or tk == "else" or
                   tk == "elseif" or tk == "until"
        end

        parse_block = function(stop1, stop2, stop3)
            while tk ~= "eof" and tk ~= stop1 and
                  (not stop2 or tk ~= stop2) and
                  (not stop3 or tk ~= stop3) do
                parse_stmt()
            end
        end

        local function parse_local()
            advance() -- local
            if tk == "function" then
                advance()
                if tk ~= "name" then
                    fail("local function name expected")
                end
                local desc = new_local(tv)
                advance()
                emit(LOADNIL, 1, 0, 0)
                emit(SETLOCAL, desc.slot, 0, 0)
                emit_cell(desc)
                local idx = compile_funcbody(false)
                emit(CLOSURE, idx, 0, 0)
                emit_local_set(desc)
                clear_multi()
                return
            end

            local names = {}
            local n = 0
            while true do
                if tk ~= "name" then
                    fail("local variable name expected")
                end
                n = n + 1
                names[n] = tv
                advance()
                if not accept(",") then
                    break
                end
            end

            local has_init = accept("=")
            if has_init then
                compile_exprlist_assign(n)
            else
                emit_loadnil(n)
            end

            local descs = {}
            for i = 1, n do
                descs[i] = new_local(names[i])
            end
            for i = n, 1, -1 do
                emit(SETLOCAL, descs[i].slot, 0, 0)
            end
            for i = 1, n do
                emit_cell(descs[i])
            end
        end

        local function parse_return()
            advance()
            local n = compile_exprlist_all()
            while accept(";") do end
            if not is_block_end() then
                fail("'end' expected after return")
            end
            emit(RET, n, 0, 0)
        end

        local function parse_break()
            advance()
            if fc.loop_depth == 0 then
                fail("break outside loop")
            end
            while accept(";") do end
            if not is_block_end() then
                fail("'end' expected after break")
            end
            local j = emit(JMP, 0, 0, 0)
            local br = fc.loop_breaks[fc.loop_depth]
            br[#br + 1] = j
        end

        local function parse_while()
            advance()
            local start = here()
            compile_expr()
            expect("do")
            local jf = emit(JMPF, 0, 0, 0)
            local mn, mr = enter_scope()
            fc.loop_depth = fc.loop_depth + 1
            local br = {}
            fc.loop_breaks[fc.loop_depth] = br
            parse_block("end")
            fc.loop_breaks[fc.loop_depth] = nil
            fc.loop_depth = fc.loop_depth - 1
            leave_scope(mn, mr)
            emit(JMP, start, 0, 0)
            expect("end")
            local target = here()
            patch_target(jf, target)
            for i = 1, #br do
                patch_target(br[i], target)
            end
        end

        local function parse_repeat()
            advance()
            local start = here()
            local mn, mr = enter_scope()
            fc.loop_depth = fc.loop_depth + 1
            local br = {}
            fc.loop_breaks[fc.loop_depth] = br
            parse_block("until")
            expect("until")
            compile_expr()
            emit(JMPF, start, 0, 0)
            fc.loop_breaks[fc.loop_depth] = nil
            fc.loop_depth = fc.loop_depth - 1
            local target = here()
            for i = 1, #br do
                patch_target(br[i], target)
            end
            leave_scope(mn, mr)
        end

        local function parse_numeric_for(name)
            expect("=")
            local mn, mr = enter_scope()
            local ctrl = reserve_reg()
            local limit = reserve_reg()
            local step = reserve_reg()

            compile_expr()
            emit(SETLOCAL, ctrl, 0, 0)
            expect(",")
            compile_expr()
            emit(SETLOCAL, limit, 0, 0)
            if accept(",") then
                compile_expr()
            else
                emit(LOADK, addk(1), 0, 0)
            end
            emit(SETLOCAL, step, 0, 0)

            local desc = new_local(name)
            expect("do")
            local prep = emit(FORPREP, ctrl, 0, 0)
            local body = here()

            emit(GETLOCAL, ctrl, 0, 0)
            emit(SETLOCAL, desc.slot, 0, 0)
            emit_cell(desc)

            fc.loop_depth = fc.loop_depth + 1
            local br = {}
            fc.loop_breaks[fc.loop_depth] = br
            parse_block("end")
            fc.loop_breaks[fc.loop_depth] = nil
            fc.loop_depth = fc.loop_depth - 1
            expect("end")

            emit(FORLOOP, ctrl, body, 0)
            local target = here()
            patch_b(prep, target)
            for i = 1, #br do
                patch_target(br[i], target)
            end
            leave_scope(mn, mr)
        end

        local function parse_generic_for(names, nnames)
            expect("in")
            local mn, mr = enter_scope()
            local freg = reserve_reg()
            local sreg = reserve_reg()
            local creg = reserve_reg()

            compile_exprlist_assign(3)
            emit(SETLOCAL, creg, 0, 0)
            emit(SETLOCAL, sreg, 0, 0)
            emit(SETLOCAL, freg, 0, 0)

            local descs = {}
            for i = 1, nnames do
                descs[i] = new_local(names[i])
            end
            expect("do")

            local start = here()
            local mreg = reserve_reg()
            local preg = reserve_reg()

            emit(GETLOCAL, freg, 0, 0)
            emit(MARK, mreg, 0, 0)
            emit(GETLOCAL, sreg, 0, 0)
            emit(GETLOCAL, creg, 0, 0)
            emit(CALLD, mreg, nnames, 0)
            emit(PEEK, preg, nnames - 1, 0)
            for i = nnames, 1, -1 do
                emit(SETLOCAL, descs[i].slot, 0, 0)
                emit_cell(descs[i])
            end
            emit(GETLOCAL, preg, 0, 0)
            emit(SETLOCAL, creg, 0, 0)
            emit(GETLOCAL, creg, 0, 0)
            local jf = emit(JMPNIL, 0, 0, 0)

            fc.loop_depth = fc.loop_depth + 1
            local br = {}
            fc.loop_breaks[fc.loop_depth] = br
            parse_block("end")
            fc.loop_breaks[fc.loop_depth] = nil
            fc.loop_depth = fc.loop_depth - 1
            expect("end")

            emit(JMP, start, 0, 0)
            local target = here()
            patch_target(jf, target)
            for i = 1, #br do
                patch_target(br[i], target)
            end
            leave_scope(mn, mr)
        end

        local function parse_for()
            advance()
            if tk ~= "name" then
                fail("for variable name expected")
            end
            local first = tv
            advance()
            if tk == "=" then
                parse_numeric_for(first)
                return
            end

            local names = { first }
            local nnames = 1
            while tk == "," do
                advance()
                if tk ~= "name" then
                    fail("for variable name expected")
                end
                nnames = nnames + 1
                names[nnames] = tv
                advance()
            end
            parse_generic_for(names, nnames)
        end

        local function parse_if()
            advance()
            local endjumps = nil
            while true do
                compile_expr()
                expect("then")
                local jf = emit(JMPF, 0, 0, 0)
                local mn, mr = enter_scope()
                parse_block("end", "elseif", "else")
                leave_scope(mn, mr)

                if tk == "elseif" then
                    local j = emit(JMP, 0, 0, 0)
                    if not endjumps then endjumps = {} end
                    endjumps[#endjumps + 1] = j
                    patch_target(jf, here())
                    advance()
                elseif tk == "else" then
                    local j = emit(JMP, 0, 0, 0)
                    if not endjumps then endjumps = {} end
                    endjumps[#endjumps + 1] = j
                    patch_target(jf, here())
                    advance()
                    local mn2, mr2 = enter_scope()
                    parse_block("end")
                    leave_scope(mn2, mr2)
                    expect("end")
                    local target = here()
                    for i = 1, #endjumps do
                        patch_target(endjumps[i], target)
                    end
                    return
                else
                    expect("end")
                    local target = here()
                    patch_target(jf, target)
                    if endjumps then
                        for i = 1, #endjumps do
                            patch_target(endjumps[i], target)
                        end
                    end
                    return
                end
            end
        end

        local function parse_do()
            advance()
            local mn, mr = enter_scope()
            parse_block("end")
            expect("end")
            leave_scope(mn, mr)
        end

        local function parse_function_stmt()
            advance()
            if tk ~= "name" then
                fail("function name expected")
            end
            local oldreg = fc.nextreg
            local name = tv
            advance()
            local kind, ref = resolve_var(name)
            local target
            local method = false

            if tk == "." or tk == ":" then
                emit_var_get(kind, ref)
                while true do
                    if tk == "." then
                        advance()
                        if tk ~= "name" then
                            fail("field name expected")
                        end
                        local key = addk(tv)
                        advance()
                        if tk == "." or tk == ":" then
                            emit(FIELD, key, 0, 0)
                        elseif tk == "(" then
                            local breg = reserve_reg()
                            emit(SETLOCAL, breg, 0, 0)
                            target = make_field_target(breg, key)
                            break
                        else
                            fail("'(' expected")
                        end
                    elseif tk == ":" then
                        advance()
                        if tk ~= "name" then
                            fail("method name expected")
                        end
                        local key = addk(tv)
                        advance()
                        if tk ~= "(" then
                            fail("'(' expected")
                        end
                        local breg = reserve_reg()
                        emit(SETLOCAL, breg, 0, 0)
                        target = make_field_target(breg, key)
                        method = true
                        break
                    else
                        fail("'(' expected")
                    end
                end
            else
                target = { kind = kind, ref = ref }
            end

            local idx = compile_funcbody(method)
            emit(CLOSURE, idx, 0, 0)
            emit_store_target(target)
            fc.nextreg = oldreg
            clear_multi()
        end

        parse_stmt = function()
            if tk == ";" then
                advance()
                return
            elseif tk == "local" then
                parse_local()
            elseif tk == "function" then
                parse_function_stmt()
            elseif tk == "if" then
                parse_if()
            elseif tk == "while" then
                parse_while()
            elseif tk == "repeat" then
                parse_repeat()
            elseif tk == "for" then
                parse_for()
            elseif tk == "do" then
                parse_do()
            elseif tk == "break" then
                parse_break()
            elseif tk == "return" then
                parse_return()
            elseif tk == "name" or tk == "(" then
                parse_assignment_or_call()
            else
                fail("statement expected")
            end
        end

        fc = new_fc(nil, true, 0)
        advance()
        while tk ~= "eof" do
            parse_stmt()
        end
        emit(RET, 0, 0, 0)
        optimize_code(fc.code, fc.ncode)

        local proto = {
            code = fc.code,
            consts = fc.consts,
            updesc = fc.upvals,
            numparams = 0,
            isvararg = true,
            maxreg = fc.maxreg,
            env = env,
            protos = all_protos,
        }
        all_protos[#all_protos + 1] = proto
        return proto
    end

    local ok, proto = pcall(compile)
    if not ok then
        return nil, tostring(proto)
    end
    return make_closure(proto, {}, env)
end

return custom_loadstring
