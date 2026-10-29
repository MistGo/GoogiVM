# In-game benchmark evidence (Scrap Mechanic)

These are **verbatim console transcripts** produced by
[`../benchmark11.lua`](../benchmark11.lua) inside Scrap Mechanic on a computer
block, in one session, back to back on the same machine.

They are user-reported in-game runs, not CI artifacts: Scrap Mechanic cannot be
scripted from this repository, so the numbers cannot be regenerated here.

Environment:

- Game: Scrap Mechanic
- Mods: ScrapComputers (`3269912087`) and SComputers
- Host Lua: the game's own Lua 5.1 (no JIT)
- Harness: `benchmark11.lua` pasted into `Main.lua`
- Date: 2026-10-29, 14:50-15:00

Reproduction: paste `benchmarks/benchmark11.lua` into a computer's `Main.lua`
and switch the active VM (`GOOGI_USE_CUSTOM_VM` in `Scripts/GoogiVMConfig.lua`
for ScrapComputers, or the equivalent switch for SComputers). Inside the sandbox
`loadstring` compiles with whichever VM is active, so the identical script
measures both engines.

---

## Run A - GoogiVM (14:50:20)

```text
== GoogiVM benchmark: 11 micro-cases ==
engine: sandbox-loadstring
samples: 3, min sample time: 0.01 s

 1 fib(30) recursive                 2.7190 s  (best 2.7190, worst 2.7190, reps 1)
 2 fib(32) recursive                 6.9260 s  (best 6.9260, worst 6.9260, reps 1)
 3 1M function calls                 0.9100 s  (best 0.9020, worst 0.9150, reps 1)
 4 1M closure calls                  0.7920 s  (best 0.7880, worst 0.7940, reps 1)
 5 100k upvalue increments           0.0690 s  (best 0.0690, worst 0.0770, reps 1)
 6 100k vararg calls                 0.2060 s  (best 0.2000, worst 0.2300, reps 1)
 7 100k metatable adds               0.1400 s  (best 0.1350, worst 0.1450, reps 1)
 8 200k table writes + reads         0.0390 s  (best 0.0380, worst 0.0420, reps 1)
 9 1M branch/mod iterations          0.2200 s  (best 0.2200, worst 0.2220, reps 1)
10 primes <= 50000                   0.2160 s  (best 0.2090, worst 0.2230, reps 1)
11 10k string concatenations         0.0180 s  (best 0.0170, worst 0.0190, reps 1)

---------------------------------------------------------------
cases: 11, failures: 0
sum of medians:        12.2550 s
geometric mean:        0.2821 s

(no io available: results are console-only)
```

## Run B - ScrapComputers VM (14:53:36)

```text
== ScrapComputersVM benchmark: 11 micro-cases ==
engine: sandbox-loadstring
samples: 3, min sample time: 0.01 s

 1 fib(30) recursive                 5.5340 s  (best 5.5340, worst 5.5340, reps 1)
 2 fib(32) recursive                14.0020 s  (best 14.0020, worst 14.0020, reps 1)
 3 1M function calls                 1.8670 s  (best 1.8660, worst 1.8690, reps 1)
 4 1M closure calls                  1.8060 s  (best 1.7980, worst 1.8640, reps 1)
 5 100k upvalue increments           0.1640 s  (best 0.1630, worst 0.1640, reps 1)
 6 100k vararg calls                 0.2420 s  (best 0.2400, worst 0.2440, reps 1)
 7 100k metatable adds               0.1770 s  (best 0.1730, worst 0.1790, reps 1)
 8 200k table writes + reads         0.0410 s  (best 0.0410, worst 0.0410, reps 1)
 9 1M branch/mod iterations          0.2330 s  (best 0.2330, worst 0.2350, reps 1)
10 primes <= 50000                   0.2420 s  (best 0.2400, worst 0.2420, reps 1)
11 10k string concatenations         0.0160 s  (best 0.0160, worst 0.0170, reps 1)

---------------------------------------------------------------
cases: 11, failures: 0
sum of medians:        24.3240 s
geometric mean:        0.4179 s

(no io available: results are console-only)
```

