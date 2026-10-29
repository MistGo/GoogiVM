# Benchmarks

Two reproducible harnesses live here.

## `benchmark11.lua` — 11 in-game micro-cases

An autonomous Lua 5.1 script that measures the 11 cases used for the in-game
Scrap Mechanic comparison.

It reports:

- per-case median / best / worst wall-clock time,
- **sum of medians** (dominated by the slowest case),
- **geometric mean** of medians (weights all cases equally),
- optional baseline ratios (geometric mean, arithmetic mean, total).

It writes two artifacts when `io` is available:

- `benchmark11_<label>.csv` — reproducible per-case results,
- `benchmark11_<label>_raw.txt` — the complete raw console log.

### Desktop usage

```bash
# Measure the local GoogiVM
luajit benchmarks/benchmark11.lua googi

# Compare against a previously exported run
luajit benchmarks/benchmark11.lua googi baseline.csv

# Reference: host LuaJIT loadstring (not a pure-Lua competitor)
luajit benchmarks/benchmark11.lua native
```

Modes:

| Mode | Loader |
|---|---|
| `auto` (default) | GoogiVM on desktop, sandbox `loadstring` in-game |
| `googi` | `dofile("custom_loadstring_full.lua")` |
| `vm` / `sandbox` | the sandbox-provided `loadstring` |
| `native` / `host` | the host `loadstring` with `setfenv` |

GoogiVM runs are given `maxInstructions/maxCallDepth/maxStack = math.huge` so a
quota never truncates a measurement.

### In-game usage (Scrap Mechanic / ScrapComputers)

Paste the whole file into a computer's `Main.lua` and run it. Inside the sandbox
`loadstring` compiles with whichever VM is active, so the **same** script
measures GoogiVM and the original FiOne when you flip `GOOGI_USE_CUSTOM_VM`.

Requirements inside the game sandbox:

| Global | Why | If missing |
|---|---|---|
| `loadstring` | compiles the cases with the active VM | hard error with a clear message |
| `os.clock` | timing | the script refuses to guess; install a clock |
| `print` | console output | nothing is displayed |
| `setmetatable`, `select`, `math`, `string`, `table` | used by the cases | the affected case reports a runtime error |

The script tolerates a stripped sandbox: it never touches `_G`, `io`, `arg`,
`dofile`, `setfenv`, `rawget`, or `getmetatable` unconditionally, and it skips
file output when `io` is absent.

In-game evidence from the reference sessions is transcribed in
[`in-game/README.md`](in-game/README.md).

## `bench50_actual.lua` — 50-case head-to-head

Generates [`../BENCHMARK_50.md`](../BENCHMARK_50.md),
[`../BENCHMARK_50.csv`](../BENCHMARK_50.csv) and
[`../BENCHMARK_50_raw.csv`](../BENCHMARK_50_raw.csv) (every sample).

Requirements (not shipped here):

- a FiOne checkout (`FIONE_PATH=/path/to/FiOne/source.lua`),
- a Lua 5.1 compiler (`LUAC_DIR=/path/to/dir/containing/luac5.1`).

```bash
FIONE_PATH=/path/to/FiOne/source.lua \
LUAC_DIR=/path/to/lua515 \
luajit benchmarks/bench50_actual.lua
```

On Windows the compiler directory is entered with `cd /d` before invoking
`luac5.1.exe`, which is required because that build ships a side-by-side CRT
manifest.

The harness times execution only: FiOne bytecode compilation and GoogiVM source
compilation are outside the timer. JIT traces are flushed before each
engine/case measurement.
