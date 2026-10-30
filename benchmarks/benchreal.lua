--[[
  benchreal.lua

  "Real-world" benchmark suite for Lua 5.1 VMs (GoogiVM, FiOne, the host VM).

  The programs are the classic algorithmic workloads used by The Computer
  Language Benchmarks Game (n-body, spectral-norm, mandelbrot, binary-trees,
  fannkuch-redux, pidigits, fasta, k-nucleotide) plus a few extra workloads
  that stress parts of a VM those programs miss: object-oriented dispatch,
  table-heavy word counting, JSON-style serialisation, and deep recursion.

  Everything is plain Lua 5.1: no `load`, no `io`, no `os` except `os.clock`
  for timing, so the same file runs on GoogiVM, on FiOne, and natively.

  Scaling: `SCALE` multiplies every workload size. The expected result is only
  checked at SCALE = 1.

  Running it directly (native Lua/LuaJIT): just execute the file.
  Running it under a VM: call `main()` from the guest chunk with `os.clock`,
  `string`, `table`, `math`, `print` available in the environment.
]]

local SCALE = 1
do
    local first = ...
    if type(first) == "number" then
        SCALE = first
    elseif type(first) == "string" then
        SCALE = tonumber(first) or 1
    end
end

local clock = os.clock
local floor = math.floor
local abs = math.abs
local sqrt = math.sqrt
local rep = string.rep
local sub = string.sub
local byte = string.byte
local format = string.format
local concat = table.concat
local sort = table.sort
local setmetatable = setmetatable

local function n(base)
    if SCALE == 1 then return base end
    local v = floor(base * SCALE)
    if v < 1 then v = 1 end
    return v
end

-- Only meaningful at SCALE = 1; the harness prints whatever comes back.
local function expected(v)
    if SCALE == 1 then return v end
    return nil
end

--------------------------------------------------------------------- n-body

local N_BODIES = n(25000)
local PI = 3.141592653589793
local SOLAR_MASS = 4 * PI * PI
local DAYS_PER_YEAR = 365.24

local function nbody()
    local bodies = {
        { 0, 0, 0, 0, 0, 0, SOLAR_MASS },
        { 4.84143144246472090e+00, -1.16032004402742839e+00, -1.03622044471123109e-01,
          1.66007664274403694e-03 * DAYS_PER_YEAR, 7.69901118419740425e-03 * DAYS_PER_YEAR,
          -6.90460016972063023e-05 * DAYS_PER_YEAR, 9.54791938424326609e-04 * SOLAR_MASS },
        { 8.34336671824457987e+00, 4.12479856412430479e+00, -4.03523417114321381e-01,
          -2.76742510726862411e-03 * DAYS_PER_YEAR, 4.99852801234917238e-03 * DAYS_PER_YEAR,
          2.30417297573763929e-05 * DAYS_PER_YEAR, 2.85885980666130812e-04 * SOLAR_MASS },
        { 1.28943695621391310e+01, -1.51111514016986312e+01, -2.23307578892655734e-01,
          2.96460137564761618e-03 * DAYS_PER_YEAR, 2.37847173959480950e-03 * DAYS_PER_YEAR,
          -2.96589568540237556e-05 * DAYS_PER_YEAR, 4.36624404335156298e-05 * SOLAR_MASS },
        { 1.53796971148509165e+01, -2.59193146099879641e+01, 1.79258772950371181e-01,
          2.68067772490389322e-03 * DAYS_PER_YEAR, 1.62824170038242295e-03 * DAYS_PER_YEAR,
          -9.51592254519715870e-05 * DAYS_PER_YEAR, 5.15138902046611451e-05 * SOLAR_MASS },
    }

    local nb = #bodies
    local b1, b2, dx, dy, dz, d2, mag, ds

    local function advance(dt)
        for i = 1, nb do
            b1 = bodies[i]
            local x1, y1, z1, m1 = b1[1], b1[2], b1[3], b1[7]
            for j = i + 1, nb do
                b2 = bodies[j]
                dx = x1 - b2[1]
                dy = y1 - b2[2]
                dz = z1 - b2[3]
                d2 = dx * dx + dy * dy + dz * dz
                mag = dt / (d2 * sqrt(d2))
                local m2 = b2[7]
                b1[4] = b1[4] - dx * m2 * mag
                b1[5] = b1[5] - dy * m2 * mag
                b1[6] = b1[6] - dz * m2 * mag
                b2[4] = b2[4] + dx * m1 * mag
                b2[5] = b2[5] + dy * m1 * mag
                b2[6] = b2[6] + dz * m1 * mag
            end
        end
        for i = 1, nb do
            b1 = bodies[i]
            b1[1] = b1[1] + dt * b1[4]
            b1[2] = b1[2] + dt * b1[5]
            b1[3] = b1[3] + dt * b1[6]
        end
    end

    -- offset the sun's momentum
    local px, py, pz = 0, 0, 0
    for i = 1, nb do
        local b = bodies[i]
        local m = b[7]
        px = px + b[4] * m
        py = py + b[5] * m
        pz = pz + b[6] * m
    end
    bodies[1][4] = -px / SOLAR_MASS
    bodies[1][5] = -py / SOLAR_MASS
    bodies[1][6] = -pz / SOLAR_MASS

    for _ = 1, N_BODIES do advance(0.01) end

    local energy = 0
    for i = 1, nb do
        local b = bodies[i]
        energy = energy + 0.5 * b[7] * (b[4] * b[4] + b[5] * b[5] + b[6] * b[6])
        for j = i + 1, nb do
            local c = bodies[j]
            dx = b[1] - c[1]
            dy = b[2] - c[2]
            dz = b[3] - c[3]
            energy = energy - (b[7] * c[7]) / sqrt(dx * dx + dy * dy + dz * dz)
        end
    end
    return floor(energy * 1e9 + 0.5)
