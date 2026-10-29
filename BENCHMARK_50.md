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
- 3 warm-up iterations, 7 measured iterations; JIT traces are flushed before each engine/case measurement.
- The table shows the median; `BENCHMARK_50_raw.csv` contains every individual sample.
- Native LuaJIT is a reference baseline, not a pure-Lua competitor.

## Results

| # | Case | GoogiVM (s) | FiOne (s) | LuaJIT native (s) | FiOne / GoogiVM | Native / GoogiVM | Reps O/F/N | Result |
|---:|---|---:|---:|---:|---:|---:|---:|---|
| 1 | `loop_sum_100k` | 0.001188 | 0.002000 | 0.000051 | 1.68x | 0.04x | 32/16/512 | `5000050000` |
| 2 | `loop_sum_1m` | 0.011500 | 0.020000 | 0.000516 | 1.74x | 0.04x | 2/1/64 | `500000500000` |
| 3 | `loop_add_const_1m` | 0.012000 | 0.020000 | 0.000516 | 1.67x | 0.04x | 2/1/64 | `2000000` |
| 4 | `loop_sub_1m` | 0.013500 | 0.019500 | 0.000516 | 1.44x | 0.04x | 2/2/64 | `-1000000` |
| 5 | `loop_mul_100k` | 0.003625 | 0.001938 | 0.000102 | 0.53x | 0.03x | 8/16/256 | `1.1051708628081` |
| 6 | `loop_mod_100k` | 0.008250 | 0.003000 | 0.000781 | 0.36x | 0.09x | 4/8/32 | `1` |
| 7 | `nested_loop_100x100` | 0.000141 | 0.000211 | 0.000005 | 1.50x | 0.04x | 256/128/4096 | `10000` |
| 8 | `while_sum_100k` | 0.012500 | 0.003750 | 0.000051 | 0.30x | 0.00x | 2/8/512 | `5000050000` |
| 9 | `repeat_sum_100k` | 0.011500 | 0.002875 | 0.000051 | 0.25x | 0.00x | 2/8/512 | `5000050000` |
| 10 | `loop_break_100k` | 0.003000 | 0.001687 | 0.000025 | 0.56x | 0.01x | 8/16/1024 | `1249975000` |
| 11 | `branch_if_1m` | 0.057000 | 0.046000 | 0.002437 | 0.81x | 0.04x | 1/1/16 | `250000000000` |
| 12 | `branch_and_or_100k` | 0.028000 | 0.005000 | 0.000469 | 0.18x | 0.02x | 1/4/64 | `99949` |
| 13 | `branch_mod3_100k` | 0.007250 | 0.006750 | 0.000359 | 0.93x | 0.05x | 4/4/64 | `1666716665` |
| 14 | `branch_nested_100k` | 0.007000 | 0.006000 | 0.000359 | 0.86x | 0.05x | 4/4/64 | `25000` |
| 15 | `calls_simple_1m` | 0.249000 | 0.772000 | 0.000516 | 3.10x | 0.00x | 1/1/64 | `1000000` |
| 16 | `calls_twoarg_1m` | 0.294000 | 0.771000 | 0.000516 | 2.62x | 0.00x | 1/1/64 | `1000000` |
| 17 | `calls_threearg_500k` | 0.184000 | 0.440000 | 0.000516 | 2.39x | 0.00x | 1/1/64 | `1500000` |
| 18 | `recursion_fib_20` | 0.006500 | 0.021000 | 0.000148 | 3.23x | 0.02x | 4/1/256 | `6765` |
| 19 | `recursion_fact_10` | 0.000013 | 0.000014 | 0.000000 | 1.08x | 0.01x | 2048/1024/8192 | `3628800` |
| 20 | `mutual_recursion_1000` | 0.000211 | 0.001031 | 0.000006 | 4.89x | 0.03x | 128/32/4096 | `true` |
| 21 | `tail_recursion_1000` | 0.000273 | 0.001438 | 0.000009 | 5.26x | 0.03x | 128/16/4096 | `500500` |
| 22 | `closures_create_100k` | 0.103000 | 0.069000 | 0.008500 | 0.67x | 0.08x | 1/1/4 | `100000` |
| 23 | `closure_upvalue_1m` | 0.227000 | 1.187000 | 0.000516 | 5.23x | 0.00x | 1/1/64 | `1000000` |
| 24 | `closure_factory_100k` | 0.163000 | 0.334000 | 0.010000 | 2.05x | 0.06x | 1/1/2 | `5000150000` |
| 25 | `closure_loop_capture_100k` | 0.101000 | 0.032000 | 0.010125 | 0.32x | 0.10x | 1/1/8 | `100000` |
| 26 | `table_write_200k` | 0.003375 | 0.006250 | 0.000609 | 1.85x | 0.18x | 8/4/64 | `200000` |
| 27 | `table_read_200k` | 0.008500 | 0.013500 | 0.000750 | 1.59x | 0.09x | 4/2/32 | `20000100000` |
| 28 | `table_mixed_100k` | 0.004875 | 0.004750 | 0.000344 | 0.97x | 0.07x | 8/8/64 | `5000050000` |
| 29 | `table_string_keys_50k` | 0.004625 | 0.001750 | 0.000094 | 0.38x | 0.02x | 8/16/256 | `4945050` |
| 30 | `table_constructor_100k` | 0.029000 | 0.020000 | 0.000051 | 0.69x | 0.00x | 1/1/512 | `5000050000` |
| 31 | `table_nested_50k` | 0.009500 | 0.006250 | 0.002000 | 0.66x | 0.21x | 2/4/4 | `1250025000` |
| 32 | `ipairs_100k` | 0.008250 | 0.018000 | 0.000281 | 2.18x | 0.03x | 4/2/128 | `5000050000` |
| 33 | `pairs_20k` | 0.001688 | 0.003875 | 0.000084 | 2.30x | 0.05x | 16/8/512 | `200010000` |
| 34 | `generic_next_100k` | 0.031000 | 0.026000 | 0.000938 | 0.84x | 0.03x | 1/1/32 | `5000050000` |
| 35 | `generic_ipairs_50k` | 0.004125 | 0.007750 | 0.000145 | 1.88x | 0.04x | 8/4/256 | `1250025000` |
| 36 | `string_concat_10k` | 0.017000 | 0.018000 | 0.014500 | 1.06x | 0.85x | 1/1/2 | `10000` |
| 37 | `string_sub_50k` | 0.011500 | 0.009500 | 0.000025 | 0.83x | 0.00x | 2/2/1024 | `150000` |
| 38 | `string_byte_100k` | 0.016500 | 0.022500 | 0.000051 | 1.36x | 0.00x | 2/2/512 | `9700000` |
| 39 | `string_format_50k` | 0.012000 | 0.014500 | 0.003125 | 1.21x | 0.26x | 2/2/8 | `238894` |
| 40 | `string_gsub_10k` | 0.003000 | 0.003000 | 0.000812 | 1.00x | 0.27x | 8/8/32 | `30000` |
| 41 | `math_sqrt_100k` | 0.016000 | 0.022000 | 0.000453 | 1.38x | 0.03x | 2/2/64 | `21082008.973918` |
| 42 | `math_sin_100k` | 0.017000 | 0.017000 | 0.000516 | 1.00x | 0.03x | 2/1/64 | `1.8477771036304` |
| 43 | `math_floor_100k` | 0.020500 | 0.016000 | 0.000105 | 0.78x | 0.01x | 2/1/256 | `1666650000` |
| 44 | `varargs_count_100k` | 0.079000 | 0.134000 | 0.000051 | 1.70x | 0.00x | 1/1/512 | `200000` |
| 45 | `varargs_sum_100k` | 0.049000 | 0.139000 | 0.000064 | 2.84x | 0.00x | 1/1/512 | `10000200000` |
| 46 | `multiret_100k` | 0.053000 | 0.123000 | 0.000156 | 2.32x | 0.00x | 1/1/128 | `15000450000` |
| 47 | `multi_assign_100k` | 0.010250 | 0.005000 | 0.000051 | 0.49x | 0.00x | 4/4/512 | `300000` |
| 48 | `method_call_100k` | 0.045000 | 0.112000 | 0.000051 | 2.49x | 0.00x | 1/1/512 | `100000` |
| 49 | `metatable_add_100k` | 0.028000 | 0.113000 | 0.000051 | 4.04x | 0.00x | 1/1/512 | `300000` |
| 50 | `prime_count_10k` | 0.008500 | 0.008000 | 0.000297 | 0.94x | 0.03x | 4/2/64 | `1229` |

## Aggregate (median execution times)

- Cases: **50** (failures: 0).
- GoogiVM faster than FiOne (>5%): **28**; slower (<-5%): **19**; within 5%: **3**.
- Geometric mean FiOne/GoogiVM speed ratio: **1.21x**.
- Sum of medians: GoogiVM **1.9956 s**, FiOne **4.6318 s** (**2.32x**).

## Limitations

- These are 50 project-local microbenchmarks, not a standardized suite.
- Execution only: FiOne bytecode compilation and GoogiVM compilation are excluded.
- FiOne is a Lua 5.1 bytecode interpreter; it needs an external Lua 5.1 compiler.
- LuaJIT native uses `loadstring` and JIT; it is not a pure-Lua competitor.
- Single machine, one process, JIT traces flushed per engine/case; results are indicative, not statistically rigorous.
