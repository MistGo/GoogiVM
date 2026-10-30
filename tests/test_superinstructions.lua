return function(t)
    local P = t.P

    -- Local arithmetic assignment fusion.
    t:expect("local s=0; for i=1,1000 do s=s+i end; return s", P(500500))
    t:expect("local s=10; for i=1,1000 do s=s-1 end; return s", P(-990))
    t:expect("local s=1; for i=1,10 do s=s*2 end; return s", P(1024))

    -- Table writes/reads with locals and constants.
    t:expect([[
local t = {}
for i = 1, 1000 do t[i] = i end
local s = 0
for i = 1, 1000 do s = s + t[i] end
return s
]], P(500500))

    t:expect([[
local t = {}
for i = 1, 100 do t[i] = 7 end
local s = 0
for i = 1, 100 do s = s + t[i] end
return s
]], P(700))

    t:expect([[
local t = {}
for i = 1, 100 do t.i = i end
local s = 0
for i = 1, 100 do s = s + t.i end
return s
]], P(10000))

    -- Local copy/constant assignment fusion.
    t:expect([[
local a = 1
local b = a
a = 5
local c = 9
return a, b, c
]], P(5, 1, 9))

    -- Conditions: local, constant comparison, and modulo comparison.
    t:expect([[
local x = 3
local s = 0
while x > 0 do
    s = s + x
    x = x - 1
end
return s
]], P(6))

    t:expect([[
local s = 0
local i = 0
while i < 10 do
    if i % 2 == 0 then s = s + i end
    i = i + 1
end
return s
]], P(20))

    t:expect([[
local s = 0
for i = 1, 20 do
    if i % 2 == 0 then
        s = s + i
    else
        s = s - 1
    end
end
return s
]], P(100))

    -- Captured loop variable: FORLOOP_CELL must make a fresh cell.
    t:expect([[
local fs = {}
for i = 1, 5 do fs[i] = function() return i end end
return fs[1](), fs[2](), fs[3](), fs[4](), fs[5]()
]], P(1, 2, 3, 4, 5))

    t:expect([[
local fs = {}
for i = 5, 1, -1 do fs[i] = function() return i end end
return fs[5](), fs[4](), fs[3](), fs[2](), fs[1]()
]], P(5, 4, 3, 2, 1))

    -- Captured loop variable + break.
    t:expect([[
local fs = {}
for i = 1, 10 do
    fs[#fs + 1] = function() return i end
    if i == 3 then break end
end
return #fs, fs[1](), fs[3]()
]], P(3, 1, 3))

    -- Assignment to the loop variable must not affect control.
    t:expect([[
local s = 0
for i = 1, 3 do
    s = s + i
    i = 100
end
return s
]], P(6))

    -- Empty body and zero iterations.
    t:expect("local n=0; for i=1,3 do end; return n", P(0))
    t:expect("local n=0; for i=1,0 do n=n+1 end; return n", P(0))

    -- Nested loops.
    t:expect([[
local s = 0
for i = 1, 10 do
    for j = 1, 10 do
        if j == 3 then break end
        s = s + i * j
    end
end
return s
]], P(165))

    -- Fused operations must still honor metamethods.
    t:expect([[
local function num(v)
    if type(v) == 'table' then return v.n end
    return v
end
local mt = {
    __add = function(a, b) return num(a) + num(b) end,
    __sub = function(a, b) return num(a) - num(b) end,
}
local s = setmetatable({n = 10}, mt)
local x = setmetatable({n = 2}, mt)
s = s + x
s = s - x
return s
]], P(10))

    t:expect([[
local log = ''
local t = setmetatable({}, {
    __index = function(_, k) log = log .. 'g' .. k; return 5 end,
    __newindex = function(t, k, v) log = log .. 's' .. k .. v; rawset(t, k, v) end,
})
local a = t.x
t.y = 7
return a, t.y, log
]], P(5, 7, "gxsy7"))

    -- Fused table operations with false/nil values.
    t:expect([[
local t = {}
t.a = false
t[1] = nil
return t.a, t[1]
]], P(false, nil))

    -- Jumps and short-circuit conditions.
    t:expect([[
local function f(x) return x end
local a = false and f(1)
local b = true or f(2)
local c = f(3) and f(4)
return a, b, c
]], P(false, true, 4))

    -- Comparison operators through fused paths.
    t:expect([[
local s = 0
for i = 1, 100 do
    if i < 50 and i >= 10 then s = s + 1 end
end
return s
]], P(40))

    -- Pairs/generic for still produce a fresh loop-local cell.
    t:expect([[
local fs = {}
for k, v in ipairs({10, 20, 30}) do
    fs[k] = function() return k, v end
end
local a, b = fs[1]()
local c, d = fs[3]()
return a, b, c, d
]], P(1, 10, 3, 30))

    -- Fused code must preserve evaluation order and side effects.
    t:expect([[
local log = {}
local t = {}
local function n(x) log[#log + 1] = x; return x end
local function base() log[#log + 1] = 'b'; return t end
base()[n(1)] = n(2)
return t[1], table.concat(log, ',')
]], P(2, "b,1,2"))

    -- Sieve-style numeric loop: `t[i] = true`.
    t:expect([[
local t = {}
for j = 2, 100, 3 do t[j] = true end
local n = 0
for j = 1, 100 do if t[j] then n = n + 1 end end
return n
]], P(33))

    -- Nbody-style indexed update with three multiplied operands.
    t:expect([[
local b = {1, 2, 3, 4, 5, 6, 7}
local dx, dy, m2, mag = 0.5, 0.25, 2, 3
b[4] = b[4] - dx * m2 * mag
b[5] = b[5] + dy * m2 * mag
return b[4], b[5]
]], P(1, 6.5))

    -- Mandelbrot-style `k * a * b + c` assignment.
    t:expect([[
local zr, zi, ci = 1.5, 2.5, 0.25
local zr2, zi2 = zr * zr, zi * zi
zi = 2.0 * zr * zi + ci
zr = zr2 - zi2 + 0.5
return zr, zi
]], P(-3.5, 7.75))

    -- `s = s + (a + b)` numeric fast path.
    t:expect([[
local a, b = 2, 3
local s = 0
for i = 1, 10 do s = s + (a + b) end
return s
]], P(50))

    -- `s = s + (a + b)` with `__add` on both operands.
    t:expect([[
local mt = {__add = function(a, b) return a.n + b.n end}
local a = setmetatable({n = 1}, mt)
local b = setmetatable({n = 2}, mt)
local s = 0
for i = 1, 10 do s = s + (a + b) end
return s
]], P(30))

    -- `t[i + k]` fused table read.
    t:expect([[
local log = {}
local t = setmetatable({}, {
    __index = function(_, k) log[#log + 1] = 'g' .. k; return k * 10 end,
})
local s = 0
for i = 1, 3 do s = s + t[i + 1] end
return s, table.concat(log, ',')
]], P(90, "g2,g3,g4"))

    -- `c + b * a` must keep `__mul` / `__add` operand order.
    t:expect([[
local log = {}
local mt = {
    __mul = function(a, b) log[#log + 1] = 'm' .. a.n .. b.n; return {n = a.n * b.n} end,
    __add = function(a, b) log[#log + 1] = 'a' .. a.n .. b.n; return {n = a.n + b.n} end,
}
local x = setmetatable({n = 2}, mt)
local y = setmetatable({n = 3}, mt)
local c = setmetatable({n = 4}, mt)
local function getx() return x end
local function gety() return y end
local r = c + getx() * gety()
return r.n, table.concat(log, ',')
]], P(10, "m23,a46"))

    -- Fused indexed update must keep `__index` / `__newindex` order.
    t:expect([[
local log = {}
local t = setmetatable({}, {
    __index = function(_, k) log[#log + 1] = 'g' .. k; return 10 end,
    __newindex = function(tt, k, v) log[#log + 1] = 's' .. k .. v; rawset(tt, k, v) end,
})
local dx, m2, mag = 2, 3, 4
local function update()
    t[1] = t[1] - dx * m2 * mag
    return t[1]
end
return update(), table.concat(log, ',')
]], P(-14, "g1,s1-14"))
end
