# 50 head-to-head benchmarks: LuaSandbox VM vs FiOne vs LuaJIT native

Date: 2026-10-28  
Host: LuaJIT 2.1 (64-bit), Windows  
Owner: current `lua-sandbox-vm-clean/custom_loadstring_full.lua`  
FiOne: `SovereignSatellite/FiOne` commit `18cf0113dcef568b6b679096e372c7bbf7ac6d27`  
Bytecode compiler for FiOne: Lua 5.1.5 `luac5.1`

## Methodology

- 50 distinct Lua 5.1 workloads; each was run on all three engines.
- All engines received the same source and the same standard-library environment.
- Timed region is execution only: FiOne bytecode loading and our compilation are outside the timer.
- 3 warm-up iterations, 7 measured iterations; JIT traces are flushed before each engine/case measurement; table shows the median, best is in the CSV.
- Native LuaJIT is a reference baseline, not a pure-Lua competitor.
- FiOne is a bytecode interpreter; its source-to-bytecode compilation is not included.

## Results

| # | Case | Ours (s) | FiOne (s) | LuaJIT native (s) | Ours / FiOne | Ours / native | Reps O/F/N | Result |
|---:|---|---:|---:|---:|---:|---:|---:|---|
| 1 | `loop_sum_100k` | 0.000969 | 0.002063 | 0.000051 | 2.13x | 0.05x | 32/16/512 | `5000050000` |
| 2 | `loop_sum_1m` | 0.009500 | 0.020000 | 0.000516 | 2.11x | 0.05x | 4/1/64 | `500000500000` |
| 3 | `loop_add_const_1m` | 0.010000 | 0.018500 | 0.000516 | 1.85x | 0.05x | 2/2/64 | `2000000` |
| 4 | `loop_sub_1m` | 0.012000 | 0.019000 | 0.000516 | 1.58x | 0.04x | 2/2/64 | `-1000000` |
| 5 | `loop_mul_100k` | 0.002625 | 0.001875 | 0.000102 | 0.71x | 0.04x | 8/16/256 | `1.1051708628081` |
| 6 | `loop_mod_100k` | 0.006750 | 0.003250 | 0.000781 | 0.48x | 0.12x | 4/8/32 | `1` |
| 7 | `nested_loop_100x100` | 0.000117 | 0.000227 | 0.000005 | 1.93x | 0.05x | 256/128/4096 | `10000` |
| 8 | `while_sum_100k` | 0.013000 | 0.003875 | 0.000051 | 0.30x | 0.00x | 2/8/512 | `5000050000` |
| 9 | `repeat_sum_100k` | 0.014500 | 0.003500 | 0.000053 | 0.24x | 0.00x | 2/8/512 | `5000050000` |
| 10 | `loop_break_100k` | 0.004125 | 0.001938 | 0.000025 | 0.47x | 0.01x | 8/16/1024 | `1249975000` |
| 11 | `branch_if_1m` | 0.049000 | 0.046000 | 0.002438 | 0.94x | 0.05x | 1/1/16 | `250000000000` |
| 12 | `branch_and_or_100k` | 0.028000 | 0.005125 | 0.000469 | 0.18x | 0.02x | 1/8/64 | `99949` |
| 13 | `branch_mod3_100k` | 0.006000 | 0.006750 | 0.000375 | 1.13x | 0.06x | 4/4/64 | `1666716665` |
| 14 | `branch_nested_100k` | 0.005750 | 0.005500 | 0.000344 | 0.96x | 0.06x | 4/4/64 | `25000` |
| 15 | `calls_simple_1m` | 0.230000 | 0.759000 | 0.000516 | 3.30x | 0.00x | 1/1/64 | `1000000` |
| 16 | `calls_twoarg_1m` | 0.271000 | 0.767000 | 0.000516 | 2.83x | 0.00x | 1/1/64 | `1000000` |
| 17 | `calls_threearg_500k` | 0.168000 | 0.438000 | 0.000516 | 2.61x | 0.00x | 1/1/64 | `1500000` |
| 18 | `recursion_fib_20` | 0.007500 | 0.021000 | 0.000145 | 2.80x | 0.02x | 4/1/256 | `6765` |
| 19 | `recursion_fact_10` | 0.000011 | 0.000016 | 0.000000 | 1.39x | 0.01x | 2048/1024/8192 | `3628800` |
| 20 | `mutual_recursion_1000` | 0.000250 | 0.001187 | 0.000006 | 4.75x | 0.02x | 128/16/4096 | `true` |
| 21 | `tail_recursion_1000` | 0.000297 | 0.001281 | 0.000002 | 4.32x | 0.01x | 64/32/8192 | `500500` |
| 22 | `closures_create_100k` | 0.114000 | 0.070000 | 0.009500 | 0.61x | 0.08x | 1/1/2 | `100000` |
| 23 | `closure_upvalue_1m` | 0.218000 | 1.158000 | 0.000516 | 5.31x | 0.00x | 1/1/64 | `1000000` |
| 24 | `closure_factory_100k` | 0.138000 | 0.337000 | 0.010000 | 2.44x | 0.07x | 1/1/2 | `5000150000` |
| 25 | `closure_loop_capture_100k` | 0.055000 | 0.038000 | 0.007000 | 0.69x | 0.13x | 1/1/2 | `100000` |
| 26 | `table_write_200k` | 0.002875 | 0.005375 | 0.000734 | 1.87x | 0.26x | 8/8/64 | `200000` |
| 27 | `table_read_200k` | 0.007750 | 0.013000 | 0.000875 | 1.68x | 0.11x | 4/2/32 | `20000100000` |
| 28 | `table_mixed_100k` | 0.003750 | 0.005500 | 0.000219 | 1.47x | 0.06x | 8/4/64 | `5000050000` |
| 29 | `table_string_keys_50k` | 0.004625 | 0.002125 | 0.000102 | 0.46x | 0.02x | 8/16/256 | `4945050` |
| 30 | `table_constructor_100k` | 0.049000 | 0.025000 | 0.000051 | 0.51x | 0.00x | 1/1/512 | `5000050000` |
| 31 | `table_nested_50k` | 0.016000 | 0.006000 | 0.001500 | 0.38x | 0.09x | 2/2/2 | `1250025000` |
| 32 | `ipairs_100k` | 0.037000 | 0.016500 | 0.000266 | 0.45x | 0.01x | 1/2/128 | `5000050000` |
| 33 | `pairs_20k` | 0.009000 | 0.003000 | 0.000125 | 0.33x | 0.01x | 4/4/512 | `200010000` |
| 34 | `generic_next_100k` | 0.029000 | 0.026000 | 0.000938 | 0.90x | 0.03x | 1/1/32 | `5000050000` |
| 35 | `generic_ipairs_50k` | 0.018000 | 0.006500 | 0.000195 | 0.36x | 0.01x | 2/2/256 | `1250025000` |
| 36 | `string_concat_10k` | 0.018000 | 0.021000 | 0.019000 | 1.17x | 1.06x | 1/2/2 | `10000` |
| 37 | `string_sub_50k` | 0.011500 | 0.010500 | 0.000025 | 0.91x | 0.00x | 2/2/1024 | `150000` |
| 38 | `string_byte_100k` | 0.016500 | 0.023000 | 0.000051 | 1.39x | 0.00x | 2/2/512 | `9700000` |
| 39 | `string_format_50k` | 0.012000 | 0.013000 | 0.002625 | 1.08x | 0.22x | 2/1/8 | `238894` |
| 40 | `string_gsub_10k` | 0.003000 | 0.003375 | 0.000781 | 1.13x | 0.26x | 8/8/32 | `30000` |
| 41 | `math_sqrt_100k` | 0.015500 | 0.015000 | 0.000453 | 0.97x | 0.03x | 2/1/64 | `21082008.973918` |
| 42 | `math_sin_100k` | 0.017000 | 0.025500 | 0.000516 | 1.50x | 0.03x | 2/2/64 | `1.8477771036304` |
| 43 | `math_floor_100k` | 0.018000 | 0.023000 | 0.000102 | 1.28x | 0.01x | 2/2/256 | `1666650000` |
| 44 | `varargs_count_100k` | 0.070000 | 0.145000 | 0.000051 | 2.07x | 0.00x | 1/1/512 | `200000` |
| 45 | `varargs_sum_100k` | 0.047000 | 0.142000 | 0.000066 | 3.02x | 0.00x | 1/1/256 | `10000200000` |
| 46 | `multiret_100k` | 0.048000 | 0.129000 | 0.000152 | 2.69x | 0.00x | 1/1/256 | `15000450000` |
| 47 | `multi_assign_100k` | 0.007000 | 0.005000 | 0.000051 | 0.71x | 0.01x | 4/8/512 | `300000` |
| 48 | `method_call_100k` | 0.040000 | 0.113000 | 0.000051 | 2.83x | 0.00x | 1/1/512 | `100000` |
| 49 | `metatable_add_100k` | 0.179000 | 0.107000 | 0.000051 | 0.60x | 0.00x | 1/1/512 | `300000` |
| 50 | `prime_count_10k` | 0.012000 | 0.008000 | 0.000234 | 0.67x | 0.02x | 2/2/128 | `1229` |

