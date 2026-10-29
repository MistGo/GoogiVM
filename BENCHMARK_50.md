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
| 1 | `loop_sum_100k` | 0.001219 | 0.002438 | 0.000053 | 2.00x | 0.04x | 32/16/512 | `5000050000` |
| 2 | `loop_sum_1m` | 0.011500 | 0.024000 | 0.000516 | 2.09x | 0.04x | 2/2/64 | `500000500000` |
| 3 | `loop_add_const_1m` | 0.012000 | 0.024000 | 0.000500 | 2.00x | 0.04x | 2/2/64 | `2000000` |
| 4 | `loop_sub_1m` | 0.013500 | 0.023000 | 0.000516 | 1.70x | 0.04x | 2/2/64 | `-1000000` |
| 5 | `loop_mul_100k` | 0.003625 | 0.002312 | 0.000102 | 0.64x | 0.03x | 8/16/256 | `1.1051708628081` |
| 6 | `loop_mod_100k` | 0.008500 | 0.003375 | 0.000781 | 0.40x | 0.09x | 4/8/32 | `1` |
| 7 | `nested_loop_100x100` | 0.000145 | 0.000203 | 0.000005 | 1.41x | 0.04x | 256/128/4096 | `10000` |
| 8 | `while_sum_100k` | 0.013000 | 0.004125 | 0.000051 | 0.32x | 0.00x | 2/8/512 | `5000050000` |
| 9 | `repeat_sum_100k` | 0.011500 | 0.003375 | 0.000051 | 0.29x | 0.00x | 2/8/512 | `5000050000` |
| 10 | `loop_break_100k` | 0.003000 | 0.001875 | 0.000025 | 0.63x | 0.01x | 8/16/1024 | `1249975000` |
| 11 | `branch_if_1m` | 0.058000 | 0.047000 | 0.002438 | 0.81x | 0.04x | 1/1/16 | `250000000000` |
| 12 | `branch_and_or_100k` | 0.028000 | 0.005000 | 0.000453 | 0.18x | 0.02x | 1/4/64 | `99949` |
| 13 | `branch_mod3_100k` | 0.007250 | 0.006500 | 0.000375 | 0.90x | 0.05x | 4/4/64 | `1666716665` |
| 14 | `branch_nested_100k` | 0.007000 | 0.005500 | 0.000359 | 0.79x | 0.05x | 4/4/64 | `25000` |
| 15 | `calls_simple_1m` | 0.262000 | 0.826000 | 0.000516 | 3.15x | 0.00x | 1/1/64 | `1000000` |
| 16 | `calls_twoarg_1m` | 0.291000 | 0.864000 | 0.000516 | 2.97x | 0.00x | 1/1/64 | `1000000` |
| 17 | `calls_threearg_500k` | 0.174000 | 0.483000 | 0.000516 | 2.78x | 0.00x | 1/1/64 | `1500000` |
| 18 | `recursion_fib_20` | 0.006500 | 0.022000 | 0.000148 | 3.38x | 0.02x | 4/1/128 | `6765` |
| 19 | `recursion_fact_10` | 0.000011 | 0.000019 | 0.000000 | 1.62x | 0.02x | 4096/2048/8192 | `3628800` |
| 20 | `mutual_recursion_1000` | 0.000219 | 0.000750 | 0.000011 | 3.43x | 0.05x | 128/16/2048 | `true` |
| 21 | `tail_recursion_1000` | 0.000297 | 0.000812 | 0.000010 | 2.74x | 0.04x | 64/16/4096 | `500500` |
| 22 | `closures_create_100k` | 0.111000 | 0.095000 | 0.003000 | 0.86x | 0.03x | 1/1/1 | `100000` |
| 23 | `closure_upvalue_1m` | 0.228000 | 1.417000 | 0.000516 | 6.21x | 0.00x | 1/1/64 | `1000000` |
| 24 | `closure_factory_100k` | 0.133000 | 0.357000 | 0.012750 | 2.68x | 0.10x | 1/1/4 | `5000150000` |
| 25 | `closure_loop_capture_100k` | 0.085000 | 0.033000 | 0.011250 | 0.39x | 0.13x | 1/1/8 | `100000` |
| 26 | `table_write_200k` | 0.003250 | 0.005500 | 0.000625 | 1.69x | 0.19x | 8/4/64 | `200000` |
| 27 | `table_read_200k` | 0.008500 | 0.012500 | 0.000750 | 1.47x | 0.09x | 4/2/32 | `20000100000` |
| 28 | `table_mixed_100k` | 0.004875 | 0.005500 | 0.000375 | 1.13x | 0.08x | 8/4/64 | `5000050000` |
| 29 | `table_string_keys_50k` | 0.004750 | 0.002063 | 0.000098 | 0.43x | 0.02x | 8/16/256 | `4945050` |
| 30 | `table_constructor_100k` | 0.033000 | 0.037000 | 0.000051 | 1.12x | 0.00x | 1/1/512 | `5000050000` |
| 31 | `table_nested_50k` | 0.008500 | 0.008250 | 0.001500 | 0.97x | 0.18x | 2/4/4 | `1250025000` |
| 32 | `ipairs_100k` | 0.008750 | 0.014500 | 0.000391 | 1.66x | 0.04x | 4/2/64 | `5000050000` |
| 33 | `pairs_20k` | 0.002125 | 0.002750 | 0.000129 | 1.29x | 0.06x | 16/4/256 | `200010000` |
| 34 | `generic_next_100k` | 0.033000 | 0.027000 | 0.001063 | 0.82x | 0.03x | 1/1/32 | `5000050000` |
| 35 | `generic_ipairs_50k` | 0.004250 | 0.007000 | 0.000203 | 1.65x | 0.05x | 8/1/128 | `1250025000` |
| 36 | `string_concat_10k` | 0.004500 | 0.004625 | 0.003500 | 1.03x | 0.78x | 8/8/8 | `10000` |
| 37 | `string_sub_50k` | 0.012000 | 0.014750 | 0.000025 | 1.23x | 0.00x | 2/4/1024 | `150000` |
| 38 | `string_byte_100k` | 0.016000 | 0.017000 | 0.000051 | 1.06x | 0.00x | 2/1/512 | `9700000` |
| 39 | `string_format_50k` | 0.013500 | 0.015000 | 0.003875 | 1.11x | 0.29x | 2/2/8 | `238894` |
| 40 | `string_gsub_10k` | 0.002875 | 0.003000 | 0.000812 | 1.04x | 0.28x | 8/8/32 | `30000` |
| 41 | `math_sqrt_100k` | 0.015500 | 0.023000 | 0.000453 | 1.48x | 0.03x | 2/2/64 | `21082008.973918` |
| 42 | `math_sin_100k` | 0.017000 | 0.019000 | 0.000516 | 1.12x | 0.03x | 2/1/64 | `1.8477771036304` |
| 43 | `math_floor_100k` | 0.019500 | 0.026000 | 0.000102 | 1.33x | 0.01x | 2/2/256 | `1666650000` |
| 44 | `varargs_count_100k` | 0.086000 | 0.178000 | 0.000053 | 2.07x | 0.00x | 1/1/512 | `200000` |
| 45 | `varargs_sum_100k` | 0.051000 | 0.177000 | 0.000066 | 3.47x | 0.00x | 1/1/512 | `10000200000` |
| 46 | `multiret_100k` | 0.053000 | 0.155000 | 0.000152 | 2.92x | 0.00x | 1/1/256 | `15000450000` |
| 47 | `multi_assign_100k` | 0.010000 | 0.005000 | 0.000051 | 0.50x | 0.01x | 2/4/512 | `300000` |
| 48 | `method_call_100k` | 0.046000 | 0.157000 | 0.000051 | 3.41x | 0.00x | 1/1/512 | `100000` |
| 49 | `metatable_add_100k` | 0.028000 | 0.106000 | 0.000051 | 3.79x | 0.00x | 1/1/512 | `300000` |
| 50 | `prime_count_10k` | 0.008500 | 0.008750 | 0.000234 | 1.03x | 0.03x | 4/4/128 | `1229` |