end

------------------------------------------------------------ spectral-norm

local SPECTRAL_N = n(275)

local function spectralnorm()
    local function eval_a(i, j)
        return 1.0 / ((i + j) * (i + j + 1) / 2 + i + 1)
    end

    local function mul_av(v, out)
        for i = 0, SPECTRAL_N - 1 do
            local t = 0
            for j = 0, SPECTRAL_N - 1 do t = t + v[j + 1] * eval_a(i, j) end
            out[i + 1] = t
        end
    end

    local function mul_atv(v, out)
        for i = 0, SPECTRAL_N - 1 do
            local t = 0
            for j = 0, SPECTRAL_N - 1 do t = t + v[j + 1] * eval_a(j, i) end
            out[i + 1] = t
        end
    end

    local u, v, tmp = {}, {}, {}
    for i = 1, SPECTRAL_N do u[i] = 1 end
    for _ = 1, 10 do
        mul_av(u, tmp)
        mul_atv(tmp, v)
        mul_av(v, tmp)
        mul_atv(tmp, u)
    end

    local vbv, vv = 0, 0
    for i = 1, SPECTRAL_N do
        vbv = vbv + u[i] * v[i]
        vv = vv + v[i] * v[i]
    end
    return floor(sqrt(vbv / vv) * 1e9 + 0.5)
end

--------------------------------------------------------------- mandelbrot

local MB_N = n(200)

local function mandelbrot()
    local inv = 2.0 / MB_N
    local inside = 0
    for y = 0, MB_N - 1 do
        local ci = y * inv - 1.0
        for x = 0, MB_N - 1 do
            local cr = x * inv - 1.5
            local zr, zi = 0.0, 0.0
            local i = 0
            repeat
                local zr2 = zr * zr
                local zi2 = zi * zi
                if zr2 + zi2 > 4.0 then break end
                zi = 2.0 * zr * zi + ci
                zr = zr2 - zi2 + cr
                i = i + 1
            until i >= 50
            if i == 50 then inside = inside + 1 end
        end
    end
    return inside
end

-------------------------------------------------------------- binary trees

local BT_DEPTH = n(10)

local function binarytrees()
    local function bottom_up(depth)
        if depth == 0 then return { nil, nil } end
        return { bottom_up(depth - 1), bottom_up(depth - 1) }
    end
    local function check(node)
        local l = node[1]
        if l == nil then return 1 end
        return 1 + check(l) + check(node[2])
    end
    local total = 0
    for d = 4, BT_DEPTH, 2 do
        local iters = floor(2 ^ (BT_DEPTH - d + 4))
        for _ = 1, iters do total = total + check(bottom_up(d)) end
    end
    return total
