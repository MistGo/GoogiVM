# 50 head-to-head benchmarks: GoogiVM vs FiOne vs LuaJIT native

Date: 2026-10-30
Host: Lua 5.1 (LuaJIT 2.1.1720049189)
Owner: current `custom_loadstring_full.lua`
FiOne: `SovereignSatellite/FiOne` @ `18cf0113dcef568b6b679096e372c7bbf7ac6d27`
Bytecode compiler for FiOne: `luac5.1` (Lua 5.1.5)

## Methodology

- 50 distinct Lua 5.1 workloads; each was run on all three engines.
- All engines received the same source and the same standard-library environment.
- Timed region is execution only: FiOne bytecode loading and GoogiVM compilation are outside the timer.
- 3 warm-up iterations, 10 measured iterations; JIT traces are flushed before each engine/case measurement.
- The table shows the median; `bench50_actual.lua` also writes an untracked `BENCHMARK_50_raw.csv` with every individual sample.
- Native LuaJIT is a reference baseline, not a pure-Lua competitor.

## Results

| # | Case | GoogiVM (s) | FiOne (s) | LuaJIT native (s) | FiOne / GoogiVM | Native / GoogiVM | Reps O/F/N | Result |
|---:|---|---:|---:|---:|---:|---:|---:|---|
| 1 | `loop_sum_100k` | 0.000875 | 0.001938 | 0.000051 | 2.21x | 0.06x | 32/16/512 | `5000050000` |
| 2 | `loop_sum_1m` | 0.008750 | 0.019000 | 0.000500 | 2.17x | 0.06x | 4/2/64 | `500000500000` |
| 3 | `loop_add_const_1m` | 0.009125 | 0.018000 | 0.000500 | 1.97x | 0.05x | 4/1/64 | `2000000` |
| 4 | `loop_sub_1m` | 0.009250 | 0.018750 | 0.000500 | 2.03x | 0.05x | 2/2/64 | `-1000000` |
| 5 | `loop_mul_100k` | 0.000938 | 0.001875 | 0.000102 | 2.00x | 0.11x | 32/16/256 | `1.1051708628081` |
| 6 | `loop_mod_100k` | 0.001906 | 0.003250 | 0.000781 | 1.70x | 0.41x | 16/8/32 | `1` |
| 7 | `nested_loop_100x100` | 0.000098 | 0.000203 | 0.000005 | 2.08x | 0.05x | 256/128/4096 | `10000` |
| 8 | `while_sum_100k` | 0.002625 | 0.003625 | 0.000051 | 1.38x | 0.02x | 8/8/512 | `5000050000` |
| 9 | `repeat_sum_100k` | 0.002875 | 0.003125 | 0.000051 | 1.09x | 0.02x | 8/8/512 | `5000050000` |
| 10 | `loop_break_100k` | 0.001563 | 0.001844 | 0.000025 | 1.18x | 0.02x | 16/16/1024 | `1249975000` |
| 11 | `branch_if_1m` | 0.034000 | 0.045000 | 0.002375 | 1.32x | 0.07x | 1/1/16 | `250000000000` |
| 12 | `branch_and_or_100k` | 0.005000 | 0.004875 | 0.000453 | 0.97x | 0.09x | 4/8/64 | `99949` |
| 13 | `branch_mod3_100k` | 0.004250 | 0.006375 | 0.000359 | 1.50x | 0.08x | 8/4/64 | `1666716665` |
| 14 | `branch_nested_100k` | 0.004250 | 0.005750 | 0.000242 | 1.35x | 0.06x | 8/4/128 | `25000` |
| 15 | `calls_simple_1m` | 0.009750 | 0.795000 | 0.000508 | 81.54x | 0.05x | 4/1/64 | `1000000` |
| 16 | `calls_twoarg_1m` | 0.009000 | 0.859500 | 0.000500 | 95.50x | 0.06x | 4/1/64 | `1000000` |
| 17 | `calls_threearg_500k` | 0.018500 | 0.487000 | 0.000516 | 26.32x | 0.03x | 2/1/64 | `1500000` |
| 18 | `recursion_fib_20` | 0.002750 | 0.022000 | 0.000145 | 8.00x | 0.05x | 8/1/256 | `6765` |
| 19 | `recursion_fact_10` | 0.000012 | 0.000006 | 0.000000 | 0.51x | 0.02x | 4096/512/8192 | `3628800` |
| 20 | `mutual_recursion_1000` | 0.000084 | 0.000781 | 0.000006 | 9.30x | 0.07x | 256/16/4096 | `true` |
| 21 | `tail_recursion_1000` | 0.000092 | 0.001562 | 0.000008 | 17.02x | 0.09x | 256/32/4096 | `500500` |
| 22 | `closures_create_100k` | 0.073000 | 0.070500 | 0.003500 | 0.97x | 0.05x | 1/1/1 | `100000` |
| 23 | `closure_upvalue_1m` | 0.167500 | 1.373000 | 0.000508 | 8.20x | 0.00x | 1/1/64 | `1000000` |
| 24 | `closure_factory_100k` | 0.109500 | 0.388000 | 0.012125 | 3.54x | 0.11x | 1/1/4 | `5000150000` |
| 25 | `closure_loop_capture_100k` | 0.042500 | 0.063500 | 0.003000 | 1.49x | 0.07x | 1/1/1 | `100000` |
| 26 | `table_write_200k` | 0.002625 | 0.005750 | 0.000625 | 2.19x | 0.24x | 8/4/64 | `200000` |
| 27 | `table_read_200k` | 0.006500 | 0.012500 | 0.000750 | 1.92x | 0.12x | 4/2/32 | `20000100000` |
| 28 | `table_mixed_100k` | 0.003125 | 0.005375 | 0.000344 | 1.72x | 0.11x | 8/4/64 | `5000050000` |
| 29 | `table_string_keys_50k` | 0.001125 | 0.002000 | 0.000090 | 1.78x | 0.08x | 32/16/256 | `4945050` |
| 30 | `table_constructor_100k` | 0.017000 | 0.020000 | 0.000051 | 1.18x | 0.00x | 1/1/512 | `5000050000` |
| 31 | `table_nested_50k` | 0.009250 | 0.007875 | 0.003125 | 0.85x | 0.34x | 4/4/4 | `1250025000` |
| 32 | `ipairs_100k` | 0.004250 | 0.015750 | 0.000383 | 3.71x | 0.09x | 8/2/128 | `5000050000` |
| 33 | `pairs_20k` | 0.000875 | 0.003563 | 0.000117 | 4.07x | 0.13x | 32/8/256 | `200010000` |
| 34 | `generic_next_100k` | 0.017750 | 0.037500 | 0.000938 | 2.11x | 0.05x | 2/1/32 | `5000050000` |
| 35 | `generic_ipairs_50k` | 0.002125 | 0.008000 | 0.000199 | 3.76x | 0.09x | 16/4/256 | `1250025000` |
| 36 | `string_concat_10k` | 0.004125 | 0.004375 | 0.003563 | 1.06x | 0.86x | 8/8/8 | `10000` |
| 37 | `string_sub_50k` | 0.007125 | 0.010125 | 0.000025 | 1.42x | 0.00x | 4/4/1024 | `150000` |
| 38 | `string_byte_100k` | 0.009000 | 0.021500 | 0.000051 | 2.39x | 0.01x | 4/2/512 | `9700000` |
| 39 | `string_format_50k` | 0.007625 | 0.014250 | 0.003188 | 1.87x | 0.42x | 4/2/8 | `238894` |
| 40 | `string_gsub_10k` | 0.002125 | 0.003125 | 0.000781 | 1.47x | 0.37x | 16/8/32 | `30000` |
| 41 | `math_sqrt_100k` | 0.008625 | 0.024250 | 0.000453 | 2.81x | 0.05x | 4/2/64 | `21082008.973918` |
| 42 | `math_sin_100k` | 0.009250 | 0.027500 | 0.000516 | 2.97x | 0.06x | 4/2/64 | `1.8477771036304` |
| 43 | `math_floor_100k` | 0.009250 | 0.016000 | 0.000102 | 1.73x | 0.01x | 4/1/256 | `1666650000` |
| 44 | `varargs_count_100k` | 0.061000 | 0.169500 | 0.000051 | 2.78x | 0.00x | 1/1/512 | `200000` |
| 45 | `varargs_sum_100k` | 0.027000 | 0.166000 | 0.000063 | 6.15x | 0.00x | 1/1/512 | `10000200000` |
| 46 | `multiret_100k` | 0.023000 | 0.150000 | 0.000152 | 6.52x | 0.01x | 1/1/256 | `15000450000` |
| 47 | `multi_assign_100k` | 0.003375 | 0.004875 | 0.000051 | 1.44x | 0.02x | 8/8/512 | `300000` |
| 48 | `method_call_100k` | 0.019500 | 0.153000 | 0.000051 | 7.85x | 0.00x | 2/1/512 | `100000` |
| 49 | `metatable_add_100k` | 0.013500 | 0.130000 | 0.000051 | 9.63x | 0.00x | 2/1/512 | `300000` |
| 50 | `prime_count_10k` | 0.005375 | 0.008375 | 0.000312 | 1.56x | 0.06x | 4/4/128 | `1229` |

## Aggregate (median execution times)

- Cases: **50** (failures: 0).
- GoogiVM faster than FiOne (>5%): **46**; slower (<-5%): **2**; within 5%: **2**.
- Geometric mean FiOne/GoogiVM speed ratio: **2.78x**.
- Sum of medians: GoogiVM **0.7927 s**, FiOne **5.2156 s** (**6.58x**).

## Limitations

- These are 50 project-local microbenchmarks, not a standardized suite.
- Execution only: FiOne bytecode compilation and GoogiVM compilation are excluded.
- FiOne is a Lua 5.1 bytecode interpreter; it needs an external Lua 5.1 compiler.
- LuaJIT native uses `loadstring` and JIT; it is not a pure-Lua competitor.
- Single machine, one process, JIT traces flushed per engine/case; results are indicative, not statistically rigorous.