## Summary

Rows marked ERROR were not timed. Raw best-of-run data is in `BENCHMARK_50.csv`.

Important: FiOne is an old bytecode interpreter. This comparison measures execution speed of the two VMs, not source-to-closure compile speed. LuaJIT native uses `loadstring` and JIT; it is shown as a reference, not as a pure-Lua competitor.

Rows: 50, failures: 0

## Aggregate (median execution times)

- Cases: **50**.
- Ours faster than FiOne (>5%): **32**; slower (<-5%): **14**; within 5%: **4**.
- Geometric mean FiOne/ours speed ratio: **1.30x**.
- Sum of medians: ours **1.9636 s**, FiOne **5.2825 s** (**2.69x** overall speedup).
- Our VM wins call/closure/vararg-heavy, generic-for (`ipairs`/`pairs`), table constructor, prime-sieve, and metamethod cases.
- LuaJIT native is orders of magnitude faster and is shown only as a reference.

## Limitations

- These are 50 project-local microbenchmarks, not a standardized suite.
- Execution only: FiOne bytecode compilation and our source compilation are excluded.
- FiOne is a Lua 5.1 bytecode interpreter; it needs an external Lua 5.1 compiler.
- LuaJIT native uses `loadstring` and JIT; it is not a pure-Lua competitor.
- Single machine, one process, JIT traces flushed per engine/case; warm-up plus 7 samples; results are indicative, not a statistically rigorous benchmark.
