# 50 head-to-head benchmarks: GoogiVM vs FiOne vs LuaJIT native

Date: 2026-10-29
Host: Lua 5.1 (LuaJIT 2.1.1720049189)
Owner: current `custom_loadstring_full.lua`
FiOne: `SovereignSatellite/FiOne` @ `18cf0113dcef568b6b679096e372c7bbf7ac6d27`
Bytecode compiler for FiOne: `luac5.1` (Lua 5.1.5)

## Methodology

- 50 distinct Lua 5.1 workloads; each was run on all three engines.
- All engines received the same source and the same standard-library environment.
- Timed region is execution only: FiOne bytecode loading and GoogiVM compilation are outside the timer.
- Per run: 3 warm-up iterations, 7 measured iterations; JIT traces are flushed before each engine/case measurement.
- Every number in this report is the **mean of 3 consecutive full runs** of the suite on the same machine.
- `reps` and `result` are taken from the first run; they are identical across runs.
- `bench50_actual.lua` also writes an untracked `BENCHMARK_50_raw.csv` with every individual sample of a single run.
- Native LuaJIT is a reference baseline, not a pure-Lua competitor.

## Results

| # | Case | GoogiVM (s) | FiOne (s) | LuaJIT native (s) | FiOne / GoogiVM | Native / GoogiVM | Reps O/F/N | Result |
|---:|---|---:|---:|---:|---:|---:|---:|---|
| 1 | `loop_sum_100k` | 0.001563 | 0.003208 | 0.000082 | 2.05x | 0.05x | 16/8/256 | `5000050000` |
| 2 | `loop_sum_1m` | 0.014833 | 0.031333 | 0.000823 | 2.11x | 0.06x | 2/1/32 | `500000500000` |
| 3 | `loop_add_const_1m` | 0.014167 | 0.030333 | 0.000812 | 2.14x | 0.06x | 2/1/32 | `2000000` |
| 4 | `loop_sub_1m` | 0.014833 | 0.030667 | 0.000812 | 2.07x | 0.05x | 2/1/32 | `-1000000` |
| 5 | `loop_mul_100k` | 0.003292 | 0.003083 | 0.000164 | 0.94x | 0.05x | 8/8/128 | `1.1051708628081` |
| 6 | `loop_mod_100k` | 0.003333 | 0.005000 | 0.001250 | 1.50x | 0.38x | 8/4/16 | `1` |
| 7 | `nested_loop_100x100` | 0.000156 | 0.000352 | 0.000009 | 2.25x | 0.05x | 128/64/4096 | `10000` |
| 8 | `while_sum_100k` | 0.005833 | 0.006167 | 0.000082 | 1.06x | 0.01x | 4/4/256 | `5000050000` |
| 9 | `repeat_sum_100k` | 0.004958 | 0.005000 | 0.000082 | 1.01x | 0.02x | 8/4/256 | `5000050000` |
| 10 | `loop_break_100k` | 0.002708 | 0.002875 | 0.000041 | 1.06x | 0.02x | 8/8/512 | `1249975000` |
| 11 | `branch_if_1m` | 0.059333 | 0.075000 | 0.003875 | 1.26x | 0.07x | 1/1/8 | `250000000000` |
| 12 | `branch_and_or_100k` | 0.009083 | 0.007917 | 0.000750 | 0.87x | 0.08x | 4/4/32 | `99949` |
| 13 | `branch_mod3_100k` | 0.007333 | 0.010667 | 0.000589 | 1.45x | 0.08x | 4/2/64 | `1666716665` |
| 14 | `branch_nested_100k` | 0.007250 | 0.009250 | 0.000562 | 1.28x | 0.08x | 4/4/64 | `25000` |
| 15 | `calls_simple_1m` | 0.218667 | 1.322333 | 0.000812 | 6.05x | 0.00x | 1/1/32 | `1000000` |
| 16 | `calls_twoarg_1m` | 0.247333 | 1.420000 | 0.000812 | 5.74x | 0.00x | 1/1/32 | `1000000` |
| 17 | `calls_threearg_500k` | 0.152000 | 0.797667 | 0.000812 | 5.25x | 0.01x | 1/1/32 | `1500000` |
| 18 | `recursion_fib_20` | 0.004875 | 0.034333 | 0.000234 | 7.04x | 0.05x | 8/1/128 | `6765` |
| 19 | `recursion_fact_10` | 0.000017 | 0.000024 | 0.000000 | 1.40x | 0.02x | 2048/1024/8192 | `3628800` |
| 20 | `mutual_recursion_1000` | 0.000143 | 0.001458 | 0.000010 | 10.18x | 0.07x | 256/16/4096 | `true` |
| 21 | `tail_recursion_1000` | 0.000164 | 0.002021 | 0.000010 | 12.32x | 0.06x | 128/16/2048 | `500500` |
| 22 | `closures_create_100k` | 0.132000 | 0.096333 | 0.009750 | 0.73x | 0.07x | 1/1/4 | `100000` |
| 23 | `closure_upvalue_1m` | 0.249000 | 1.739000 | 0.000812 | 6.98x | 0.00x | 1/1/32 | `1000000` |
| 24 | `closure_factory_100k` | 0.134333 | 0.479333 | 0.008833 | 3.57x | 0.07x | 1/1/1 | `5000150000` |
| 25 | `closure_loop_capture_100k` | 0.130667 | 0.082333 | 0.020583 | 0.63x | 0.16x | 1/1/8 | `100000` |
| 26 | `table_write_200k` | 0.004333 | 0.009083 | 0.000937 | 2.10x | 0.22x | 8/4/64 | `200000` |
| 27 | `table_read_200k` | 0.010833 | 0.020667 | 0.001125 | 1.91x | 0.10x | 2/1/32 | `20000100000` |
| 28 | `table_mixed_100k` | 0.005167 | 0.008250 | 0.000552 | 1.60x | 0.11x | 4/4/64 | `5000050000` |
| 29 | `table_string_keys_50k` | 0.002000 | 0.003167 | 0.000150 | 1.58x | 0.07x | 16/8/256 | `4945050` |
| 30 | `table_constructor_100k` | 0.030000 | 0.036333 | 0.000082 | 1.21x | 0.00x | 1/1/256 | `5000050000` |
| 31 | `table_nested_50k` | 0.010833 | 0.011750 | 0.003417 | 1.08x | 0.32x | 1/4/2 | `1250025000` |
| 32 | `ipairs_100k` | 0.007083 | 0.028667 | 0.000396 | 4.05x | 0.06x | 4/1/64 | `5000050000` |
| 33 | `pairs_20k` | 0.001500 | 0.004958 | 0.000118 | 3.31x | 0.08x | 16/2/256 | `200010000` |
| 34 | `generic_next_100k` | 0.032333 | 0.048000 | 0.001500 | 1.48x | 0.05x | 1/1/16 | `5000050000` |
| 35 | `generic_ipairs_50k` | 0.003625 | 0.011000 | 0.000188 | 3.03x | 0.05x | 8/2/128 | `1250025000` |
| 36 | `string_concat_10k` | 0.027333 | 0.027833 | 0.025333 | 1.02x | 0.93x | 1/1/1 | `10000` |
| 37 | `string_sub_50k` | 0.012667 | 0.015833 | 0.000041 | 1.25x | 0.00x | 2/2/512 | `150000` |
| 38 | `string_byte_100k` | 0.015500 | 0.026667 | 0.000082 | 1.72x | 0.01x | 2/1/256 | `9700000` |
| 39 | `string_format_50k` | 0.013000 | 0.021500 | 0.004417 | 1.65x | 0.34x | 2/2/8 | `238894` |
| 40 | `string_gsub_10k` | 0.003583 | 0.004875 | 0.001281 | 1.36x | 0.36x | 8/2/32 | `30000` |
| 41 | `math_sqrt_100k` | 0.015167 | 0.028333 | 0.000719 | 1.87x | 0.05x | 2/1/32 | `21082008.973918` |
| 42 | `math_sin_100k` | 0.016333 | 0.029333 | 0.000833 | 1.80x | 0.05x | 2/1/32 | `1.8477771036304` |
| 43 | `math_floor_100k` | 0.015833 | 0.028333 | 0.000164 | 1.79x | 0.01x | 2/1/128 | `1666650000` |
| 44 | `varargs_count_100k` | 0.097667 | 0.208000 | 0.000082 | 2.13x | 0.00x | 1/1/256 | `200000` |
| 45 | `varargs_sum_100k` | 0.044667 | 0.207333 | 0.000105 | 4.64x | 0.00x | 1/1/256 | `10000200000` |
| 46 | `multiret_100k` | 0.039667 | 0.177333 | 0.000247 | 4.47x | 0.01x | 1/1/64 | `15000450000` |
| 47 | `multi_assign_100k` | 0.008667 | 0.007917 | 0.000082 | 0.91x | 0.01x | 4/4/256 | `300000` |
| 48 | `method_call_100k` | 0.033333 | 0.169000 | 0.000082 | 5.07x | 0.00x | 1/1/256 | `100000` |
| 49 | `metatable_add_100k` | 0.022667 | 0.168667 | 0.000085 | 7.44x | 0.00x | 1/1/256 | `300000` |
| 50 | `prime_count_10k` | 0.008583 | 0.013167 | 0.000411 | 1.53x | 0.05x | 4/2/64 | `1229` |

## Aggregate (mean execution times)

- Cases: **50** (failures: 0).
- GoogiVM faster than FiOne (>5%): **43**; slower (<-5%): **5**; within 5%: **2**.
- Geometric mean FiOne/GoogiVM speed ratio: **2.12x**.
- Sum of means: GoogiVM **1.9003 s**, FiOne **7.5117 s** (**3.95x**).

## Limitations

- These are 50 project-local microbenchmarks, not a standardized suite.
- Execution only: FiOne bytecode compilation and GoogiVM compilation are excluded.
- FiOne is a Lua 5.1 bytecode interpreter; it needs an external Lua 5.1 compiler.
- LuaJIT native uses `loadstring` and JIT; it is not a pure-Lua competitor.
- Single machine; absolute seconds drift with host load, so the ratios are the stable metric.
- Averaging 3 runs smooths per-run noise but is not a statistically rigorous treatment.