end

------------------------------------------------------------- fannkuch-redux

local FAN_N = n(7)

local function fannkuch()
    local p, q = {}, {}
    for i = 1, FAN_N do p[i] = i; q[i] = i end
    local maxflips, checksum, sign = 0, 0, 1

    while true do
        -- count the flips needed for this permutation
        local flips = 0
        local k = q[1]
        while k ~= 1 do
            local i, j = 1, k
            while i < j do
                q[i], q[j] = q[j], q[i]
                i = i + 1
                j = j - 1
            end
            flips = flips + 1
            k = q[1]
        end
        if flips > maxflips then maxflips = flips end
        checksum = checksum + sign * flips
        sign = -sign

        -- restore q and advance to the next permutation of p
        for i = 1, FAN_N do q[i] = p[i] end
        local i = FAN_N - 1
        while i >= 1 and p[i] >= p[i + 1] do i = i - 1 end
        if i < 1 then break end
        local j = FAN_N
        while p[j] <= p[i] do j = j - 1 end
        p[i], p[j] = p[j], p[i]
        local a, b = i + 1, FAN_N
        while a < b do
            p[a], p[b] = p[b], p[a]
            a = a + 1
            b = b - 1
        end
    end

    return maxflips * 1000000 + (checksum % 1000000)
end

--------------------------------------------------------------- pidigits

local PIDIGITS = n(100)

local function pidigits()
    -- Wagon spigot: emits the digits of pi without big integers.
    local n = PIDIGITS
    if n < 1 then n = 1 end
    local len = floor(n * 10 / 3) + 1
    local a = {}
    for i = 1, len do a[i] = 2 end

    local digits = {}
    local count = 0
    local nines = 0
    local predigit = 0

    for _ = 1, n do
        local q = 0
        for i = len, 1, -1 do
            local x = 10 * a[i] + q * i
            local d = 2 * i - 1
            a[i] = x % d
            q = floor(x / d)
        end
        a[1] = q % 10
        q = floor(q / 10)
        if q == 9 then
            nines = nines + 1
        elseif q == 10 then
            count = count + 1
            digits[count] = predigit + 1
            for _ = 1, nines do
                count = count + 1
                digits[count] = 0
            end
            predigit, nines = 0, 0
        else
            count = count + 1
            digits[count] = predigit
            for _ = 1, nines do
                count = count + 1
                digits[count] = 9
            end
            predigit, nines = q, 0
        end
    end
    count = count + 1
    digits[count] = predigit

    -- The spigot emits a leading placeholder 0 before the "3" of pi.
    local sum = 0
    local emitted = 0
    for i = 2, count do
        emitted = emitted + 1
        sum = sum + digits[i] * emitted
    end
    return emitted * 1000000 + sum
end

-------------------------------------------------------------------- fasta

local FASTA_N = n(100000)

local function fasta()
    local IM, IA, IC = 139968, 3877, 29573
    local seed = 42
    local function rand()
        seed = (seed * IA + IC) % IM
        return seed / IM
    end

    local alphabet = "acgt"
    local out = {}
    local nout = 0
    local pick_from = { 0.27, 0.12, 0.12, 0.49 }
    for _ = 1, FASTA_N do
        local r = rand()
        local idx = 1
        while idx < 4 and r > pick_from[idx] do
            r = r - pick_from[idx]
            idx = idx + 1
        end
        nout = nout + 1
        out[nout] = sub(alphabet, idx, idx)
    end
    local s = concat(out)
    local chk = 0
    for i = 1, #s, 61 do chk = chk + byte(s, i) end
    return #s * 1000 + (chk % 1000)
end

-------------------------------------------------------------- k-nucleotide

local KN_N = n(20000)