## Run C - SComputers VM (14:59:29)

```text
== SComputersVM benchmark: 11 micro-cases ==
engine: sandbox-loadstring
samples: 3, min sample time: 0.01 s

 1 fib(30) recursive                 4.1560 s  (best 4.1560, worst 4.1560, reps 1)
 2 fib(32) recursive                10.4010 s  (best 10.4010, worst 10.4010, reps 1)
 3 1M function calls                 1.5940 s  (best 1.3660, worst 1.5950, reps 1)
 4 1M closure calls                  1.4570 s  (best 1.4400, worst 1.5560, reps 1)
 5 100k upvalue increments           0.1350 s  (best 0.1270, worst 0.1490, reps 1)
 6 100k vararg calls                 0.2210 s  (best 0.1590, worst 0.2550, reps 1)
 7 100k metatable adds            RUNTIME ERROR  @code:5: attempt to perform arithmetic on local 'lhs' (a nil value)
 8 200k table writes + reads         0.0490 s  (best 0.0490, worst 0.0500, reps 1)
 9 1M branch/mod iterations          0.1970 s  (best 0.1930, worst 0.2190, reps 1)
10 primes <= 50000                   0.2130 s  (best 0.2110, worst 0.2200, reps 1)
11 10k string concatenations         0.0070 s  (best 0.0060, worst 0.0720, reps 1)

---------------------------------------------------------------
cases: 11, failures: 1
sum of medians:        18.4300 s
geometric mean:        0.3660 s

(no io available: results are console-only)
```

Run C reports **10 timed cases** and one runtime error: that VM does not
support the `__add` metamethod used by case 7, so it cannot complete the
metatable workload at all. Its `sum of medians` therefore covers 10 cases and is
not directly comparable with the 11-case totals.

---

## Cross-engine ratios (same session)

| Case | GoogiVM | ScrapComputers | SComputers | Googi / SC | Googi / SComp |
|---|---:|---:|---:|---:|---:|
| `fib(30)` | 2.7190 | 5.5340 | 4.1560 | **2.04x** | **1.53x** |
| `fib(32)` | 6.9260 | 14.0020 | 10.4010 | **2.02x** | **1.50x** |
| 1M function calls | 0.9100 | 1.8670 | 1.5940 | **2.05x** | **1.75x** |
| 1M closure calls | 0.7920 | 1.8060 | 1.4570 | **2.28x** | **1.84x** |
| 100k upvalue increments | 0.0690 | 0.1640 | 0.1350 | **2.38x** | **1.96x** |
| 100k vararg calls | 0.2060 | 0.2420 | 0.2210 | **1.17x** | **1.07x** |
| 100k metatable adds | 0.1400 | 0.1770 | *error* | **1.26x** | n/a |
| 200k table writes + reads | 0.0390 | 0.0410 | 0.0490 | **1.05x** | **1.26x** |
| 1M branch/mod iterations | 0.2200 | 0.2330 | 0.1970 | **1.06x** | 0.90x |
| primes <= 50000 | 0.2160 | 0.2420 | 0.2130 | **1.12x** | 0.99x |
| 10k string concatenations | 0.0180 | 0.0160 | 0.0070 | 0.89x | 0.39x |
| **Total** | **12.2550** | **24.3240** (11) | **18.4300** (10) | **1.99x** | **1.52x** (10 shared) |

Geometric mean of per-case speedups: **1.48x** vs ScrapComputers (11 cases),
**1.21x** vs SComputers (10 shared cases).

## Caveats

- Single machine, one world, one session. Wall-clock numbers come from a game
  tick loop and include engine overhead and jitter; treat differences below
  ~5% as noise. `10k string concatenations` is clearly slower for GoogiVM.
- `sum of medians` is dominated by the slowest case; the geometric mean weights
  all cases equally.
- SComputers has only 10 valid cases (no metamethod support), so its totals are
  compared on the 10 shared cases only.
- These transcripts prove what the harness printed; they are not a
  statistically controlled experiment.
