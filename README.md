# GoogiVM

**A high-performance, pure-Lua Lua 5.1 source compiler and bytecode VM for sandboxed hosts where `loadstring` is unavailable.**

![Lua](https://img.shields.io/badge/Lua-5.1%20%7C%20LuaJIT-2C2D72)
![Tests](https://img.shields.io/badge/tests-18%2C681%20passed-brightgreen)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

`custom_loadstring_full.lua` is **GoogiVM**: a single-file Lua 5.1 compiler, peephole optimizer, and register/stack virtual machine written in 100% pure Lua. It requires zero external dependencies and never touches `load`, `loadstring`, FFI, `debug`, `io`, or `os`.

It is designed for game modding environments (such as **Scrap Mechanic / ScrapComputers**), embedded scripting engines, and restricted sandboxes that need to compile and run Lua 5.1 source strings safely and quickly.

> **Single-file deployment:** Only `custom_loadstring_full.lua` is required at runtime. The `tests/` directory and benchmark files are for development only.

---

## Why GoogiVM?

Most pure-Lua interpreters (such as **FiOne** / **LBI**) are *bytecode-only* interpreters: to run Lua source code, you must first run a separate pure-Lua lexer/parser/compiler (`LuaZ`/`LuaX`/`LuaY`/`LuaK`/`LuaU` from Yueliang) to serialize Lua 5.1 bytecode, and then deserialize and interpret it in FiOne.

**GoogiVM** replaces that entire multi-file chain with a single integrated pipeline:

```text
Lua 5.1 Source
  -> Streaming Lexer & Single-Pass Compiler (no AST allocation)
  -> Per-Function Prototype + Line Table
  -> Linear Peephole Superinstruction Optimizer (Opcodes 52–146)
  -> Explicit-Frame Stack/Register VM with Frame Pooling & Tail-Call Optimization
```

### Key Features

- **Complete Lua 5.1 Language Support:**
  - Control flow: `if`/`elseif`/`else`, `while`, `repeat`/`until`, numeric `for`, generic `for`, `break`, `do`/`end`, `return`.
  - Functions & closures: lexical scoping, mutable upvalues (heap-cell backpatching), varargs (`...`), method syntax (`obj:method()`), and **frame-reusing tail calls (`return f(...)`)**.
  - Tables & metamethods: array/hash/nested constructors, multi-return tail expansion (`{a, f()}`), and full host metamethod support (`__index`, `__newindex`, `__add`..`__pow`, `__eq`, `__lt`, `__le`, `__concat`, `__unm`, `__call`, `__len`).
  - Environments: isolated per-chunk `env`, plus sandboxed `getfenv`/`setfenv` support for interpreted closures.
- **Built-in Sandbox Quotas & Safety:**
  - Configurable compile-time limits (`maxSourceBytes`, `maxCodeSlots`) and runtime budgets (`maxInstructions`, `maxCallDepth`, `maxStack`, `maxArgs`, `maxReturns`).
  - Blocks `getfenv`/`setfenv` on native C/host functions and `setfenv(0, ...)` so untrusted code cannot escape into the host `_G`.
- **Source-Line Tracebacks:**
  - Syntax errors report exact line numbers and nearby tokens.
  - Runtime errors are rewritten to `sourceName:line: message` with a full call-stack traceback across interpreted frames.
  - Guest `pcall`/`xpcall` around interpreted closures keep the same sandbox format: host file paths and internal VM line numbers are never exposed.
- **Bounded Stack for Tail Calls:**
  - `return f(...)` reuses the current frame **and** its original stack region, so even millions of tail calls stay within a constant `maxStack` footprint.
- **Superinstruction Peephole Optimizer (95 Fused Opcodes):**
  - Fuses local moves, constant loads, binary arithmetic, compound assignments (`s = s + i`, `s = s + t[i]`), table reads/writes (`t[k] = v`, `t.field = v`), conditional branches (`if a < b`, `if x % d == 0`), numeric `for` bodies, table constructors, and zero-overhead `ipairs`/`pairs` generic `for` loops.

---

## Quick Start

Copy `custom_loadstring_full.lua` into your project and load it:

```lua
local custom_loadstring = dofile("custom_loadstring_full.lua")

local env = {
    ipairs = ipairs,
    pairs = pairs,
    next = next,
    select = select,
    tostring = tostring,
    tonumber = tonumber,
    type = type,
    pcall = pcall,
    xpcall = xpcall,
    assert = assert,
    error = error,
    math = math,
    string = string,
    table = table,
}

local chunk, err = custom_loadstring([[
    local out = {}
    for i = 1, 5 do
        out[i] = i * i
    end
    return table.concat(out, ", ")
]], env, {
    sourceName = "example.lua",
    maxInstructions = 1000000,
})

if not chunk then
    error("Compile error: " .. tostring(err))
end

print(chunk()) --> 1, 4, 9, 16, 25
```

If `env` is omitted (`nil`), GoogiVM creates a **fresh empty table `{}`** — it never exposes the host `_G` by default.

---

## Public API

```lua
local chunk, err = custom_loadstring(source, env, options)
```

| Parameter | Type | Description |
|---|---|---|
| `source` | `string` | Lua 5.1 source code to compile. Non-strings return `nil, "script must be a string"`. |
| `env` | `table \| nil` | Global environment table for the chunk (`nil` creates a new `{}`). |
| `options` | `table \| nil` | Optional configuration and resource budgets (see below). |

**Return values:**
- **Success:** returns a callable Lua function `chunk(...)`.
- **Failure:** returns `nil, err` where `err` is a human-readable syntax or option validation error.

### Options & Resource Limits

All limits are enabled by default and can be customized per chunk or disabled individually by passing `math.huge`:

| Option | Default | Description |
|---|---:|---|
| `sourceName` | `"<string>"` | Chunk name shown in runtime error messages and stack tracebacks. |
| `maxSourceBytes` | `4,194,304` (4 MiB) | Maximum allowed length of `source` in bytes. |
| `maxCodeSlots` | `8,388,608` | Maximum bytecode array numbers per compiled function prototype. |
| `maxInstructions` | `50,000,000` | Maximum VM instructions executed per top-level call to `chunk(...)`. |
| `maxCallDepth` | `10,000` | Maximum nested interpreted call frames (tail calls reuse frames and do not count). |
| `maxStack` | `1,000,000` | Maximum VM register/expression stack index. |
| `maxArgs` | `1,000` | Maximum arguments passed to a function call. |
| `maxReturns` | `1,000` | Maximum return values produced by a function return or vararg expansion. |

---

## Host-dependent semantics

GoogiVM implements the Lua 5.1 **language**, but a few behaviors are defined by
the host runtime and are inherited rather than re-implemented:

| Area | Behavior |
|---|---|
| `#` on tables with holes | Follows the host's length algorithm; it is not defined as "highest integer key". |
| `__len` | Honored only when the host honors `__len` for tables (LuaJIT and Lua 5.2+ do; plain Lua 5.1 does not). |
| `getfenv` / `setfenv` | Available only when the host provides them. Interpreted closures (including numeric levels) are fully supported; `setfenv(0, ...)` is rejected and native function environments are blocked. |
| Numeric formatting | `tostring(number)` uses the host formatter. |
| Libraries | Only what you place in `env`; GoogiVM never imports `math`, `string`, or `table` itself. |
| Metamethod dispatch | Performed by host operators, so host-specific `__eq`/`__lt`/`__le`/`__concat` quirks apply. |
| Operator error text | Produced by the host; GoogiVM only rewrites the location prefix to `sourceName:line`. |
| Restricted sandboxes | Scrap Mechanic may omit or proxy `setmetatable`/`getmetatable`/`rawget`/`rawset`; GoogiVM requires only the helpers it actually uses and degrades gracefully when one is absent. |

If you need bit-identical behavior, run the same host version everywhere;
GoogiVM does not ship a second standard library.

## Performance Benchmarks

### 1. In-Game Benchmark (Scrap Mechanic / Lua 5.1)

Measured directly inside **Scrap Mechanic** with [`benchmarks/benchmark11.lua`](benchmarks/benchmark11.lua) against both the standard **ScrapComputers VM (FiOne)** and **SComputers (FiOne fork)**:

| Workload | **GoogiVM** | ScrapComputers (FiOne, Run 1) | ScrapComputers (FiOne, Run 2) | SComputers (FiOne) | **GoogiVM vs FiOne** | **GoogiVM vs SComputers** |
|---|---:|---:|---:|---:|---:|---:|
| `fib(30)` recursive | **2.639 s** | 5.973 s | 5.308 s | 4.203 s | **2.01–2.26x** | **1.59x** |
| `fib(32)` recursive | **6.969 s** | 16.098 s | 14.762 s | 10.807 s | **2.12–2.31x** | **1.55x** |
| 1M function calls | **0.911 s** | 2.150 s | 1.944 s | 1.453 s | **2.13–2.36x** | **1.59x** |
| 1M closure calls | **0.789 s** | 2.172 s | 1.829 s | 1.522 s | **2.32–2.75x** | **1.93x** |
| 100k upvalue increments | **0.071 s** | 0.180 s | 0.170 s | 0.167 s | **2.39–2.54x** | **2.35x** |
| 100k vararg calls | **0.206 s** | 0.295 s | 0.257 s | 0.176 s | **1.25–1.43x** | 0.85x |
| 100k metatable `__add` | **0.135 s** | 0.205 s | 0.185 s | *unsupported* | **1.37–1.52x** | — |
| 200k table writes + reads | **0.041 s** | 0.043 s | 0.041 s | 0.047 s | **1.00–1.05x** | **1.15x** |
| 1M branch/mod iterations | **0.226 s** | 0.254 s | 0.233 s | 0.192 s | **1.03–1.12x** | 0.85x |
| Primes <= 50,000 | **0.205 s** | 0.258 s | 0.242 s | 0.290 s | **1.18–1.26x** | **1.41x** |
| 10k string concatenations | **0.025 s** | 0.025 s | 0.020 s | 0.006 s | 0.80–1.00x | 0.24x |
| **Total (All 11 cases)** | **12.217 s** | **27.653 s** | **24.991 s** | — | **2.05–2.26x faster** | — |
| **Total (10 shared cases)** | **12.082 s** | **27.448 s** | **24.806 s** | **18.863 s** | **2.05–2.27x faster** | **1.56x faster** |

### 2. 50-Case Head-to-Head Suite (`BENCHMARK_50.md`)

Across 50 diverse microbenchmarks comparing **GoogiVM** against upstream **FiOne** (`SovereignSatellite/FiOne` running precompiled `luac5.1` bytecode):

- **32 wins**, **14 losses**, **4 near-ties** (within 5%).
- **2.69x faster by total median execution time** (`1.9636 s` vs `5.2825 s`).
- **1.30x geometric mean speedup** across all 50 workloads.
- Massive gains on calls (`2.6–3.2x`), closures/upvalues (`2.7–6.2x`), tail/mutual recursion (`2.7–4.8x`), `ipairs`/`pairs` (`1.3–1.7x`), and metamethods (`3.8x`).

See [`BENCHMARK_50.md`](BENCHMARK_50.md) and [`BENCHMARK_50.csv`](BENCHMARK_50.csv) for the full 50-case breakdown.

---

## Architecture Overview

See [`TECHNICAL.md`](TECHNICAL.md) for a deep dive into the compiler, bytecode format, and VM internals.

1. **Lexer & Single-Pass Parser:**
   - Scans tokens on demand (`tk`, `tv`, `tp`, `pos`) without building a token list or AST.
   - Tracks newline offsets in `line_starts` and resolves source lines via binary search (`line_of`).
2. **hybrid Stack + Register Bytecode:**
   - Locals live in fixed frame-relative registers `S[base + slot - 1]`.
   - Temporary expression values use the top of `S` above `base + maxreg - 1`.
   - Captured locals are automatically promoted to heap cells (`{ v = val }`) by backpatching `NOP -> CELL` and `GETLOCAL/SETLOCAL -> GETCELL/SETCELL`.
3. **Peephole Superinstruction Optimizer (`optimize_code`):**
   - Scans jump targets first so it never fuses across a branch destination.
   - Replaces multi-instruction sequences in place (marking trailing slots dead and advancing `pc` by `4 * len`).
   - Fuses loop control (`FORLOOP_MOV`, `FORLOOP_CELL`) with hot loop bodies (`FORLOOP_ADD_RR`, `FORLOOP_ADD_INDEX`, `FORLOOP_SETINDEX_RR`, `FORLOOP_MOD_RR_EQ_K`, `FORLOOP_NEWTABLE_SETINDEX_R`).
   - Fuses generic `for` loops into `TFOR_1` and `TFOR_2` with direct in-VM `ipairs` and `next` iteration.
4. **Explicit Call Frames & Frame Pool:**
   - Custom-to-custom function calls (`CALLD`) push a lightweight frame onto `frames[]` (reusing pooled frame tables from `free_frames`) and jump to `pc = 1` inside the same `while true` loop — avoiding host Lua C-stack recursion.
   - Tail calls (`return f(...)`) overwrite the current frame in place.

---

## Running the Test Suite

Run from the repository root with LuaJIT (primary target) or standard Lua 5.1–5.4:

```bash
luajit run_all_tests.lua
lua run_all_tests.lua
```

Expected output:
- **LuaJIT 2.1:** `TOTAL: 18691 checks, 0 failed`
- **Lua 5.4:** `TOTAL: 18673 checks, 0 failed`

See [`tests/README.md`](tests/README.md) for a description of all 17 test modules.

## Reproducible benchmarks

The 11-case comparison is reproducible with the autonomous harness in
[`benchmarks/benchmark11.lua`](benchmarks/benchmark11.lua):

```bash
luajit benchmarks/benchmark11.lua googi                 # measure GoogiVM
luajit benchmarks/benchmark11.lua googi baseline.csv    # add ratio metrics
luajit benchmarks/benchmark11.lua native                # host LuaJIT reference
```

It prints per-case medians, the **sum of medians** and the **geometric mean**,
and (when `io` is available) writes `benchmark11_<label>.csv` plus a raw
console log. Inside Scrap Mechanic, paste the file into `Main.lua`: the sandbox
`loadstring` then measures whichever VM is active, so the identical script
yields a paired GoogiVM / FiOne comparison.

Details: [`benchmarks/README.md`](benchmarks/README.md).

---

## Repository Layout

```text
custom_loadstring_full.lua   # GoogiVM (compiler, optimizer, and VM in one file)
README.md                    # Project overview, API, and benchmark summary
TECHNICAL.md                 # Internal architecture and opcode reference
BENCHMARK_50.md              # 50-case benchmark report (GoogiVM vs FiOne)
BENCHMARK_50.csv             # Raw benchmark data
benchmarks/                  # Reproducible 11-case harness + raw artifacts
run_all_tests.lua            # Automated test runner
tests/                       # 17 test modules + test suite documentation
AGENTS.md                    # Guidelines and invariants for AI coding agents
LICENSE                      # MIT License
```

## License

MIT License. See [`LICENSE`](LICENSE).