local function knucleotide()
    local IM, IA, IC = 139968, 3877, 29573
    local seed = 7
    local base = { "A", "C", "G", "T" }
    local seq = {}
    for i = 1, KN_N do
        seed = (seed * IA + IC) % IM
        seq[i] = base[(seed % 4) + 1]
    end
    local s = concat(seq)

    local counts = {}
    for i = 1, #s - 3 do
        local k = sub(s, i, i + 3)
        counts[k] = (counts[k] or 0) + 1
    end
    local best, bestk = -1, nil
    for k, v in pairs(counts) do
        if v > best or (v == best and k < bestk) then
            best, bestk = v, k
        end
    end
    return best
end

-------------------------------------------------------------------- sieve

local SIEVE_N = n(300000)

local function sieve()
    local flags = {}
    local count = 0
    for i = 2, SIEVE_N do
        if not flags[i] then
            count = count + 1
            for j = i * 2, SIEVE_N, i do flags[j] = true end
        end
    end
    return count
end

-------------------------------------------------------------------- queens

local QUEENS_N = n(8)

local function queens()
    local count = 0
    local cols, d1, d2 = {}, {}, {}
    local function place(row)
        if row > QUEENS_N then
            count = count + 1
            return
        end
        for c = 1, QUEENS_N do
            if not cols[c] and not d1[row + c] and not d2[row - c + QUEENS_N] then
                cols[c], d1[row + c], d2[row - c + QUEENS_N] = true, true, true
                place(row + 1)
                cols[c], d1[row + c], d2[row - c + QUEENS_N] = nil, nil, nil
            end
        end
    end
    place(1)
    return count
end

------------------------------------------------------------------ matmul

local MM_N = n(80)

local function matmul()
    local a, b, c = {}, {}, {}
    local IM, IA, IC = 139968, 3877, 29573
    local seed = 1
    local function rand()
        seed = (seed * IA + IC) % IM
        return seed / IM
    end
    for i = 1, MM_N do
        a[i], b[i], c[i] = {}, {}, {}
        for j = 1, MM_N do
            a[i][j] = rand()
            b[i][j] = rand()
        end
    end
    for i = 1, MM_N do
        local ai, ci = a[i], c[i]
        for j = 1, MM_N do
            local s = 0
            for k = 1, MM_N do s = s + ai[k] * b[k][j] end
            ci[j] = s
        end
    end
    local sum = 0
    for i = 1, MM_N do sum = sum + c[i][i] end
    return floor(sum * 1e6 + 0.5)
end

---------------------------------------------------------------- quicksort

local QS_N = n(40000)

local function quicksort()
    local IM, IA, IC = 139968, 3877, 29573
    local seed = 3
    local t = {}
    for i = 1, QS_N do
        seed = (seed * IA + IC) % IM
        t[i] = seed
    end

    local function qsort(lo, hi)
        while lo < hi do
            if hi - lo < 12 then
                for i = lo + 1, hi do
                    local v = t[i]
                    local j = i - 1
                    while j >= lo and t[j] > v do
                        t[j + 1] = t[j]
                        j = j - 1
                    end
                    t[j + 1] = v
                end
                return
            end
            local mid = floor((lo + hi) / 2)
            local pivot = t[mid]
            local i, j = lo, hi
            while i <= j do
                while t[i] < pivot do i = i + 1 end
                while t[j] > pivot do j = j - 1 end
                if i <= j then
                    t[i], t[j] = t[j], t[i]
                    i = i + 1
                    j = j - 1
                end
            end
            if j - lo < hi - i then
                qsort(lo, j)
                lo = i
            else
                qsort(i, hi)
                hi = j
            end
        end
    end

    qsort(1, QS_N)
    return t[1] * 1000 + t[QS_N]
end

------------------------------------------------------------------- wordfreq

local WF_N = n(50000)

local function wordfreq()
    local words = {
        "lua", "vm", "bytecode", "interpreter", "table", "closure", "value",
        "chunk", "prototype", "upvalue", "metatable", "coroutine", "string",
        "number", "boolean", "function", "thread", "userdata", "debug",
    }
    local nw = #words
    local IM, IA, IC = 139968, 3877, 29573
    local seed = 11
    local counts = {}
    local total = 0
    for _ = 1, WF_N do
        seed = (seed * IA + IC) % IM
        local w = words[(seed % nw) + 1]
        counts[w] = (counts[w] or 0) + 1
        total = total + 1
    end
    local distinct = 0
    for _ in pairs(counts) do distinct = distinct + 1 end
    return total + distinct * 1000000
