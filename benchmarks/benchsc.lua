--[[
ScrapComputers library benchmark.

Measures the heavy pure-Lua libraries that ship with ScrapComputers and that
user programs actually call: AES-256, SHA-256, MD5, Base64, Base91, LZ4, JSON,
QR-Code, the syntax highlighter, bit streams and vector maths.

Everything runs inside the computer's own Lua VM, so the numbers include the
interpreter overhead your programs pay.

Usage
-----
Paste this file into a computer's Main.lua and run it:

    run("Main.lua")

The libraries are provided by the ScrapComputers environment (`aes256`,
`sha256`, `md5`, `base64`, `base91`, `lz4`, `json`, `qrcode`, `syntax`,
`bitstream`, `vec2`). Any library that is missing is skipped, so the same file
still runs on a plain Lua host, where it only proves the harness works.

Lower `SCALE` if a run feels slow on a weak server; the printed work sizes
scale with it.
]]

local SCALE = 1

local print = debug
local clock = os.clock

-- The libraries can be reached three different ways depending on which
-- computer mod runs this file:
--
--   * plain globals          aes256, qrcode, ...          (ScrapComputers env)
--   * documented namespace   sc.aes256, sc.qrcode, ...    (newer docs)
--   * addon registry         sm.scrapcomputers.aes256, ... (other computer mods)
--
-- Every lookup falls back to the next form, and finally to the global itself,
-- so the same file works in ScrapComputers, SComputers and anywhere else that
-- exposes the ScrapComputers addon API.
local SC = (type(sc) == "table") and sc or {}
local ADDON = (type(sm) == "table" and type(sm.scrapcomputers) == "table")
              and sm.scrapcomputers or {}
local ADDSC = (type(ADDON.sc) == "table") and ADDON.sc or {}

local function pick(name, alt)
    local v = SC[name] or ADDSC[name] or ADDON[name]
    if v == nil and alt then
        v = SC[alt] or ADDSC[alt] or ADDON[alt]
    end
    return v
end

local aes256    = pick("aes256")             or aes256
local sha256    = pick("sha256")             or sha256
local md5       = pick("md5")                or md5
local base64    = pick("base64")             or base64
local base91    = pick("base91")             or base91
local lz4       = pick("lz4")                or lz4
local json      = pick("json")               or json
local qrcode    = pick("qrcode")             or qrcode
local syntax    = pick("syntax")             or syntax
local bitstream = pick("bitstream")          or bitstream
local vec2      = pick("vec2", "vector2")    or vec2

local function chars(n, seed)
    local t = {}
    local base = seed or 65
    for i = 1, n do
        t[i] = string.char(base + (i * 37) % 26)
    end
    return table.concat(t)
end

local function compressible(n)
    local t = {}
    for i = 1, n do
        t[i] = string.char(65 + math.floor(i / 8) % 4)
    end
    return table.concat(t)
end

local results = {}
local total = 0

