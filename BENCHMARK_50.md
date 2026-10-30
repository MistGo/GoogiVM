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
| 1 | `loop_sum_100k` | 0.000938 | 0.002063 | 0.000052 | 2.20x | 0.06x | 32/16/512 | `5000050000` |
| 2 | `loop_sum_1m` | 0.008750 | 0.019500 | 0.000508 | 2.23x | 0.06x | 4/2/64 | `500000500000` |
| 3 | `loop_add_const_1m` | 0.009250 | 0.018500 | 0.000516 | 2.00x | 0.06x | 4/2/64 | `2000000` |
| 4 | `loop_sub_1m` | 0.009500 | 0.019000 | 0.000508 | 2.00x | 0.05x | 4/2/64 | `-1000000` |
| 5 | `loop_mul_100k` | 0.000984 | 0.001875 | 0.000102 | 1.90x | 0.10x | 32/16/256 | `1.1051708628081` |
| 6 | `loop_mod_100k` | 0.001937 | 0.003250 | 0.000781 | 1.68x | 0.40x | 16/8/32 | `1` |
| 7 | `nested_loop_100x100` | 0.000098 | 0.000203 | 0.000005 | 2.08x | 0.05x | 256/128/4096 | `10000` |
| 8 | `while_sum_100k` | 0.002750 | 0.003875 | 0.000051 | 1.41x | 0.02x | 8/8/512 | `5000050000` |
| 9 | `repeat_sum_100k` | 0.003000 | 0.003313 | 0.000051 | 1.10x | 0.02x | 8/8/512 | `5000050000` |
| 10 | `loop_break_100k` | 0.001563 | 0.001875 | 0.000025 | 1.20x | 0.02x | 16/16/1024 | `1249975000` |
| 11 | `branch_if_1m` | 0.034000 | 0.045000 | 0.002437 | 1.32x | 0.07x | 1/1/8 | `250000000000` |
| 12 | `branch_and_or_100k` | 0.005250 | 0.004875 | 0.000461 | 0.93x | 0.09x | 4/8/64 | `99949` |
| 13 | `branch_mod3_100k` | 0.004500 | 0.006750 | 0.000359 | 1.50x | 0.08x | 8/4/64 | `1666716665` |
| 14 | `branch_nested_100k` | 0.004375 | 0.005625 | 0.000344 | 1.29x | 0.08x | 8/4/64 | `25000` |
| 15 | `calls_simple_1m` | 0.123500 | 0.746000 | 0.000516 | 6.04x | 0.00x | 1/1/64 | `1000000` |
| 16 | `calls_twoarg_1m` | 0.132000 | 0.849000 | 0.000508 | 6.43x | 0.00x | 1/1/64 | `1000000` |
| 17 | `calls_threearg_500k` | 0.075500 | 0.457500 | 0.000508 | 6.06x | 0.01x | 1/1/64 | `1500000` |
| 18 | `recursion_fib_20` | 0.002625 | 0.021000 | 0.000148 | 8.00x | 0.06x | 8/1/256 | `6765` |
| 19 | `recursion_fact_10` | 0.000011 | 0.000019 | 0.000000 | 1.70x | 0.01x | 2048/1024/8192 | `3628800` |
| 20 | `mutual_recursion_1000` | 0.000083 | 0.001031 | 0.000006 | 12.42x | 0.07x | 512/16/4096 | `true` |
| 21 | `tail_recursion_1000` | 0.000096 | 0.001250 | 0.000008 | 13.06x | 0.09x | 256/16/4096 | `500500` |
| 22 | `closures_create_100k` | 0.066500 | 0.061500 | 0.010000 | 0.92x | 0.15x | 1/1/2 | `100000` |
| 23 | `closure_upvalue_1m` | 0.138500 | 1.288500 | 0.000523 | 9.30x | 0.00x | 1/1/64 | `1000000` |
| 24 | `closure_factory_100k` | 0.078000 | 0.327500 | 0.010750 | 4.20x | 0.14x | 1/1/2 | `5000150000` |
| 25 | `closure_loop_capture_100k` | 0.065500 | 0.033500 | 0.011000 | 0.51x | 0.17x | 1/1/4 | `100000` |
| 26 | `table_write_200k` | 0.002500 | 0.005375 | 0.000609 | 2.15x | 0.24x | 8/4/32 | `200000` |
| 27 | `table_read_200k` | 0.006500 | 0.012500 | 0.000719 | 1.92x | 0.11x | 4/2/32 | `20000100000` |
| 28 | `table_mixed_100k` | 0.003125 | 0.005250 | 0.000344 | 1.68x | 0.11x | 8/4/64 | `5000050000` |
| 29 | `table_string_keys_50k` | 0.001172 | 0.002000 | 0.000086 | 1.71x | 0.07x | 32/16/256 | `4945050` |
| 30 | `table_constructor_100k` | 0.018000 | 0.021000 | 0.000051 | 1.17x | 0.00x | 2/2/512 | `5000050000` |
| 31 | `table_nested_50k` | 0.007125 | 0.006250 | 0.005562 | 0.88x | 0.78x | 4/4/8 | `1250025000` |
| 32 | `ipairs_100k` | 0.004125 | 0.014000 | 0.000375 | 3.39x | 0.09x | 8/2/128 | `5000050000` |
| 33 | `pairs_20k` | 0.000891 | 0.003063 | 0.000134 | 3.44x | 0.15x | 32/8/512 | `200010000` |
| 34 | `generic_next_100k` | 0.018250 | 0.030500 | 0.000938 | 1.67x | 0.05x | 2/1/32 | `5000050000` |
| 35 | `generic_ipairs_50k` | 0.002063 | 0.008375 | 0.000205 | 4.06x | 0.10x | 16/4/256 | `1250025000` |
| 36 | `string_concat_10k` | 0.004000 | 0.004313 | 0.003500 | 1.08x | 0.87x | 8/8/4 | `10000` |
| 37 | `string_sub_50k` | 0.007250 | 0.013250 | 0.000025 | 1.83x | 0.00x | 4/4/1024 | `150000` |
| 38 | `string_byte_100k` | 0.009000 | 0.022250 | 0.000051 | 2.47x | 0.01x | 4/2/512 | `9700000` |
| 39 | `string_format_50k` | 0.007250 | 0.017250 | 0.003000 | 2.38x | 0.41x | 4/2/8 | `238894` |
| 40 | `string_gsub_10k` | 0.002063 | 0.002875 | 0.000781 | 1.39x | 0.38x | 16/8/32 | `30000` |
| 41 | `math_sqrt_100k` | 0.008750 | 0.022500 | 0.000453 | 2.57x | 0.05x | 4/2/64 | `21082008.973918` |
| 42 | `math_sin_100k` | 0.009250 | 0.016500 | 0.000516 | 1.78x | 0.06x | 4/1/64 | `1.8477771036304` |
| 43 | `math_floor_100k` | 0.009375 | 0.024000 | 0.000105 | 2.56x | 0.01x | 4/2/256 | `1666650000` |
| 44 | `varargs_count_100k` | 0.055000 | 0.157500 | 0.000051 | 2.86x | 0.00x | 1/1/512 | `200000` |
| 45 | `varargs_sum_100k` | 0.026500 | 0.155000 | 0.000064 | 5.85x | 0.00x | 1/1/512 | `10000200000` |
| 46 | `multiret_100k` | 0.022000 | 0.135000 | 0.000152 | 6.14x | 0.01x | 1/1/256 | `15000450000` |
| 47 | `multi_assign_100k` | 0.003437 | 0.005000 | 0.000051 | 1.45x | 0.01x | 8/4/512 | `300000` |
| 48 | `method_call_100k` | 0.018000 | 0.135500 | 0.000051 | 7.53x | 0.00x | 2/1/512 | `100000` |
| 49 | `metatable_add_100k` | 0.012000 | 0.124500 | 0.000051 | 10.37x | 0.00x | 2/1/512 | `300000` |
| 50 | `prime_count_10k` | 0.005500 | 0.008375 | 0.000234 | 1.52x | 0.04x | 2/4/128 | `1229` |

## Aggregate (median execution times)

- Cases: **50** (failures: 0).
- GoogiVM faster than FiOne (>5%): **46**; slower (<-5%): **4**; within 5%: **0**.
- Geometric mean FiOne/GoogiVM speed ratio: **2.43x**.
- Sum of medians: GoogiVM **1.0323 s**, FiOne **4.8746 s** (**4.72x**).

## Limitations

- These are 50 project-local microbenchmarks, not a standardized suite.
- Execution only: FiOne bytecode compilation and GoogiVM compilation are excluded.
- FiOne is a Lua 5.1 bytecode interpreter; it needs an external Lua 5.1 compiler.
- LuaJIT native uses `loadstring` and JIT; it is not a pure-Lua competitor.
- Single machine, one process, JIT traces flushed per engine/case; results are indicative, not statistically rigorous.
