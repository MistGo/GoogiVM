# Benchmarks

This directory contains the reproducible benchmark harness for **GoogiVM**.

## `benchmark11.lua`

An autonomous Lua 5.1 script that measures the 11 standard micro-cases used for
the in-game Scrap Mechanic comparison.

It reports:

- per-case median / best / worst wall-clock time,
- **sum of medians** (dominated by the slowest case),
- **geometric mean** of medians (weights all cases equally),
- optional baseline ratios (geometric mean, arithmetic mean, and total).

It writes two artifacts when `io` is available:

- `benchmark11_<label>.csv` — reproducible per-case results,
- `benchmark11_<label>_raw.txt` — the complete raw console log.

### Desktop usage

Run from the repository root:

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

The harness raises `maxInstructions`, `maxCallDepth`, and `maxStack` to
`math.huge` for GoogiVM runs so a quota never truncates a measurement.

### In-game usage (Scrap Mechanic / ScrapComputers)

Paste the whole file into a computer's `Main.lua` and run it. Inside the
sandbox `loadstring` compiles with whichever VM is active, so the **same**
script measures GoogiVM and the original FiOne when you flip
`GOOGI_USE_CUSTOM_VM` in `Scripts/GoogiVMConfig.lua`.

The file is console-only there (no `io`), which is expected: copy the printed
table into a spreadsheet or into the report.

## `bench50_actual.lua` (workspace only)

The 50-case head-to-head suite that produced [`../BENCHMARK_50.md`](../BENCHMARK_50.md)
and [`../BENCHMARK_50.csv`](../BENCHMARK_50.csv). It requires an external Lua
5.1 compiler and a local FiOne checkout, so it is not shipped in this
repository.