end

------------------------------------------------------------------------ oop

local OOP_N = n(50000)

local function oop()
    local Vec = {}
    Vec.__index = Vec

    function Vec.new(x, y)
        return setmetatable({ x = x, y = y }, Vec)
    end
    function Vec:add(o)
        return Vec.new(self.x + o.x, self.y + o.y)
    end
    function Vec:scale(k)
        return Vec.new(self.x * k, self.y * k)
    end
    function Vec:len2()
        return self.x * self.x + self.y * self.y
    end

    local v = Vec.new(1.0, 2.0)
    local step = Vec.new(0.5, 0.25)
    for i = 1, OOP_N do
        v = v:add(step):scale(0.999)
        if i % 1000 == 0 then v = Vec.new(v.x * 0.5, v.y * 0.5) end
    end
    return floor(v:len2() * 1e6 + 0.5)
end

----------------------------------------------------------------- jsonencode

local JSON_N = n(5000)

local function jsonencode()
    local function esc(s)
        return '"' .. s .. '"'
    end

    local function enc(v)
        local t = type(v)
        if t == "table" then
            local parts = {}
            local i = 1
            for k, val in pairs(v) do
                parts[i] = esc(tostring(k)) .. ":" .. enc(val)
                i = i + 1
            end
            return "{" .. concat(parts, ",") .. "}"
        elseif t == "string" then
            return esc(v)
        else
            return tostring(v)
        end
    end

    local doc = {
        name = "googivm",
        version = 1,
        tags = { "lua", "vm", "sandbox" },
        nested = { a = 1, b = 2, c = { d = 3, e = { f = 4 } } },
    }
    local out
    for _ = 1, JSON_N do out = enc(doc) end
    return #out
end

-------------------------------------------------------------------- hanoi

local HANOI_N = n(16)

local function hanoi()
    local moves = 0
    local function move(n, from, to, via)
        if n == 0 then return end
        move(n - 1, from, via, to)
        moves = moves + 1
        move(n - 1, via, to, from)
    end
    move(HANOI_N, 1, 3, 2)
    return moves
end

--------------------------------------------------------------------- suite

local CASES = {
    { "nbody",          nbody,        expected(-169071265) },
    { "spectral-norm",  spectralnorm, expected(1274223937) },
    { "mandelbrot",     mandelbrot,   expected(15909) },
    { "binary-trees",   binarytrees,  expected(129712) },
    { "fannkuch-redux", fannkuch,     expected(16000501) },
    { "pidigits",       pidigits,     expected(100023293) },
    { "fasta",          fasta,        expected(100000536) },
    { "k-nucleotide",   knucleotide,  expected(5000) },
    { "sieve",          sieve,        expected(25997) },
    { "queens",         queens,       expected(92) },
    { "matmul",         matmul,       expected(1615555365) },
    { "quicksort",      quicksort,    expected(139966) },
    { "wordfreq",       wordfreq,     expected(19050000) },
    { "oop",            oop,          expected(46798426479) },
    { "jsonencode",     jsonencode,   expected(119) },
    { "hanoi",          hanoi,        expected(65535) },
}

local function main()
    local total = 0
    local fails = 0
    print("== real-world suite (SCALE=" .. SCALE .. ") ==")
    for i = 1, #CASES do
        local c = CASES[i]
        local t0 = clock()
        local got = c[2]()
        local dt = clock() - t0
        total = total + dt
        local status = "OK"
        if c[3] ~= nil and got ~= c[3] then
            status = "MISMATCH got " .. tostring(got) .. " want " .. tostring(c[3])
            fails = fails + 1
        end
        print(format("%-16s %8.4f s  %-14s %s", c[1], dt, tostring(got), status))
    end
    print("--------------------------------")
    print(format("Total measured time: %.4f s, mismatches: %d", total, fails))
    return fails
end

if type(print) == "function" and os and os.clock then
    return main()
end
return main