local function bench(name, fn, expected)
    local ok, value = pcall(fn)
    if not ok then
        results[#results + 1] = { name = name, status = "ERROR: " .. tostring(value) }
        return
    end

    local start = clock()
    local got = fn()
    local elapsed = clock() - start

    local status
    if expected == nil then
        status = "OK"
    elseif got == expected then
        status = "OK"
    else
        status = string.format("MISMATCH got=%s want=%s", tostring(got), tostring(expected))
    end

    total = total + elapsed
    results[#results + 1] = { name = name, time = elapsed, status = status }
end

local function skip(name, why)
    results[#results + 1] = { name = name, status = "skipped (" .. why .. ")" }
end

------------------------------------------------------------------ core (synthetic)

-- The classic synthetic cases from the 50-case head-to-head suite: loops,
-- calls, closures, recursion, tables and branches. They measure the
-- interpreter itself; the library section below measures what programs
-- actually do with it.

-- Expected values only hold at SCALE = 1; otherwise the case still runs and is
-- reported as OK without checking the result.
local function exp(v)
    if SCALE == 1 then return v end
    return nil
end

local n24   = math.floor(24 * SCALE)
local n10k  = math.floor(10000 * SCALE)
local n20k  = math.floor(20000 * SCALE)
local n100k = math.floor(100000 * SCALE)
local n200k = math.floor(200000 * SCALE)
local n1m   = math.floor(1000000 * SCALE)

local function fib(n)
    if n < 2 then return n end
    return fib(n - 1) + fib(n - 2)
end

bench(string.format("fib(%d) recursion", n24), function()
    return fib(n24)
end, exp(46368))

bench(string.format("calls %d plain", n1m), function()
    local function id(x) return x end
    local s = 0
    for i = 1, n1m do s = s + id(1) end
    return s
end, n1m)

bench(string.format("closures %d create+call", n1m), function()
    local s = 0
    for i = 1, n1m do
        local f = function(x) return x + 1 end
        s = s + f(0)
    end
    return s
end, n1m)

bench(string.format("upvalue %d increments", n100k), function()
    local c = 0
    local function inc() c = c + 1 end
    for i = 1, n100k do inc() end
    return c
end, n100k)

bench(string.format("varargs %d calls", n100k), function()
    local function count(...) return select("#", ...) end
    local s = 0
    for i = 1, n100k do s = s + count(i, i, i) end
    return s
end, 3 * n100k)

bench(string.format("tail recursion %d", n100k), function()
    local function loop(n, acc)
        if n == 0 then return acc end
        return loop(n - 1, acc + 1)
    end
    return loop(n100k, 0)
end, n100k)

if setmetatable then
    local mt = { __add = function(a, b) return a.v + b.v end }
    bench(string.format("metatable %d adds", n100k), function()
        local a = setmetatable({ v = 1 }, mt)
        local b = setmetatable({ v = 2 }, mt)
        local s = 0
        for i = 1, n100k do s = s + (a + b) end
        return s
    end, 3 * n100k)
else
    skip("metatable adds", "no setmetatable in env")
end

bench(string.format("table write+read %d", n200k), function()
    local t = {}
    for i = 1, n200k do t[i] = i end
    local s = 0
    for i = 1, n200k do s = s + t[i] end
    return s
end, n200k * (n200k + 1) / 2)

bench(string.format("table ctor %d", n100k), function()
    local s = 0
    for i = 1, n100k do
        local t = { i, i + 1, i + 2 }
        s = s + t[1]
    end
    return s
end, n100k * (n100k + 1) / 2)

bench(string.format("while sum %d", n100k), function()
    local i, s = 0, 0
    while i < n100k do
        i = i + 1
        s = s + i
    end
    return s
end, n100k * (n100k + 1) / 2)

bench(string.format("repeat sum %d", n100k), function()
    local i, s = 0, 0
    repeat
        i = i + 1
        s = s + i
    until i >= n100k
    return s
end, n100k * (n100k + 1) / 2)

bench(string.format("branch+mod %d", n1m), function()
    local s = 0
    for i = 1, n1m do
        if i % 2 == 0 then
            s = s + i
        else
            s = s - 1
        end
    end
    return s
end, exp(250000000000))

bench(string.format("and/or chain %d", n100k), function()
    local s = 0
    for i = 1, n100k do
        if (i > 10 and i < 50) or i > 90 then s = s + 1 end
    end
    return s
end, exp(n100k - 51))

bench(string.format("loop break %d", n100k), function()
    local half = math.floor(n100k / 2)
    local s = 0
    for i = 1, n100k do
        if i == half then break end
        s = s + i
    end
    return s
end, n100k / 2 * (n100k / 2 - 1) / 2)

bench(string.format("multi-assign swap %d", n100k), function()
    local a, b = 0, 1
    for i = 1, n100k do
        a, b = b, a
        a = a + 1
        b = b + 2
    end
    return a + b
end, nil)

bench(string.format("concat %d", n10k), function()
    local s = ""
    for i = 1, n10k do s = s .. "x" end
    return #s
end, n10k)

bench(string.format("ipairs %d", n100k), function()
    local t = {}
    for i = 1, n100k do t[i] = i end
    local s = 0
    for _, v in ipairs(t) do s = s + v end
    return s
end, n100k * (n100k + 1) / 2)

bench(string.format("pairs %d", n20k), function()
    local t = {}
    for i = 1, n20k do t[i] = i end
    local s = 0
    for k in pairs(t) do s = s + k end
    return s
end, n20k * (n20k + 1) / 2)

bench("primes <= 50000", function()
    local limit = math.floor(50000 * SCALE)
    local count = 0
    for n = 2, limit do
        local prime = true
        local d = 2
        while d * d <= n do
            if n % d == 0 then
                prime = false
                break
            end
            d = d + 1
        end
        if prime then count = count + 1 end
    end
    return count
end, exp(5133))

-------------------------------------------------------------------- AES-256

local secret = chars(math.floor(512 * SCALE) + 16)

if aes256 then
    bench("aes256 encrypt 512 B", function()
        local out = aes256.encrypt("correct horse battery", secret)
        return #out > 0
    end, true)

    bench("aes256 encrypt+decrypt 512 B", function()
        local enc = aes256.encrypt("correct horse battery", secret)
        local dec = aes256.decrypt("correct horse battery", enc)
        return dec == secret
    end, true)

    bench("aes256 ECB 512 B", function()
        local out = aes256.encrypt("key", secret, aes256.AES256, aes256.ECBMODE)
        return #out > 0
    end, true)
else
    skip("aes256", "no aes256 in env")
end

--------------------------------------------------------------------- hashing

local payload = chars(math.floor(1024 * SCALE) + 7)

if sha256 then
    bench("sha256 1 KB x4", function()
        local h = ""
        for _ = 1, 4 do
            h = sha256.encode(payload)
        end
        return #h
    end, 64)
else
    skip("sha256", "no sha256 in env")
end

if md5 then
    local sumhexa = md5.sumhexa or md5.sum
    bench("md5 1 KB x4", function()
        local h = ""
        for _ = 1, 4 do
            h = sumhexa(payload)
        end
        return #h
    end, 32)
else
    skip("md5", "no md5 in env")
end

--------------------------------------------------------------------- codecs

local raw = chars(math.floor(4096 * SCALE))

if base64 then
    bench("base64 encode+decode 4 KB", function()
        local enc = base64.encode(raw)
        local dec = base64.decode(enc)
        return dec == raw
    end, true)
else
    skip("base64", "no base64 in env")
end

if base91 then
    bench("base91 encode+decode 2 KB", function()
        local enc = base91.encode(raw:sub(1, math.floor(2048 * SCALE)))
        local dec = base91.decode(enc)
        return #dec > 0
    end, true)
else
    skip("base91", "no base91 in env")
end

if lz4 then
    local compressible_data = compressible(math.floor(8192 * SCALE))
    bench("lz4 encode+decode 8 KB", function()
        local enc = lz4.encode(compressible_data)
        local dec = lz4.decode(enc)
        return dec == compressible_data
    end, true)
else
    skip("lz4", "no lz4 in env")
end

--------------------------------------------------------------------- JSON

if json and json.toString then
    local record = {
        name = "computer", id = 12345, online = true, tags = { "a", "b", "c" },
        position = { x = 1.5, y = -2.25, z = 0.125 },
        history = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 },
    }
    local records = {}
    for i = 1, math.floor(200 * SCALE) do
        records[i] = record
    end

    bench("json encode 200 records", function()
        local out = json.toString(records, false)
        return #out > 0
    end, true)
else
    skip("json", "no json in env")
end

--------------------------------------------------------------------- QR code

if qrcode and qrcode.generate then
    local text = string.rep("ScrapComputers ", math.floor(20 * SCALE))
    bench("qrcode generate 300 chars", function()
        -- errorCorrection is mandatory: 1..4 = L, M, Q, H
        local matrix = qrcode.generate(text, 2)
        return matrix ~= nil and #matrix > 0
    end, true)
else
    skip("qrcode", "no qrcode in env")
end

--------------------------------------------------------------------- syntax

if syntax and syntax.highlightCode then
    local lines = {}
    for i = 1, math.floor(100 * SCALE) do
        lines[i] = string.format("local value%d = %d * math.floor(%d / 2) -- comment", i, i, i)
    end
    local code = table.concat(lines, "\n")

    bench("syntax highlight 100 lines", function()
        -- exceptionLines is iterated with pairs() unguarded, so it must be a
        -- table, and theme must stay nil so the module falls back to its own
        -- defaultTheme (an empty table is not nil and misses every field).
        local out = syntax.highlightCode(code, {}, nil, true)
        return out ~= nil
    end, true)
else
    skip("syntax", "no syntax in env")
end

--------------------------------------------------------------------- bitstream

if bitstream and bitstream.new then
    bench("bitstream 10k values", function()
        local stream = bitstream.new()
        for i = 1, math.floor(10000 * SCALE) do
            stream:writeUIntBE(i % 256, 8)
        end
        return true
    end, true)
else
    skip("bitstream", "no bitstream in env")
end

--------------------------------------------------------------------- vectors

if vec2 and vec2.new then
    bench("vec2 normalise 50k", function()
        local acc = 0
        for i = 1, math.floor(50000 * SCALE) do
            local v = vec2.new(i % 7 + 1, i % 5 + 1)
            v:normalize()
            acc = acc + v:length()
        end
        return acc > 0
    end, true)
else
    skip("vec2", "no vec2 in env")
end

--------------------------------------------------------------------- stdlib

bench("table.sort 2000 comparator", function()
    local t = {}
    for i = 1, math.floor(2000 * SCALE) do
        t[i] = (i * 7919) % 10007
    end
    table.sort(t, function(a, b) return a < b end)
    return t[1] <= t[#t]
end, true)

bench("string.gsub 1 KB x20", function()
    local out = ""
    for _ = 1, math.floor(20 * SCALE) do
        out = string.gsub(payload, "%a+", "x")
    end
    return #out > 0
end, true)

--------------------------------------------------------------------- report

print("== ScrapComputers library benchmark ==")

for _, r in ipairs(results) do
    if r.time then
        print(string.format("%-32s %8.4f s   %s", r.name, r.time, r.status))
    else
        print(string.format("%-32s %8s     %s", r.name, "-", r.status))
    end
end

print("--------------------------------")
print(string.format("Total measured time: %.4f s", total))
