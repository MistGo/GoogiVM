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
- Per run: 3 warm-up iterations, 7 measured iterations; JIT traces are flushed before each engine/case measurement.
- Every number in this report is the **median of 10 consecutive full runs** of the suite on the same machine.
- Each run records the median of its 7 measured samples; the report takes the median across runs.
- `reps` and `result` are taken from the first run; they are identical across runs.
- `bench50_actual.lua` also writes an untracked `BENCHMARK_50_raw.csv` with every individual sample of a single run.
- Native LuaJIT is a reference baseline, not a pure-Lua competitor.

## Results

| # | Case | GoogiVM (s) | FiOne (s) | LuaJIT native (s) | FiOne / GoogiVM | Native / GoogiVM | Reps O/F/N | Result |
|---:|---|---:|---:|---:|---:|---:|---:|---|
| 1 | `loop_sum_100k` | 0.000844 | 0.002063 | 0.000051 | 2.44x | 0.06x | 32/16/512 | `5000050000` |
| 2 | `loop_sum_1m` | 0.008625 | 0.019250 | 0.000500 | 2.23x | 0.06x | 4/1/64 | `500000500000` |
| 3 | `loop_add_const_1m` | 0.008750 | 0.019000 | 0.000500 | 2.17x | 0.06x | 4/2/64 | `2000000` |
| 4 | `loop_sub_1m` | 0.008750 | 0.019000 | 0.000500 | 2.17x | 0.06x | 4/2/64 | `-1000000` |
| 5 | `loop_mul_100k` | 0.000937 | 0.001906 | 0.000102 | 2.03x | 0.11x | 32/16/256 | `1.1051708628081` |
| 6 | `loop_mod_100k` | 0.001781 | 0.003250 | 0.000781 | 1.82x | 0.44x | 16/8/32 | `1` |
| 7 | `nested_loop_100x100` | 0.000094 | 0.000203 | 0.000005 | 2.17x | 0.05x | 256/128/4096 | `10000` |
| 8 | `while_sum_100k` | 0.003500 | 0.003812 | 0.000051 | 1.09x | 0.01x | 8/8/512 | `5000050000` |
| 9 | `repeat_sum_100k` | 0.003000 | 0.003250 | 0.000051 | 1.08x | 0.02x | 8/8/512 | `5000050000` |
| 10 | `loop_break_100k` | 0.001437 | 0.001875 | 0.000025 | 1.30x | 0.02x | 16/16/1024 | `1249975000` |
| 11 | `branch_if_1m` | 0.034000 | 0.045000 | 0.002437 | 1.32x | 0.07x | 1/1/8 | `250000000000` |
| 12 | `branch_and_or_100k` | 0.005188 | 0.004938 | 0.000453 | 0.95x | 0.09x | 8/8/64 | `99949` |
| 13 | `branch_mod3_100k` | 0.004500 | 0.006500 | 0.000359 | 1.44x | 0.08x | 4/4/64 | `1666716665` |
| 14 | `branch_nested_100k` | 0.004375 | 0.005500 | 0.000344 | 1.26x | 0.08x | 8/4/64 | `25000` |
| 15 | `calls_simple_1m` | 0.129000 | 0.748500 | 0.000500 | 5.80x | 0.00x | 1/1/64 | `1000000` |
| 16 | `calls_twoarg_1m` | 0.139500 | 0.840500 | 0.000500 | 6.03x | 0.00x | 1/1/64 | `1000000` |
| 17 | `calls_threearg_500k` | 0.081500 | 0.467000 | 0.000500 | 5.73x | 0.01x | 1/1/64 | `1500000` |
| 18 | `recursion_fib_20` | 0.002750 | 0.021000 | 0.000145 | 7.64x | 0.05x | 8/1/256 | `6765` |
| 19 | `recursion_fact_10` | 0.000011 | 0.000014 | 0.000000 | 1.33x | 0.01x | 4096/1024/8192 | `3628800` |
| 20 | `mutual_recursion_1000` | 0.000082 | 0.001125 | 0.000006 | 13.71x | 0.08x | 256/32/4096 | `true` |
| 21 | `tail_recursion_1000` | 0.000096 | 0.001219 | 0.000008 | 12.73x | 0.09x | 256/8/4096 | `500500` |
| 22 | `closures_create_100k` | 0.059500 | 0.061000 | 0.009250 | 1.03x | 0.16x | 1/1/2 | `100000` |
| 23 | `closure_upvalue_1m` | 0.136500 | 1.324500 | 0.000500 | 9.70x | 0.00x | 1/1/64 | `1000000` |
| 24 | `closure_factory_100k` | 0.098000 | 0.343000 | 0.009500 | 3.50x | 0.10x | 1/1/4 | `5000150000` |
| 25 | `closure_loop_capture_100k` | 0.041500 | 0.073000 | 0.008125 | 1.76x | 0.20x | 1/1/4 | `100000` |
| 26 | `table_write_200k` | 0.002500 | 0.005250 | 0.000617 | 2.10x | 0.25x | 8/4/64 | `200000` |
| 27 | `table_read_200k` | 0.006375 | 0.012500 | 0.000734 | 1.96x | 0.12x | 4/2/32 | `20000100000` |
| 28 | `table_mixed_100k` | 0.003188 | 0.005250 | 0.000344 | 1.65x | 0.11x | 8/4/64 | `5000050000` |
| 29 | `table_string_keys_50k` | 0.001078 | 0.002000 | 0.000090 | 1.86x | 0.08x | 32/8/256 | `4945050` |
| 30 | `table_constructor_100k` | 0.017000 | 0.022500 | 0.000051 | 1.32x | 0.00x | 1/2/512 | `5000050000` |
| 31 | `table_nested_50k` | 0.005875 | 0.006625 | 0.001625 | 1.13x | 0.28x | 1/4/4 | `1250025000` |
| 32 | `ipairs_100k` | 0.004250 | 0.016250 | 0.000375 | 3.82x | 0.09x | 8/2/128 | `5000050000` |
| 33 | `pairs_20k` | 0.000906 | 0.002812 | 0.000127 | 3.10x | 0.14x | 32/8/512 | `200010000` |
| 34 | `generic_next_100k` | 0.018000 | 0.029000 | 0.000937 | 1.61x | 0.05x | 2/1/32 | `5000050000` |
| 35 | `generic_ipairs_50k` | 0.002125 | 0.009000 | 0.000201 | 4.24x | 0.09x | 16/4/256 | `1250025000` |
| 36 | `string_concat_10k` | 0.003938 | 0.004313 | 0.003500 | 1.10x | 0.89x | 8/8/8 | `10000` |
| 37 | `string_sub_50k` | 0.007125 | 0.012875 | 0.000025 | 1.81x | 0.00x | 4/4/1024 | `150000` |
| 38 | `string_byte_100k` | 0.008750 | 0.023500 | 0.000051 | 2.69x | 0.01x | 4/2/512 | `9700000` |
| 39 | `string_format_50k` | 0.006875 | 0.012250 | 0.002750 | 1.78x | 0.40x | 4/1/8 | `238894` |
| 40 | `string_gsub_10k` | 0.002094 | 0.003000 | 0.000781 | 1.43x | 0.37x | 16/8/32 | `30000` |
| 41 | `math_sqrt_100k` | 0.008500 | 0.016000 | 0.000453 | 1.88x | 0.05x | 4/1/64 | `21082008.973918` |
| 42 | `math_sin_100k` | 0.009000 | 0.017500 | 0.000500 | 1.94x | 0.06x | 4/1/64 | `1.8477771036304` |
| 43 | `math_floor_100k` | 0.009000 | 0.015750 | 0.000102 | 1.75x | 0.01x | 4/2/256 | `1666650000` |
| 44 | `varargs_count_100k` | 0.061500 | 0.150000 | 0.000051 | 2.44x | 0.00x | 1/1/512 | `200000` |
| 45 | `varargs_sum_100k` | 0.025000 | 0.148500 | 0.000063 | 5.94x | 0.00x | 1/1/512 | `10000200000` |
| 46 | `multiret_100k` | 0.022000 | 0.135000 | 0.000152 | 6.14x | 0.01x | 1/1/256 | `15000450000` |
| 47 | `multi_assign_100k` | 0.003500 | 0.004875 | 0.000051 | 1.39x | 0.01x | 8/8/512 | `300000` |
| 48 | `method_call_100k` | 0.018500 | 0.123500 | 0.000051 | 6.68x | 0.00x | 2/1/512 | `100000` |
| 49 | `metatable_add_100k` | 0.013000 | 0.122000 | 0.000051 | 9.38x | 0.00x | 2/1/512 | `300000` |
| 50 | `prime_count_10k` | 0.005000 | 0.008250 | 0.000230 | 1.65x | 0.05x | 4/4/128 | `1229` |

## Aggregate (median execution times)

- Cases: **50** (failures: 0).
- GoogiVM faster than FiOne (>5%): **48**; slower (<-5%): **0**; within 5%: **2**.
- Geometric mean FiOne/GoogiVM speed ratio: **2.45x**.
- Sum of medians: GoogiVM **1.0393 s**, FiOne **4.9249 s** (**4.74x**).

## Limitations

- These are 50 project-local microbenchmarks, not a standardized suite.
- Execution only: FiOne bytecode compilation and GoogiVM compilation are excluded.
- FiOne is a Lua 5.1 bytecode interpreter; it needs an external Lua 5.1 compiler.
- LuaJIT native uses `loadstring` and JIT; it is not a pure-Lua competitor.
- Single machine; absolute seconds drift with host load, so the ratios are the stable metric.
- The median over 10 runs suppresses outliers; a trimmed mean (fastest and slowest run dropped) and the plain mean agree with it within a few percent.
