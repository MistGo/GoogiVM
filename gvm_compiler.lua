--[[
  gvm_compiler.lua — GoogiVM lexer, parser, emitter and optimizer.

  Returns a factory: local compile = dofile("gvm_compiler.lua")(runtime)
  The factory closes over the runtime's make_closure/prototype helpers.
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
local unpack = unpack or table.unpack

local function build(runtime)
    local make_closure = runtime.make_closure
    local DEFAULT_LIMITS = runtime.DEFAULT_LIMITS
    local FOP = runtime.FOP
    local closure_info = runtime.closure_info
-- LuaJIT 2.1 has an intermittent miscompile in the fused comparison path
-- (observed as e.g. "0.5 > -1" returning false after a large fuzz run).
-- Keep comparisons on the base opcodes when a LuaJIT runtime is present;
-- plain Lua hosts can still use the fused forms.
local has_jit = type(jit) == "table" and (jit.status == nil or jit.status() == true)

local function custom_loadstring(source, env, opts)
    if type(source) ~= "string" then
        return nil, "script must be a string"
    end
    if env == nil then
        env = {}
    elseif type(env) ~= "table" then
        return nil, "environment must be a table"
    end
    if opts ~= nil and type(opts) ~= "table" then
        return nil, "options must be a table"
    end

    local limits = {}
    for k, v in pairs(DEFAULT_LIMITS) do
        limits[k] = v
    end
    if opts then
        for k, v in pairs(opts) do
            if DEFAULT_LIMITS[k] ~= nil then
                if type(v) ~= "number" or v <= 0 or v ~= v then
                    return nil, "option '" .. tostring(k) ..
                        "' must be a positive number"
                end
                limits[k] = v
            end
        end
    end
    if #source > limits.maxSourceBytes then
        return nil, "source exceeds maxSourceBytes"
    end

    local sourceName = "<string>"
    if opts and opts.sourceName ~= nil then
        if type(opts.sourceName) ~= "string" then
            return nil, "option 'sourceName' must be a string"
        end
        sourceName = opts.sourceName
    end

    local backend = "legacy"
    if opts and opts.backend ~= nil then
        if opts.backend ~= "legacy" and opts.backend ~= "closure" then
            return nil, "option 'backend' must be 'legacy' or 'closure'"
        end
        backend = opts.backend
    end

    local function compile()
        local len = #source
        local pos = 1
        local tk = ""
        local tv = nil
        local tp = 1
        local last_tp = 1

        local line_starts = { 1 }
        local line_pos = 1
        while line_pos <= len do
            local nl = str_find(source, "[\r\n]", line_pos)
            if not nl then
                break
            end
            if str_sub(source, nl, nl) == "\r" and
               str_sub(source, nl + 1, nl + 1) == "\n" then
                line_pos = nl + 2
            else
                line_pos = nl + 1
            end
            line_starts[#line_starts + 1] = line_pos
        end

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
            local lo, hi = 1, #line_starts
            while lo < hi do
                local mid = math.floor((lo + hi + 1) / 2)
                if line_starts[mid] <= p then
                    lo = mid
                else
                    hi = mid - 1
                end
            end
            return lo
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
                    if str_sub(source, q, q) == "." and
                       str_sub(source, q + 1, q + 1) == "." then
                        tp = p
                        tv = str_sub(source, p, q + 1)
                        fail("malformed number")
                    end
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

            if str_sub(source, q, q) == "." and
               str_sub(source, q + 1, q + 1) == "." then
                tp = p
                tv = str_sub(source, p, q + 1)
                fail("malformed number")
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
            last_tp = tp
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
                code = {}, lines = {}, ncode = 0,
                consts = {}, cmap = {}, kcount = 0,
                locals = {}, nlocals = 0,
                upvals = {},
                slotlen = {},
                nextreg = 0, maxreg = 0,
                isvararg = isvararg, numparams = numparams,
                loop_depth = 0, loop_breaks = {},
                has_inline = false,
                inline_sites = {},
            }
        end

        local function emit(op, a, b, c)
            local i = fc.ncode + 1
            local co = fc.code
            co[i] = op
            co[i + 1] = a or 0
            co[i + 2] = b or 0
            co[i + 3] = c or 0
            fc.lines[i] = line_of(last_tp)
            fc.ncode = i + 3
            fc.slotlen[i] = 1
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
                func_idx = nil,
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
            desc.func_idx = nil
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
                local ui = add_upval(f, name, 1, d.slot)
                f.upvals[ui].src = d
                return ui
            end
            local ui = find_upval(parent, name)
            if not ui then
                ui = resolve_upvalue(parent, name)
            end
            if ui then
                local nui = add_upval(f, name, 0, ui)
                f.upvals[nui].src = parent.upvals[ui].src
                return nui
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
        local no_tail_call = false

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
        -- Post-compile peephole optimizer: fuses frequent instruction
        -- sequences into superinstructions without shifting code.
        -- ========================================================
        local function optimize_code(co, n, skip_fusions)
            if skip_fusions then return end
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

            -- Reject jump targets anywhere in a span, while allowing dead
            -- slots: patterns that fuse already-fused instructions have
            -- expected dead slots between their live opcodes.
            local function no_targets(pos, len)
                for i = 1, len - 1 do
                    if targets[pos + i * 4] then
                        return false
                    end
                end
                return true
            end

            -- Like can(), but tolerates a jump target on the final slot.
            -- The last instruction of a fused sequence stays in place and
            -- therefore remains valid for jumps that land on it; only the
            -- fall-through path skips it.
            local function can_tail(pos, len)
                local last = pos + (len - 1) * 4
                for i = 1, len - 1 do
                    local p = pos + i * 4
                    if dead[p] then
                        return false
                    end
                    if p ~= last and targets[p] then
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
                co.slotlen = co.slotlen or {}
                co.slotlen[pos] = len
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
            -- Compound assignment travels as one opcode per shape; the
            -- operator kind is the base arithmetic opcode number.
            local assign_kind = {
                [ADD] = 13, [SUB] = 14, [MUL] = 15,
                [DIV] = 16, [MOD] = 17, [POW] = 18, [CONCAT] = 19,
            }
            local kop = {
                [EQ] = FOP.EQ_K, [NE] = FOP.NE_K,
                [LT] = FOP.LT_K, [LE] = FOP.LE_K,
                [GT] = FOP.GT_K, [GE] = FOP.GE_K,
            }
            if has_jit then
                -- See the LuaJIT note near custom_loadstring. Equality
                -- fusions are safe; only ordering comparisons have the
                -- intermittent upstream miscompile.
                for _, op in ipairs({ LT, LE, GT, GE }) do
                    rr[op] = nil
                    rk[op] = nil
                    kop[op] = nil
                end
            end

            local function try_stmt(pos)
                -- t[i % k] = v
                if co[pos] == GETLOCAL and co[pos + 4] == GETLOCAL and
                   co[pos + 8] == LOADK and co[pos + 12] == MOD and
                   co[pos + 16] == SETLOCAL and co[pos + 20] == SETLOCAL and
                   co[pos + 24] == GETLOCAL and co[pos + 28] == SETINDEX and
                   can(pos, 8) then
                    local t = co[pos + 1]
                    local i = co[pos + 5]
                    local kmod = co[pos + 9]
                    local ktmp = co[pos + 17]
                    local ttmp = co[pos + 21]
                    local v = co[pos + 25]
                    if co[pos + 29] == ttmp and co[pos + 30] == ktmp and
                       t ~= ttmp and t ~= ktmp and v ~= ttmp and v ~= ktmp then
                        put(pos, FOP.SETINDEX_MOD_RK, t, i, kmod, 8)
                        co[pos + 4] = v
                        return pos + 32
                    end
                end

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

                -- target = target + (a op b)
                if pos + 20 <= n and co[pos] == GETLOCAL and
                   co[pos + 4] == GETLOCAL and co[pos + 8] == GETLOCAL and
                   (co[pos + 12] == ADD or co[pos + 12] == SUB or co[pos + 12] == MUL) and
                   co[pos + 16] == ADD and co[pos + 20] == SETLOCAL and
                   co[pos + 21] == co[pos + 1] and can(pos, 6) then
                    local dest = co[pos + 1]
                    local a = co[pos + 5]
                    local b = co[pos + 9]
                    if dest ~= a and dest ~= b then
                        put(pos, FOP.ADD_ASSIGN_BINOP_RR, dest, a, b, 6)
                        return pos + 24
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
                        put(pos, FOP.ASSIGN_INDEX, a, t, k, 6)
                        co[pos + 4] = 13
                        return pos + 24
                    end
                end

                -- a, b = b, a  ->  one swap
                --   GETLOCAL B ; GETLOCAL A ; SETLOCAL B ; SETLOCAL A
                -- Matched on the raw sequence, before the GETLOCAL/SETLOCAL
                -- pairs below are folded into MOVLOCAL.
                if co[pos] == GETLOCAL and co[pos + 4] == GETLOCAL and
                   co[pos + 8] == SETLOCAL and co[pos + 12] == SETLOCAL and
                   co[pos + 9] == co[pos + 1] and co[pos + 13] == co[pos + 5] and
                   co[pos + 1] ~= co[pos + 5] and
                   can(pos, 4) then
                    put(pos, FOP.SWAP, co[pos + 1], co[pos + 5], 0, 4)
                    return pos + 16
                end

                -- s = (s + i) % k  ->  one fused op
                if pos + 20 <= n and co[pos] == GETLOCAL and
                   co[pos + 4] == GETLOCAL and co[pos + 8] == ADD and
                   co[pos + 12] == LOADK and co[pos + 16] == MOD and
                   co[pos + 20] == SETLOCAL and co[pos + 21] == co[pos + 1] and
                   can(pos, 6) then
                    put(pos, FOP.ASSIGN_MOD_ADD_RK, co[pos + 1], co[pos + 5], co[pos + 13], 6)
                    return pos + 24
                end

                -- target = target op operand, operand = local/constant
                if co[pos] == GETLOCAL and
                   (co[pos + 4] == GETLOCAL or co[pos + 4] == LOADK) and
                   co[pos + 12] == SETLOCAL and
                   co[pos + 13] == co[pos + 1] and can(pos, 4) then
                    local op = co[pos + 8]
                    local kind = assign_kind[op]
                    if kind then
                        if co[pos + 4] == GETLOCAL then
                            put(pos, FOP.ASSIGN_RR, co[pos + 1], co[pos + 5], 0, 4)
                        else
                            put(pos, FOP.ASSIGN_RK, co[pos + 1], co[pos + 5], 0, 4)
                        end
                        co[pos + 4] = kind
                        return pos + 16
                    end
                end

                -- dest = a op b  (destination differs from the left operand)
                if co[pos] == GETLOCAL and
                   (co[pos + 4] == GETLOCAL or co[pos + 4] == LOADK) and
                   co[pos + 12] == SETLOCAL and
                   co[pos + 13] ~= co[pos + 1] and can(pos, 4) then
                    local aop = co[pos + 8]
                    local akind = assign_kind[aop]
                    if akind then
                        if co[pos + 4] == GETLOCAL then
                            put(pos, FOP.ASSIGN_TO_RR, co[pos + 13], co[pos + 1], co[pos + 5], 4)
                        else
                            put(pos, FOP.ASSIGN_TO_RK, co[pos + 13], co[pos + 1], co[pos + 5], 4)
                        end
                        co[pos + 4] = akind
                        return pos + 16
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

                -- target = boolean
                if co[pos] == LOADBOOL and co[pos + 4] == SETLOCAL and
                   can(pos, 2) then
                    put(pos, FOP.SETLOCAL_BOOL, co[pos + 5], co[pos + 1], 0, 2)
                    return pos + 8
                end

                -- local cell = { v = x }; local f = function() ... end
                --   GETLOCAL src ; SETLOCAL cellreg ; CELL cellreg ; CLOSURE proto ; SETLOCAL dest
                if co[pos] == GETLOCAL and co[pos + 4] == SETLOCAL and
                   co[pos + 8] == CELL and co[pos + 12] == CLOSURE and
                   co[pos + 16] == SETLOCAL and
                   co[pos + 5] == co[pos + 9] and
                   co[pos + 1] ~= co[pos + 5] and
                   co[pos + 17] ~= co[pos + 5] and
                   co[pos + 17] ~= co[pos + 1] and
                   can(pos, 5) then
                    put(pos, FOP.CLOSURE_CELL, co[pos + 5], co[pos + 1], co[pos + 17], 5)
                    co[pos + 4] = co[pos + 13]
                    return pos + 20
                end

                -- t[cell.v] = function() ... end
                --   GETLOCAL src ; SETLOCAL cellreg ; CELL cellreg ; GETLOCAL t ;
                --   GETCELL cellreg ; SETLOCAL ktmp ; SETLOCAL ttmp ; CLOSURE proto ;
                --   SETINDEX ttmp ktmp
                if co[pos] == GETLOCAL and co[pos + 4] == SETLOCAL and
                   co[pos + 8] == CELL and co[pos + 12] == GETLOCAL and
                   co[pos + 16] == GETCELL and co[pos + 20] == SETLOCAL and
                   co[pos + 24] == SETLOCAL and co[pos + 28] == CLOSURE and
                   co[pos + 32] == SETINDEX and
                   co[pos + 5] == co[pos + 9] and co[pos + 5] == co[pos + 17] and
                   co[pos + 33] == co[pos + 25] and
                   co[pos + 34] == co[pos + 21] and
                   co[pos + 21] ~= co[pos + 13] and
                   co[pos + 25] ~= co[pos + 13] and
                   co[pos + 13] ~= co[pos + 5] and
                   co[pos + 13] ~= co[pos + 1] and
                   can(pos, 9) then
                    put(pos, FOP.SETINDEX_CLOSURE_CELL,
                        co[pos + 5], co[pos + 1], co[pos + 13], 9)
                    co[pos + 4] = co[pos + 29]
                    return pos + 36
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
                -- generic for (2 variables): GETLOCAL freg .. JMPNIL_LOCAL creg
                if pos + 52 <= n and co[pos] == GETLOCAL and
                   co[pos + 4] == MARK and co[pos + 8] == GETLOCAL and
                   co[pos + 12] == GETLOCAL and co[pos + 16] == CALLD and
                   co[pos + 18] == 2 and co[pos + 20] == PEEK and
                   co[pos + 24] == SETLOCAL and
                   (co[pos + 28] == NOP or co[pos + 28] == CELL) and
                   co[pos + 32] == SETLOCAL and
                   (co[pos + 36] == NOP or co[pos + 36] == CELL) and
                   co[pos + 40] == FOP.MOVLOCAL and
                   co[pos + 48] == GETLOCAL and co[pos + 52] == JMPNIL and
                   can(pos, 11) and not targets[pos + 48] and not targets[pos + 52] then
                    local freg = co[pos + 1]
                    if co[pos + 9] == freg + 1 and co[pos + 13] == freg + 2 and
                       co[pos + 33] == freg + 3 and co[pos + 25] == freg + 4 and
                       co[pos + 41] == freg + 2 and co[pos + 49] == freg + 2 then
                        put(pos + 48, FOP.JMPNIL_LOCAL, freg + 2, co[pos + 53], 0, 2)
                        co[pos] = FOP.TFOR_2
                        co[pos + 1] = freg
                        co[pos + 2] = (co[pos + 28] == CELL or co[pos + 36] == CELL) and 1 or 0
                        co[pos + 3] = 0
                        return pos + 56
                    end
                end

                -- generic for (1 variable): GETLOCAL freg .. JMPNIL_LOCAL creg
                if pos + 44 <= n and co[pos] == GETLOCAL and
                   co[pos + 4] == MARK and co[pos + 8] == GETLOCAL and
                   co[pos + 12] == GETLOCAL and co[pos + 16] == CALLD and
                   co[pos + 18] == 1 and co[pos + 20] == PEEK and
                   co[pos + 24] == SETLOCAL and
                   (co[pos + 28] == NOP or co[pos + 28] == CELL) and
                   co[pos + 32] == FOP.MOVLOCAL and
                   co[pos + 40] == GETLOCAL and co[pos + 44] == JMPNIL and
                   can(pos, 9) and not targets[pos + 40] and not targets[pos + 44] then
                    local freg = co[pos + 1]
                    if co[pos + 9] == freg + 1 and co[pos + 13] == freg + 2 and
                       co[pos + 25] == freg + 3 and
                       co[pos + 33] == freg + 2 and co[pos + 41] == freg + 2 then
                        put(pos + 40, FOP.JMPNIL_LOCAL, freg + 2, co[pos + 45], 0, 2)
                        co[pos] = FOP.TFOR_1
                        co[pos + 1] = freg
                        co[pos + 2] = (co[pos + 28] == CELL) and 1 or 0
                        co[pos + 3] = 0
                        return pos + 48
                    end
                end

                -- local/local and local/constant comparison directly followed by JMPF
                if co[pos] == GETLOCAL and
                   (co[pos + 4] == GETLOCAL or co[pos + 4] == LOADK) and
                   co[pos + 8] >= EQ and co[pos + 8] <= GE and
                   co[pos + 12] == JMPF and
                   can_tail(pos, 4) then
                    local kind = co[pos + 8]
                    local fused
                    if co[pos + 4] == GETLOCAL then
                        fused = FOP.JMPF_CMP_RR
                    else
                        fused = FOP.JMPF_CMP_RK
                    end
                    put(pos, fused, co[pos + 1], co[pos + 5], co[pos + 13], 4)
                    co[pos + 4] = kind
                    return pos + 16
                end

                -- local/local and local/constant comparison directly followed by TESTF/TESTT
                if co[pos] == GETLOCAL and
                   (co[pos + 4] == GETLOCAL or co[pos + 4] == LOADK) and
                   co[pos + 8] >= EQ and co[pos + 8] <= GE and
                   (co[pos + 12] == TESTF or co[pos + 12] == TESTT) and
                   can_tail(pos, 4) then
                    local cop = co[pos + 8]
                    local op2
                    if co[pos + 12] == TESTF then
                        op2 = (co[pos + 4] == GETLOCAL) and FOP.TESTF_CMP_RR or FOP.TESTF_CMP_RK
                    else
                        op2 = (co[pos + 4] == GETLOCAL) and FOP.TESTT_CMP_RR or FOP.TESTT_CMP_RK
                    end
                    put(pos, op2, co[pos + 1], co[pos + 5], co[pos + 13], 4)
                    co[pos + 4] = cop
                    return pos + 16
                end

                -- t[k] = { field = local }
                if pos + 36 <= n and co[pos] == GETLOCAL and
                   co[pos + 4] == FOP.MOVLOCAL and co[pos + 12] == SETLOCAL and
                   co[pos + 16] == NEWTABLE and co[pos + 20] == SETLOCAL and
                   (co[pos + 24] == GETLOCAL or co[pos + 24] == LOADK) and
                   co[pos + 28] == SETFIELD and co[pos + 29] == co[pos + 21] and
                   co[pos + 32] == GETLOCAL and co[pos + 33] == co[pos + 21] and
                   co[pos + 36] == SETINDEX and
                   not targets[pos + 4] and not targets[pos + 12] and
                   not targets[pos + 16] and not targets[pos + 20] and
                   not targets[pos + 24] and not targets[pos + 28] and
                   not targets[pos + 32] and not targets[pos + 36] then
                    local t = co[pos + 1]
                    local keytemp = co[pos + 5]
                    local k = co[pos + 6]
                    local basetemp = co[pos + 13]
                    local treg = co[pos + 21]
                    local v = co[pos + 25]
                    local fkey = co[pos + 30]
                    if co[pos + 24] == GETLOCAL and
                       co[pos + 37] == basetemp and co[pos + 38] == keytemp and
                       t ~= keytemp and t ~= basetemp and
                       k ~= keytemp and k ~= basetemp and
                       v ~= keytemp and v ~= basetemp and v ~= treg then
                        co[pos + 25] = fkey
                        put(pos, FOP.NEWTABLE_SETINDEX_R, t, k, v, 10)
                        return pos + 40
                    end
                end

                -- single-field table constructor: { field = local/const }
                if pos + 16 <= n and co[pos] == NEWTABLE and
                   co[pos + 4] == SETLOCAL and
                   (co[pos + 8] == GETLOCAL or co[pos + 8] == LOADK) and
                   co[pos + 12] == SETFIELD and co[pos + 13] == co[pos + 5] and
                   not targets[pos + 4] and not targets[pos + 8] and
                   not targets[pos + 12] and not targets[pos + 16] then
                    local treg = co[pos + 5]
                    local v = co[pos + 9]
                    local k = co[pos + 14]
                    if co[pos + 8] ~= GETLOCAL or v ~= treg then
                        local op = co[pos + 8] == GETLOCAL and FOP.NEWTABLE_FIELD_R or FOP.NEWTABLE_FIELD_K
                        if co[pos + 16] == FOP.MOVLOCAL and co[pos + 18] == treg and
                           pos + 20 <= n and not targets[pos + 20] then
                            put(pos, op, k, v, co[pos + 17], 6)
                            return pos + 24
                        elseif co[pos + 16] == GETLOCAL and co[pos + 17] == treg then
                            put(pos, op, k, v, 0, 5)
                            return pos + 20
                        end
                    end
                end

                -- `{v, v + k1, v + k2}` from the original constructor
                -- sequence, before the smaller SETLIST fusions split it up.
                if pos + 60 <= n and co[pos] == NEWTABLE and
                   co[pos + 4] == SETLOCAL and
                   co[pos + 8] == MARK and co[pos + 12] == GETLOCAL and
                   co[pos + 16] == SETLIST and co[pos + 18] == 1 and
                   co[pos + 20] == MARK and co[pos + 24] == GETLOCAL and
                   co[pos + 28] == LOADK and co[pos + 32] == ADD and
                   co[pos + 36] == SETLIST and co[pos + 38] == 2 and
                   co[pos + 40] == MARK and co[pos + 44] == GETLOCAL and
                   co[pos + 48] == LOADK and co[pos + 52] == ADD and
                   co[pos + 56] == SETLIST and co[pos + 58] == 3 and
                   no_targets(pos, 15) then
                    local treg = co[pos + 5]
                    local v = co[pos + 13]
                    local k1 = co[pos + 29]
                    local k2 = co[pos + 49]
                    if co[pos + 17] == treg and co[pos + 25] == v and
                       co[pos + 37] == treg and co[pos + 45] == v and
                       co[pos + 57] == treg then
                        put(pos, FOP.NEWTABLE_LIST3_RK, treg, v, k1, 15)
                        co[pos + 4] = k2
                        return pos + 60
                    end
                end

                -- table allocation directly into local register
                if pos + 68 <= n and co[pos] == NEWTABLE and
                   co[pos + 4] == SETLOCAL and
                   co[pos + 8] == MARK and co[pos + 12] == GETLOCAL and
                   co[pos + 16] == SETLIST and co[pos + 18] == 1 and
                   co[pos + 20] == MARK and co[pos + 24] == GETLOCAL and
                   co[pos + 28] == LOADK and co[pos + 32] == ADD and
                   co[pos + 36] == SETLIST and co[pos + 38] == 2 and
                   co[pos + 40] == MARK and co[pos + 44] == GETLOCAL and
                   co[pos + 48] == LOADK and co[pos + 52] == ADD and
                   co[pos + 56] == SETLIST and co[pos + 58] == 3 and
                   co[pos + 60] == FOP.MOVLOCAL_NOP and
                   co[pos + 62] == co[pos + 5] and
                   not targets[pos + 4] and not targets[pos + 8] and
                   not targets[pos + 12] and not targets[pos + 16] and
                   not targets[pos + 20] and not targets[pos + 24] and
                   not targets[pos + 28] and not targets[pos + 32] and
                   not targets[pos + 36] and not targets[pos + 40] and
                   not targets[pos + 44] and not targets[pos + 48] and
                   not targets[pos + 52] and not targets[pos + 56] and
                   not targets[pos + 60] then
                    local treg = co[pos + 5]
                    local mreg = co[pos + 9]
                    local v = co[pos + 13]
                    local dest = co[pos + 61]
                    if co[pos + 17] == treg and co[pos + 37] == treg and
                       co[pos + 57] == treg and co[pos + 25] == v and
                       co[pos + 45] == v and v ~= treg and v ~= mreg then
                        if pos + 92 <= n and co[pos + 72] == GETLOCAL and
                           co[pos + 76] == GETLOCAL and co[pos + 77] == dest and
                           co[pos + 80] == LOADK and co[pos + 84] == INDEX and
                           co[pos + 88] == ADD and co[pos + 92] == SETLOCAL and
                           co[pos + 93] == co[pos + 73] and
                           co[pos + 96] == FOP.FORLOOP_MOV and
                           co[pos + 73] ~= dest and
                           not targets[pos + 72] and not targets[pos + 76] and
                           not targets[pos + 80] and not targets[pos + 84] and
                           not targets[pos + 88] and not targets[pos + 92] then
                            co[pos + 77] = co[pos + 81]
                            put(pos, FOP.NEWTABLE_LIST3_ADD_RK, dest, v, co[pos + 73], 24)
                            return pos + 96
                        end
                        put(pos, FOP.NEWTABLE_LIST3_ADD_RK, dest, v, 0, 18)
                        return pos + 72
                    end
                end

                if co[pos] == NEWTABLE and co[pos + 4] == SETLOCAL and
                   can(pos, 2) then
                    put(pos, FOP.NEWTABLE_LOCAL, co[pos + 5], 0, 0, 2)
                    return pos + 8
                end

                -- list constructor elements: MARK + (GETLOCAL | LOADK) + SETLIST
                if pos + 8 <= n and co[pos] == MARK and
                   (co[pos + 4] == GETLOCAL or co[pos + 4] == LOADK) and
                   co[pos + 8] == SETLIST and can(pos, 3) then
                    local mreg = co[pos + 1]
                    local treg = co[pos + 9]
                    local idx = co[pos + 10]
                    local v = co[pos + 5]
                    if co[pos + 4] == GETLOCAL then
                        if v ~= mreg then
                            put(pos, FOP.SETLIST_R, treg, idx, v, 3)
                            return pos + 12
                        end
                    else
                        put(pos, FOP.SETLIST_K, treg, idx, v, 3)
                        return pos + 12
                    end
                end

                -- list constructor elements: MARK + GETLOCAL + LOADK + ADD + SETLIST
                if pos + 16 <= n and co[pos] == MARK and
                   co[pos + 4] == GETLOCAL and
                   co[pos + 8] == LOADK and
                   co[pos + 12] == ADD and co[pos + 16] == SETLIST and
                   can(pos, 5) then
                    local mreg = co[pos + 1]
                    local treg = co[pos + 17]
                    local idx = co[pos + 18]
                    local a = co[pos + 5]
                    if a ~= mreg then
                        put(pos, FOP.SETLIST_ADD_RK, treg, idx, a, 5)
                        return pos + 20
                    end
                end

                -- constant comparison directly followed by JMPF
                if co[pos] == LOADK and co[pos + 4] >= EQ and co[pos + 4] <= GE and
                   co[pos + 8] == JMPF and can(pos, 3) then
                    local kind = co[pos + 4]
                    put(pos, FOP.JMPF_CMP_K, co[pos + 1], co[pos + 9], 0, 3)
                    co[pos + 4] = kind
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

                -- global.field, e.g. math.sqrt or string.sub
                if co[pos] == GETGLOBAL and co[pos + 4] == FIELD and
                   can(pos, 2) then
                    put(pos, FOP.GETGLOBAL_FIELD, co[pos + 1], co[pos + 5], 0, 2)
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

                -- GETUPVAL + MARK + GETLOCAL + GETLOCAL + CALLD
                if pos + 16 <= n and co[pos] == GETUPVAL and
                   co[pos + 4] == MARK and
                   co[pos + 8] == GETLOCAL and
                   co[pos + 12] == GETLOCAL and
                   co[pos + 16] == CALLD and
                   co[pos + 17] == co[pos + 5] and
                   co[pos + 19] == 0 and
                   (pos + 20 > n or co[pos + 20] ~= PEEK) and
                   can(pos, 5) then
                    local u = co[pos + 1]
                    local a = co[pos + 9]
                    local b = co[pos + 13]
                    local nres = co[pos + 18]
                    put(pos, FOP.CALL_U_RR2, u, a, b, 5)
                    co[pos + 4] = nres
                    return pos + 20
                end

                -- GETUPVAL + MARK + GETLOCAL + CALLD
                if pos + 12 <= n and co[pos] == GETUPVAL and
                   co[pos + 4] == MARK and
                   co[pos + 8] == GETLOCAL and
                   co[pos + 12] == CALLD and
                   co[pos + 13] == co[pos + 5] and
                   co[pos + 15] == 0 and
                   (pos + 16 > n or co[pos + 16] ~= PEEK) and
                   can(pos, 4) then
                    local u = co[pos + 1]
                    local a = co[pos + 9]
                    local nres = co[pos + 14]
                    put(pos, FOP.CALL_U_RR1, u, a, 0, 4)
                    co[pos + 4] = nres
                    return pos + 16
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

            -- Left-to-right arithmetic chains: `k <op> a`, `<stack> <op> a`,
            -- `<stack> <op> k`. These run after the register/register and
            -- register/constant fusions, which cover the leftmost-operand cases.
            for pc = 1, n, 4 do
                if not dead[pc] then
                    local bop = co[pc + 8]
                    if pc + 8 <= n and co[pc] == LOADK and co[pc + 4] == GETLOCAL and
                       not dead[pc + 4] and not dead[pc + 8] and
                       bop >= ADD and bop <= CONCAT and can(pc, 3) then
                        local kind = bop
                        put(pc, FOP.PUSH_OP_RK, co[pc + 1], co[pc + 5], 0, 3)
                        co[pc + 4] = kind
                    else
                        local op2 = co[pc + 4]
                        if pc + 4 <= n and op2 >= ADD and op2 <= CONCAT and not dead[pc + 4] then
                            if co[pc] == GETLOCAL and can(pc, 2) then
                                local r = co[pc + 1]
                                put(pc, FOP.PUSH_OP_RS, r, 0, 0, 2)
                                co[pc + 4] = op2
                            elseif co[pc] == LOADK and can(pc, 2) then
                                local k = co[pc + 1]
                                put(pc, FOP.PUSH_OP_KS, k, 0, 0, 2)
                                co[pc + 4] = op2
                            end
                        end
                    end
                end
            end

            -- `v[j + k]`: GETLOCAL v; ADD_RK j k; INDEX.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 16 <= n and
                   co[pc] == GETLOCAL and
                   not dead[pc + 4] and co[pc + 4] == FOP.ADD_RK and
                   dead[pc + 8] and dead[pc + 12] and
                   not dead[pc + 16] and co[pc + 16] == INDEX and
                   no_targets(pc, 5) then
                    put(pc, FOP.INDEX_ADD_RK, co[pc + 1], co[pc + 5], co[pc + 6], 5)
                end
            end

            -- `dest = c + b * a` left on the expression stack by MUL; ADD; SETLOCAL.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 8 <= n and
                   co[pc] == MUL and
                   not dead[pc + 4] and co[pc + 4] == ADD and
                   not dead[pc + 8] and co[pc + 8] == SETLOCAL and
                   no_targets(pc, 3) then
                    put(pc, FOP.MUL_ADD_SETLOCAL, co[pc + 9], 0, 0, 3)
                end
            end

            -- `t[k] <op> v` followed by JMPF, with an upvalue/local table
            -- and a local/constant right operand.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 20 <= n and
                   (co[pc] == GETUPVAL or co[pc] == GETLOCAL) and
                   co[pc + 4] == GETLOCAL and
                   co[pc + 8] == INDEX and
                   (co[pc + 12] == GETLOCAL or co[pc + 12] == LOADK) and
                   co[pc + 16] >= EQ and co[pc + 16] <= GE and
                   co[pc + 20] == JMPF and
                   no_targets(pc, 6) then
                    local td = co[pc] == GETUPVAL and -co[pc + 1] or co[pc + 1]
                    local kd = co[pc + 5]
                    local vd = co[pc + 12] == LOADK and -co[pc + 13] or co[pc + 13]
                    local kind = co[pc + 16]
                    local target = co[pc + 21]
                    put(pc, FOP.INDEX_CMP_JMPF, td, kd, vd, 6)
                    co[pc + 4] = kind
                    co[pc + 5] = target
                end
            end

            -- Same comparison when `GETLOCAL t; GETLOCAL k; INDEX` was already
            -- folded into INDEX_RR.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 20 <= n and
                   co[pc] == FOP.INDEX_RR and
                   (co[pc + 12] == GETLOCAL or co[pc + 12] == LOADK) and
                   co[pc + 16] >= EQ and co[pc + 16] <= GE and
                   co[pc + 20] == JMPF and
                   no_targets(pc, 6) then
                    local td = co[pc + 1]
                    local kd = co[pc + 2]
                    local vd = co[pc + 12] == LOADK and -co[pc + 13] or co[pc + 13]
                    local kind = co[pc + 16]
                    local target = co[pc + 21]
                    put(pc, FOP.INDEX_CMP_JMPF, td, kd, vd, 6)
                    co[pc + 4] = kind
                    co[pc + 5] = target
                end
            end

            -- `v[j + k]` pushed immediately before a two-argument upvalue call.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 20 <= n and
                   co[pc] == FOP.INDEX_ADD_RK and
                   not dead[pc + 20] and co[pc + 20] == FOP.CALL_U_RR2 and
                   co[pc + 24] == 1 and
                   no_targets(pc, 10) then
                    put(pc, FOP.INDEX_ADD_RK_CALL_U_RR2,
                        co[pc + 1], co[pc + 2], co[pc + 3], 10)
                    co[pc + 4] = co[pc + 21]
                    co[pc + 5] = co[pc + 22]
                    co[pc + 6] = co[pc + 23]
                    co[pc + 7] = 1
                end
            end

            -- `dest = c + b * a` immediately followed by the numeric-for back-edge.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 12 <= n and
                   co[pc] == FOP.MUL_ADD_SETLOCAL and
                   not dead[pc + 12] and co[pc + 12] == FOP.FORLOOP_MOV and
                   no_targets(pc, 4) then
                    put(pc, FOP.MUL_ADD_SETLOCAL_FORLOOP,
                        co[pc + 1], co[pc + 13], co[pc + 14], 4)
                    co[pc + 4] = co[pc + 15]
                end
            end

            -- `acc = acc + v * (a / b)` at the end of a numeric for.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 4 <= n and
                   co[pc] == DIV and
                   not dead[pc + 4] and
                   co[pc + 4] == FOP.MUL_ADD_SETLOCAL_FORLOOP and
                   no_targets(pc, 5) then
                    put(pc, FOP.DIV_MUL_ADD_SETLOCAL_FORLOOP,
                        co[pc + 5], co[pc + 6], co[pc + 7], 5)
                    co[pc + 4] = co[pc + 8]
                end
            end

            -- `k / x` followed by the loop-end multiply/add/store.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 4 <= n and
                   co[pc] == FOP.DIV_K and
                   not dead[pc + 4] and
                   co[pc + 4] == FOP.MUL_ADD_SETLOCAL_FORLOOP and
                   no_targets(pc, 5) then
                    put(pc, FOP.DIV_K_MUL_ADD_SETLOCAL_FORLOOP,
                        co[pc + 1], co[pc + 5], co[pc + 6], 5)
                    co[pc + 4] = co[pc + 7]
                    co[pc + 5] = co[pc + 8]
                end
            end

            -- `dest = (a - b) + c`: SUB_RR + PUSH_OP_RS(ADD) + SETLOCAL.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 20 <= n and
                   co[pc] == FOP.SUB_RR and
                   not dead[pc + 12] and co[pc + 12] == FOP.PUSH_OP_RS and
                   co[pc + 16] == 13 and
                   not dead[pc + 20] and co[pc + 20] == SETLOCAL and
                   no_targets(pc, 6) then
                    put(pc, FOP.ASSIGN_SUB_ADD, co[pc + 21], co[pc + 1], co[pc + 2], 6)
                    co[pc + 4] = co[pc + 13]
                end
            end

            -- `(a + b) <op> k` followed by JMPF.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 20 <= n and
                   co[pc] == FOP.ADD_RR and
                   not dead[pc + 12] and co[pc + 12] == FOP.JMPF_CMP_K and
                   co[pc + 16] >= EQ and co[pc + 16] <= GE and
                   no_targets(pc, 6) then
                    put(pc, FOP.ADD_JMPF_K, co[pc + 1], co[pc + 2], co[pc + 13], 6)
                    co[pc + 4] = co[pc + 16]
                    co[pc + 5] = co[pc + 14]
                end
            end

            -- `t[a][b]`: INDEX_RR then GETLOCAL key2 then INDEX.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 16 <= n and
                   co[pc] == FOP.INDEX_RR and
                   not dead[pc + 12] and co[pc + 12] == GETLOCAL and
                   not dead[pc + 16] and co[pc + 16] == INDEX and
                   no_targets(pc, 5) then
                    put(pc, FOP.INDEX_INDEX_RR, co[pc + 1], co[pc + 2], co[pc + 13], 5)
                end
            end

            -- Higher-order arithmetic fusions
            for pc = 1, n, 4 do
                if not dead[pc] then
                    -- PUSH_OP_RS + ADD -> PUSH_OP_RS_ADD
                    if pc + 8 <= n and co[pc] == FOP.PUSH_OP_RS and
                       not dead[pc + 8] and co[pc + 8] == ADD and
                       not targets[pc + 8] then
                        put(pc, FOP.PUSH_OP_RS_ADD, co[pc + 1], co[pc + 4], 0, 3)
                    -- ADD_RR + PUSH_OP_KS(ADD) -> ADD_RR_ADD_K
                    elseif pc + 16 <= n and co[pc] == FOP.ADD_RR and
                       not dead[pc + 12] and co[pc + 12] == FOP.PUSH_OP_KS and
                       co[pc + 16] == 13 and not targets[pc + 12] then
                        local r1 = co[pc + 1]
                        local r2 = co[pc + 2]
                        local k = co[pc + 13]
                        put(pc, FOP.ADD_RR_ADD_K, r1, r2, k, 5)
                    -- PUSH_OP_RS(ADD) + PUSH_OP_KS(ADD) -> ADD_R_ADD_K
                    elseif pc + 12 <= n and co[pc] == FOP.PUSH_OP_RS and co[pc + 4] == 13 and
                           not dead[pc + 8] and co[pc + 8] == FOP.PUSH_OP_KS and
                           co[pc + 12] == 13 and not targets[pc + 8] then
                        local r = co[pc + 1]
                        local k = co[pc + 9]
                        put(pc, FOP.ADD_R_ADD_K, r, k, 0, 4)
                    -- MUL + PUSH_OP_KS(DIV) -> MUL_DIV_K
                    elseif pc + 8 <= n and co[pc] == MUL and
                           not dead[pc + 4] and co[pc + 4] == FOP.PUSH_OP_KS and
                           co[pc + 8] == 16 and not targets[pc + 4] then
                        local k = co[pc + 5]
                        put(pc, FOP.MUL_DIV_K, k, 0, 0, 3)
                    -- DIV + RET 1 -> DIV_RET
                    elseif pc + 4 <= n and co[pc] == DIV and
                           not dead[pc + 4] and co[pc + 4] == RET and
                           co[pc + 5] == 1 and not targets[pc + 4] then
                        put(pc, FOP.DIV_RET, 1, 0, 0, 2)
                    end
                end
            end

            -- nbody-style indexed update with upvalues:
            -- GETUPVAL t; LOADK k; INDEX; GETUPVAL x; PUSH_OP_RS y(MUL);
            -- GETUPVAL z; MUL; SUB/ADD; SETINDEX.
            -- GETUPVAL t; LOADK k; INDEX; GETUPVAL x; PUSH_OP_RS y(MUL);
            -- GETUPVAL z; MUL; SUB/ADD; SETINDEX.
            for pc = 17, n, 4 do
                if not dead[pc] and pc + 36 <= n and
                   co[pc] == GETUPVAL and
                   co[pc + 4] == LOADK and
                   co[pc + 8] == INDEX and
                   co[pc + 12] == GETUPVAL and
                   not dead[pc + 16] and co[pc + 16] == FOP.PUSH_OP_RS and
                   co[pc + 20] == 15 and
                   co[pc + 24] == GETUPVAL and
                   co[pc + 28] == MUL and
                   not dead[pc + 32] and
                   (co[pc + 32] == SUB or co[pc + 32] == ADD) and
                   not dead[pc + 36] and co[pc + 36] == SETINDEX and
                   not dead[pc - 16] and co[pc - 16] == GETUPVAL and
                   co[pc - 15] == co[pc + 1] and
                   not dead[pc - 12] and co[pc - 12] == FOP.SETLOCAL_K and
                   co[pc - 11] == co[pc + 38] and
                   co[pc - 10] == co[pc + 5] and
                   dead[pc - 8] and
                   not dead[pc - 4] and co[pc - 4] == SETLOCAL and
                   co[pc - 3] == co[pc + 37] and
                   no_targets(pc - 16, 5) and
                   no_targets(pc, 10) then
                    local sign = co[pc + 32] == SUB and 0 or 1
                    local table_reg = co[pc + 37]
                    local key_reg = co[pc + 38]
                    local xd = -co[pc + 13]
                    local yd = co[pc + 17]
                    local zd = -co[pc + 25]
                    put(pc, FOP.SETINDEX_MUL3, table_reg, key_reg, sign, 10)
                    co[pc + 4] = xd
                    co[pc + 5] = yd
                    co[pc + 6] = zd
                end
            end

            -- Two-term indexed update: t[k] = t[k] +/- a * t[k2].
            for pc = 17, n, 4 do
                if not dead[pc] and pc + 36 <= n and
                   co[pc] == GETUPVAL and
                   co[pc + 4] == LOADK and
                   co[pc + 8] == INDEX and
                   co[pc + 12] == GETLOCAL and
                   co[pc + 16] == GETUPVAL and
                   co[pc + 20] == LOADK and
                   co[pc + 24] == INDEX and
                   co[pc + 28] == MUL and
                   not dead[pc + 32] and
                   (co[pc + 32] == SUB or co[pc + 32] == ADD) and
                   not dead[pc + 36] and co[pc + 36] == SETINDEX and
                   not dead[pc - 16] and co[pc - 16] == GETUPVAL and
                   co[pc - 15] == co[pc + 1] and
                   not dead[pc - 12] and co[pc - 12] == FOP.SETLOCAL_K and
                   co[pc - 11] == co[pc + 38] and
                   co[pc - 10] == co[pc + 5] and
                   dead[pc - 8] and
                   not dead[pc - 4] and co[pc - 4] == SETLOCAL and
                   co[pc - 3] == co[pc + 37] and
                   no_targets(pc - 16, 5) and
                   no_targets(pc, 10) then
                    local sign = co[pc + 32] == SUB and 0 or 1
                    local table_reg = co[pc + 37]
                    local key_reg = co[pc + 38]
                    local ad = co[pc + 13]
                    local kd = -co[pc + 21]
                    put(pc, FOP.SETINDEX_MUL2, table_reg, key_reg, sign, 10)
                    co[pc + 4] = ad
                    co[pc + 5] = kd
                end
            end

            -- `dest = k * a * b +/- c`, the mandelbrot inner assignment.
            for pc = 1, n, 4 do
                if not dead[pc] and pc + 28 <= n and
                   co[pc] == FOP.PUSH_OP_RK and co[pc + 4] == 15 and
                   not dead[pc + 12] and co[pc + 12] == FOP.PUSH_OP_RS and
                   co[pc + 16] == 15 and
                   not dead[pc + 20] and co[pc + 20] == FOP.PUSH_OP_RS and
                   co[pc + 24] == 13 and
                   not dead[pc + 28] and co[pc + 28] == SETLOCAL and
                   no_targets(pc, 8) then
                    local fused = FOP.ASSIGN_MUL3_ADD
                    local dest = co[pc + 29]
                    local k = co[pc + 1]
                    local b = co[pc + 2]
                    local c = co[pc + 13]
                    local d = co[pc + 21]
                    put(pc, fused, dest, k, b, 8)
                    co[pc + 4] = c
                    co[pc + 5] = d
                end
            end

            -- Fold `(value % K) == K2` and `(value % reg) == K2` + JMPF into one branch.
            for pc = 1, n, 4 do
                local jop = co[pc + 12]
                if (co[pc] == FOP.MOD_RK or co[pc] == FOP.MOD_RR) and
                   pc + 20 <= n and
                   (jop == FOP.JMPF_CMP_K and co[pc + 16] == EQ) and
                   not dead[pc] and not targets[pc + 4] and
                   not targets[pc + 8] and not targets[pc + 12] and
                   not targets[pc + 20] then
                    local r = co[pc + 1]
                    local kmod = co[pc + 2]
                    local keq = co[pc + 13]
                    co[pc] = co[pc] == FOP.MOD_RK and FOP.JMPF_MOD_EQ_K or FOP.JMPF_MOD_RR_EQ_K
                    co[pc + 1] = r
                    co[pc + 2] = kmod
                    co[pc + 3] = keq
                    for i = 1, 5 do
                        dead[pc + i * 4] = true
                    end
                end
            end

            -- Fold the first body operation into FORLOOP as well. This
            -- removes one dispatch per iteration for the hot numeric-loop
            -- patterns `sum = sum + i`, `t[i] = i`, and similar.
            for pc = 1, n, 4 do
                if co[pc] == FOP.FORLOOP_MOV then
                    local ctrl = co[pc + 1]
                    local dest = co[pc + 2]
                    local body = co[pc + 3] - 12
                    if body >= 1 and body + 28 <= n and
                       not dead[body] and not dead[body + 12] and
                       co[body + 2] == ctrl then
                        local bop = co[body + 12]
                        local fused, nxt
                        if bop == FOP.ASSIGN_RR and co[body + 16] == 13 then
                            fused, nxt = FOP.FORLOOP_ADD_RR, body + 28
                        elseif bop == FOP.ASSIGN_RK and co[body + 16] == 13 then
                            fused, nxt = FOP.FORLOOP_ADD_RK, body + 28
                        elseif bop == FOP.ASSIGN_INDEX and co[body + 16] == 13 and
                               body + 36 <= n then
                            fused, nxt = FOP.FORLOOP_ADD_INDEX, body + 36
                        elseif bop == FOP.SETINDEX_RR and
                               body + 36 <= n then
                            fused, nxt = FOP.FORLOOP_SETINDEX_RR, body + 36
                        elseif bop == FOP.SETINDEX_RK and
                               body + 36 <= n then
                            fused, nxt = FOP.FORLOOP_SETINDEX_RK, body + 36
                        elseif bop == FOP.ASSIGN_RR and co[body + 16] == 14 then
                            fused, nxt = FOP.FORLOOP_SUB_RR, body + 28
                        elseif bop == FOP.ASSIGN_RK and co[body + 16] == 14 then
                            fused, nxt = FOP.FORLOOP_SUB_RK, body + 28
                        elseif bop == FOP.ASSIGN_RR and co[body + 16] >= 15 and
                               co[body + 16] <= 19 then
                            fused, nxt = FOP.FORLOOP_ASSIGN_RR, body + 28
                        elseif bop == FOP.ASSIGN_RK and co[body + 16] >= 15 and
                               co[body + 16] <= 19 then
                            fused, nxt = FOP.FORLOOP_ASSIGN_RK, body + 28
                        elseif bop == FOP.JMPF_MOD_RR_EQ_K and
                               body + 36 <= n then
                            fused, nxt = FOP.FORLOOP_MOD_RR_EQ_K, body + 36
                        elseif bop == FOP.NEWTABLE_SETINDEX_R and
                               body + 52 <= n then
                            fused, nxt = FOP.FORLOOP_NEWTABLE_SETINDEX_R, body + 52
                        end
                        if fused then
                            co[pc] = fused
                            co[pc + 1] = ctrl
                            co[pc + 2] = dest
                            co[pc + 3] = body
                            targets[nxt] = true
                        end
                    end
                end
            end

            -- Sieve-style numeric loop: `for i = ..., ... do t[i] = true end`.
            -- Body: GETLOCAL t; MOVLOCAL kc i; SETLOCAL tc; LOADBOOL 1; SETINDEX tc kc.
            for pc = 1, n, 4 do
                if co[pc] == FOP.FORLOOP_MOV and not dead[pc] then
                    local dest = co[pc + 2]
                    local body = co[pc + 3]
                    if body >= 1 and body + 24 == pc and body + 24 <= n and
                       not dead[body] and co[body] == GETLOCAL and
                       not dead[body + 4] and co[body + 4] == FOP.MOVLOCAL and
                       co[body + 5] == co[body + 22] and
                       co[body + 6] == dest and
                       dead[body + 8] and
                       not dead[body + 12] and co[body + 12] == SETLOCAL and
                       co[body + 13] == co[body + 21] and
                       co[body + 16] == LOADBOOL and co[body + 17] == 1 and
                       not dead[body + 20] and co[body + 20] == SETINDEX and
                       no_targets(body, 6) then
                        co[pc] = FOP.FORLOOP_SETTRUE
                    end
                end
            end

            -- `t[i], t[j] = t[j], t[i]` after the first pass has fused the
            -- indexed reads into INDEX_RR.  Keep this in a second pass: at
            -- the assignment's first instruction the future INDEX_RR pair
            -- does not exist yet.
            local spos = 1
            while spos <= n do
                if not dead[spos] and spos + 64 <= n and
                   co[spos] == GETLOCAL and
                   co[spos + 4] == FOP.MOVLOCAL and
                   co[spos + 12] == SETLOCAL and
                   co[spos + 16] == GETLOCAL and
                   co[spos + 20] == FOP.MOVLOCAL and
                   co[spos + 28] == SETLOCAL and
                   co[spos + 32] == FOP.INDEX_RR and
                   co[spos + 44] == FOP.INDEX_RR and
                   co[spos + 56] == SETINDEX and
                   co[spos + 60] == SETINDEX and
                   no_targets(spos, 16) then
                    local table_reg = co[spos + 1]
                    local k1_temp = co[spos + 5]
                    local k1_src = co[spos + 6]
                    local base1 = co[spos + 13]
                    local table2 = co[spos + 17]
                    local k2_temp = co[spos + 21]
                    local k2_src = co[spos + 22]
                    local base2 = co[spos + 29]
                    local idx1_table = co[spos + 33]
                    local idx1_key = co[spos + 34]
                    local idx2_table = co[spos + 45]
                    local idx2_key = co[spos + 46]
                    local set2_base = co[spos + 57]
                    local set2_key = co[spos + 58]
                    local set1_base = co[spos + 61]
                    local set1_key = co[spos + 62]
                    if table_reg == table2 and
                       idx1_table == table_reg and idx2_table == table_reg and
                       k1_temp == set1_key and k2_temp == set2_key and
                       base1 == set1_base and base2 == set2_base and
                       k1_src == idx2_key and k2_src == idx1_key then
                        put(spos, FOP.SWAP_INDEX, table_reg, k1_src, k2_src, 16)
                        spos = spos + 64
                    else
                        spos = spos + 4
                    end
                else
                    spos = spos + 4
                end
            end

            -- Fold back-edge JMP into JMPT_CMP_* (while/repeat loop fusion)
            for pc = 1, n, 4 do
                if co[pc] == JMP then
                    local target = co[pc + 1]
                    if target >= 1 and target <= n and not dead[target] then
                        local top = co[target]
                        if top == FOP.JMPF_CMP_RR then
                            local r1 = co[target + 1]
                            local r2 = co[target + 2]
                            local exit_pc = co[target + 3]
                            local cop = co[target + 4]
                            local body_pc = target + 16
                            if exit_pc == pc + 4 and cop >= 23 and cop <= 28 then
                                local op_map = {
                                    [23] = FOP.JMPT_CMP_RR_EQ,
                                    [24] = FOP.JMPT_CMP_RR_NE,
                                    [25] = FOP.JMPT_CMP_RR_LT,
                                    [26] = FOP.JMPT_CMP_RR_LE,
                                    [27] = FOP.JMPT_CMP_RR_GT,
                                    [28] = FOP.JMPT_CMP_RR_GE,
                                }
                                co[pc] = op_map[cop]
                                co[pc + 1] = r1
                                co[pc + 2] = r2
                                co[pc + 3] = body_pc
                                targets[body_pc] = true
                            end
                        elseif top == FOP.JMPF_CMP_RK then
                            local r1 = co[target + 1]
                            local k = co[target + 2]
                            local exit_pc = co[target + 3]
                            local cop = co[target + 4]
                            local body_pc = target + 16
                            if exit_pc == pc + 4 and cop >= 23 and cop <= 28 then
                                local op_map = {
                                    [23] = FOP.JMPT_CMP_RK_EQ,
                                    [24] = FOP.JMPT_CMP_RK_NE,
                                    [25] = FOP.JMPT_CMP_RK_LT,
                                    [26] = FOP.JMPT_CMP_RK_LE,
                                    [27] = FOP.JMPT_CMP_RK_GT,
                                    [28] = FOP.JMPT_CMP_RK_GE,
                                }
                                co[pc] = op_map[cop]
                                co[pc + 1] = r1
                                co[pc + 2] = k
                                co[pc + 3] = body_pc
                                targets[body_pc] = true
                            end
                        end
                    end
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
            if no_tail_call then fc.code[callpc + 3] = 2 end
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

        local function function_proto(kind, ref)
            local idx
            if kind == "local" then
                idx = ref.func_idx
            elseif kind == "upval" then
                local u = fc.upvals[ref]
                idx = u and u.src and u.src.func_idx
            end
            if not idx then return nil end
            return all_protos[idx]
        end

        local function callable_proto(kind, ref)
            local p = function_proto(kind, ref)
            if p and p.simple then return p end
            return nil
        end

        local function try_inline_call(proto)
            local sp, stk, stv, stp, slt = pos, tk, tv, tp, last_tp
            local function restore()
                pos, tk, tv, tp, last_tp = sp, stk, stv, stp, slt
            end
            if tk ~= "(" then return false end
            advance()
            local args = {}
            if tk ~= ")" then
                while true do
                    if tk == "name" then
                        local name = tv
                        advance()
                        local d = find_local(fc, name)
                        if not d then
                            restore()
                            return false
                        end
                        args[#args + 1] = { kind = "local", desc = d }
                    elseif tk == "number" or tk == "string" then
                        args[#args + 1] = { kind = "const", value = tv }
                        advance()
                    else
                        restore()
                        return false
                    end
                    if tk == "," then
                        advance()
                    elseif tk == ")" then
                        break
                    else
                        restore()
                        return false
                    end
                end
            end
            if tk ~= ")" then
                restore()
                return false
            end
            advance()
            if #args ~= proto.numparams then
                restore()
                return false
            end

            for p = 1, proto.rawncode - 11, 4 do
                local op = proto.rawcode[p]
                if op == NOP then
                elseif op == GETLOCAL then
                    local a = proto.rawcode[p + 1]
                    if a < 1 or a > proto.numparams then
                        restore()
                        return false
                    end
                elseif op == LOADK or op == LOADBOOL or op == LOADNIL then
                    if op == LOADBOOL and proto.rawcode[p + 3] ~= 0 then
                        restore()
                        return false
                    end
                elseif (op >= ADD and op <= POW) or
                       op == UNM or op == NOT or op == LEN then
                else
                    restore()
                    return false
                end
            end

            local divk, firstk, divk_idx = false, nil, nil
            local st = {}
            for p = 1, proto.rawncode - 11, 4 do
                local op = proto.rawcode[p]
                if op == NOP then
                elseif op == GETLOCAL or op == LOADK or
                       op == LOADBOOL or op == LOADNIL then
                    local tag = "V"
                    if op == LOADK and not firstk then
                        firstk = p
                        tag = "K"
                    end
                    if op == LOADNIL then
                        for _ = 1, proto.rawcode[p + 1] do st[#st + 1] = "V" end
                    else
                        st[#st + 1] = tag
                    end
                elseif op == DIV then
                    local b = table.remove(st)
                    local a = table.remove(st)
                    if p == proto.rawncode - 11 and a == "K" then
                        divk = true
                        divk_idx = addk(proto.consts[proto.rawcode[firstk + 1]])
                    end
                    st[#st + 1] = "V"
                elseif op == UNM or op == NOT or op == LEN then
                    table.remove(st)
                    st[#st + 1] = "V"
                else
                    table.remove(st)
                    table.remove(st)
                    st[#st + 1] = "V"
                end
            end

            local function ins(op, a, b, c, line)
                local pc = emit(op, a, b, c)
                if line then fc.lines[pc] = line end
                return pc
            end

            local inline_start = fc.ncode + 1
            local inline_call_line = line_of(last_tp)

            for p = 1, proto.rawncode - 11, 4 do
                local op = proto.rawcode[p]
                local line = proto.lines and proto.lines[p]
                if op == NOP then
                elseif divk and p == firstk then
                elseif op == GETLOCAL then
                    local arg = args[proto.rawcode[p + 1]]
                    if arg.kind == "local" then
                        local pc = emit_local_get(arg.desc)
                        if line then fc.lines[pc] = line end
                    else
                        ins(LOADK, addk(arg.value), 0, 0, line)
                    end
                elseif op == LOADK then
                    ins(LOADK, addk(proto.consts[proto.rawcode[p + 1]]), 0, 0, line)
                elseif op == LOADBOOL then
                    ins(LOADBOOL, proto.rawcode[p + 1], 0, 0, line)
                elseif op == LOADNIL then
                    ins(LOADNIL, proto.rawcode[p + 1], 0, 0, line)
                elseif divk and p == proto.rawncode - 11 then
                    ins(FOP.DIV_K, divk_idx, 0, 0, line)
                else
                    ins(op, 0, 0, 0, line)
                end
            end
            fc.inline_sites[#fc.inline_sites + 1] = {
                start = inline_start,
                finish = fc.ncode,
                name = proto.name,
                call_line = inline_call_line,
            }
            clear_multi()
            fc.has_inline = true
            return true
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
                local p = function_proto(kind, ref)
                local proto = p and p.simple and p or nil
                if backend ~= "closure" and tk == "(" and proto and try_inline_call(proto) then
                    compile_suffix()
                else
                    local save_no_tail = no_tail_call
                    if p and p.has_inline then no_tail_call = true end
                    emit_var_get(kind, ref)
                    compile_suffix()
                    no_tail_call = save_no_tail
                end
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
        -- Table constructors
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
        -- Functions
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
            local rawncode = child.ncode
            local rawcode = {}
            for i = 1, rawncode do
                rawcode[i] = child.code[i]
            end
            child.code.slotlen = child.slotlen
        optimize_code(child.code, child.ncode, backend == "closure")
            if child.ncode > limits.maxCodeSlots then
                error("code exceeds maxCodeSlots", 0)
            end

            -- A leaf that can be expanded at a caller's call site: no
            -- upvalues, no locals/cells, no branches or calls, and a single
            -- arithmetic `return expr`.
            local simple = false
            if not child.isvararg and #child.upvals == 0 and rawncode >= 12 then
                local lastret = rawncode - 3
                local prevret = rawncode - 7
                if rawcode[lastret] == RET and rawcode[lastret + 1] == 0 and
                   rawcode[prevret] == RET and rawcode[prevret + 1] == 1 then
                    simple = true
                    for p = 1, rawncode - 11, 4 do
                        local op = rawcode[p]
                        if op == NOP then
                        elseif op == GETLOCAL then
                            if rawcode[p + 1] < 1 or
                               rawcode[p + 1] > child.numparams then
                                simple = false
                                break
                            end
                        elseif op == LOADK or op == LOADBOOL or op == LOADNIL then
                            if op == LOADBOOL and rawcode[p + 3] ~= 0 then
                                simple = false
                                break
                            end
                        elseif (op >= ADD and op <= POW) or
                               op == UNM or op == NOT or op == LEN then
                        else
                            simple = false
                            break
                        end
                    end
                end
            end

            -- Leading NOPs are `emit_cell` placeholders for parameters and
            -- locals that were never captured. They are pure no-ops, so the
            -- frame can start at the first real instruction.
            local entry = 1
            while entry <= child.ncode and child.code[entry] == NOP do
                entry = entry + 4
            end

            local proto = {
                code = child.code,
                lines = child.lines,
                slotlen = child.code.slotlen or child.slotlen,
                consts = child.consts,
                updesc = child.upvals,
                numparams = child.numparams,
                isvararg = child.isvararg,
                maxreg = child.maxreg,
                entry = entry,
                rawcode = rawcode,
                rawncode = rawncode,
                simple = simple,
                backend = backend,
                has_inline = child.has_inline,
                inline_sites = child.inline_sites,
                env = env,
                sourceName = sourceName,
                name = nil,
                protos = all_protos,
                limits = limits,
            }
            all_protos[#all_protos + 1] = proto
            local idx = #all_protos

            fc = parent_fc
            return idx
        end

        -- ========================================================
        -- Expression lists
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
                local multi_pc = last_multi_pc
                patch_nres(multi_pc, -1)
                clear_multi()
                return -1, count, multi_pc
            end
            clear_multi()
            return count
        end

        -- ========================================================
        -- Statement-level expressions: assignment or call
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
                local u = fc.upvals[target.ref]
                if u and u.src then u.src.func_idx = nil end
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
        -- Blocks and statements
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
                local fname = tv
                local desc = new_local(tv)
                advance()
                emit(LOADNIL, 1, 0, 0)
                emit(SETLOCAL, desc.slot, 0, 0)
                emit_cell(desc)
                local idx = compile_funcbody(false)
                all_protos[idx].name = fname
                emit(CLOSURE, idx, 0, 0)
                emit_local_set(desc)
                desc.func_idx = idx
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
            local n, count, multi_pc = compile_exprlist_all()
            while accept(";") do end
            if not is_block_end() then
                fail("'end' expected after return")
            end
            if n == -1 and count == 1 and multi_pc and
               fc.code[multi_pc] == CALLD and fc.code[multi_pc + 3] ~= 2 then
                -- Mark this CALLD as a tail call. The VM reuses the current
                -- frame for interpreted targets; native targets are called
                -- normally and fall through to the RET below. C = 2 marks a
                -- call that must keep its frame because the target contains
                -- inlined code whose errors need a traceback frame.
                fc.code[multi_pc + 3] = 1
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
            local fname = name
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
                        fname = tv
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
                        fname = tv
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
            all_protos[idx].name = fname
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
        fc.code.slotlen = fc.slotlen
        optimize_code(fc.code, fc.ncode, backend == "closure")
        if fc.ncode > limits.maxCodeSlots then
            error("code exceeds maxCodeSlots", 0)
        end

        local proto = {
            code = fc.code,
            lines = fc.lines,
            slotlen = fc.code.slotlen or fc.slotlen,
            consts = fc.consts,
            updesc = fc.upvals,
            numparams = 0,
            isvararg = true,
            maxreg = fc.maxreg,
            env = env,
            sourceName = sourceName,
            backend = backend,
            protos = all_protos,
            limits = limits,
        }
        all_protos[#all_protos + 1] = proto
        return proto
    end

    local ok, proto = pcall(compile)
    if not ok then
        return nil, tostring(proto)
    end
    return make_closure(proto, {}, env, true)
end

return custom_loadstring
end

return build