## Summary

Rows marked ERROR were not timed. Raw best-of-run data is in `BENCHMARK_50.csv`.

Important: FiOne is an old bytecode interpreter. This comparison measures execution speed of the two VMs, not source-to-closure compile speed. LuaJIT native uses `loadstring` and JIT; it is shown as a reference, not as a pure-Lua competitor.

Rows: 50, failures: 0

## Aggregate (median execution times)

- Cases: **50**.
- Ours faster than FiOne (>5%): **28**; slower (<-5%): **20**; within 5%: **2**.
- Geometric mean FiOne/ours speed ratio: **1.13x**.
- Sum of medians: ours **2.0559 s**, FiOne **4.6205 s**.
- Our VM is **not universally faster**: it wins call/closure/vararg-heavy cases, but loses several plain table, generic-for, while/repeat, and metamethod cases.
- LuaJIT native is orders of magnitude faster and is shown only as a reference.

## Limitations

- These are 50 project-local microbenchmarks, not a standardized suite.
- Execution only: FiOne bytecode compilation and our source compilation are excluded.
- FiOne is a Lua 5.1 bytecode interpreter; it needs an external Lua 5.1 compiler.
- LuaJIT native uses `loadstring` and JIT; it is not a pure-Lua competitor.
- Single machine, one process, JIT traces flushed per engine/case; warm-up plus 7 samples; results are indicative, not a statistically rigorous benchmark.
- No Scrap Mechanic in-game measurements.
