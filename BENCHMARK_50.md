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
- Every number in this report is the **median of 10 consecutive full runs** of the suite on the same machine.
- Each run records the median of its 7 measured samples; the report takes the median across runs.
- `reps` and `result` are taken from the first run; they are identical across runs.
- `bench50_actual.lua` also writes an untracked `BENCHMARK_50_raw.csv` with every individual sample of a single run.
- Native LuaJIT is a reference baseline, not a pure-Lua competitor.

## Results

| # | Case | GoogiVM (s) | FiOne (s) | LuaJIT native (s) | FiOne / GoogiVM | Native / GoogiVM | Reps O/F/N | Result |
|---:|---|---:|---:|---:|---:|---:|---:|---|
| 1 | `loop_sum_100k` | 0.000906 | 0.002000 | 0.000053 | 2.21x | 0.06x | 32/16/512 | `5000050000` |
| 2 | `loop_sum_1m` | 0.008750 | 0.019000 | 0.000516 | 2.17x | 0.06x | 4/1/64 | `500000500000` |
| 3 | `loop_add_const_1m` | 0.009000 | 0.018500 | 0.000500 | 2.06x | 0.06x | 4/1/64 | `2000000` |
| 4 | `loop_sub_1m` | 0.008750 | 0.019000 | 0.000500 | 2.17x | 0.06x | 4/1/64 | `-1000000` |
| 5 | `loop_mul_100k` | 0.001063 | 0.001906 | 0.000102 | 1.79x | 0.10x | 32/16/256 | `1.1051708628081` |
| 6 | `loop_mod_100k` | 0.002000 | 0.003250 | 0.000781 | 1.63x | 0.39x | 16/8/32 | `1` |
| 7 | `nested_loop_100x100` | 0.000098 | 0.000203 | 0.000005 | 2.08x | 0.05x | 256/128/4096 | `10000` |
| 8 | `while_sum_100k` | 0.003500 | 0.003875 | 0.000051 | 1.11x | 0.01x | 8/8/512 | `5000050000` |
| 9 | `repeat_sum_100k` | 0.003000 | 0.003250 | 0.000051 | 1.08x | 0.02x | 8/8/512 | `5000050000` |
| 10 | `loop_break_100k` | 0.001563 | 0.001875 | 0.000025 | 1.20x | 0.02x | 16/16/1024 | `1249975000` |
| 11 | `branch_if_1m` | 0.036000 | 0.045000 | 0.002437 | 1.25x | 0.07x | 1/1/16 | `250000000000` |
| 12 | `branch_and_or_100k` | 0.005500 | 0.004875 | 0.000453 | 0.89x | 0.08x | 4/4/64 | `99949` |
| 13 | `branch_mod3_100k` | 0.004625 | 0.006500 | 0.000359 | 1.41x | 0.08x | 8/4/64 | `1666716665` |
| 14 | `branch_nested_100k` | 0.004500 | 0.005500 | 0.000344 | 1.22x | 0.08x | 8/4/64 | `25000` |
| 15 | `calls_simple_1m` | 0.131000 | 0.786500 | 0.000516 | 6.00x | 0.00x | 1/1/64 | `1000000` |
| 16 | `calls_twoarg_1m` | 0.147000 | 0.846000 | 0.000500 | 5.76x | 0.00x | 1/1/64 | `1000000` |
| 17 | `calls_threearg_500k` | 0.090500 | 0.486500 | 0.000508 | 5.38x | 0.01x | 1/1/64 | `1500000` |
| 18 | `recursion_fib_20` | 0.002875 | 0.021000 | 0.000145 | 7.30x | 0.05x | 8/1/256 | `6765` |
| 19 | `recursion_fact_10` | 0.000011 | 0.000014 | 0.000000 | 1.27x | 0.01x | 2048/2048/8192 | `3628800` |
| 20 | `mutual_recursion_1000` | 0.000090 | 0.001016 | 0.000006 | 11.30x | 0.07x | 256/32/4096 | `true` |
| 21 | `tail_recursion_1000` | 0.000102 | 0.001203 | 0.000008 | 11.85x | 0.08x | 256/16/4096 | `500500` |
| 22 | `closures_create_100k` | 0.071000 | 0.060500 | 0.008875 | 0.85x | 0.13x | 1/1/4 | `100000` |
| 23 | `closure_upvalue_1m` | 0.149000 | 1.252000 | 0.000516 | 8.40x | 0.00x | 1/1/64 | `1000000` |
| 24 | `closure_factory_100k` | 0.118000 | 0.335500 | 0.010625 | 2.84x | 0.09x | 1/1/4 | `5000150000` |
| 25 | `closure_loop_capture_100k` | 0.060500 | 0.037500 | 0.006250 | 0.62x | 0.10x | 1/1/4 | `100000` |
| 26 | `table_write_200k` | 0.002625 | 0.005250 | 0.000609 | 2.00x | 0.23x | 8/8/64 | `200000` |
| 27 | `table_read_200k` | 0.006500 | 0.012500 | 0.000719 | 1.92x | 0.11x | 4/2/32 | `20000100000` |
| 28 | `table_mixed_100k` | 0.003375 | 0.005250 | 0.000344 | 1.56x | 0.10x | 8/4/64 | `5000050000` |
| 29 | `table_string_keys_50k` | 0.001156 | 0.002031 | 0.000090 | 1.76x | 0.08x | 32/16/256 | `4945050` |
| 30 | `table_constructor_100k` | 0.018500 | 0.021000 | 0.000051 | 1.14x | 0.00x | 2/1/512 | `5000050000` |
| 31 | `table_nested_50k` | 0.005375 | 0.006000 | 0.002125 | 1.12x | 0.40x | 1/4/4 | `1250025000` |
| 32 | `ipairs_100k` | 0.004125 | 0.016750 | 0.000391 | 4.06x | 0.09x | 8/2/128 | `5000050000` |
| 33 | `pairs_20k` | 0.000891 | 0.002938 | 0.000128 | 3.30x | 0.14x | 32/8/512 | `200010000` |
| 34 | `generic_next_100k` | 0.019000 | 0.029500 | 0.000937 | 1.55x | 0.05x | 2/1/32 | `5000050000` |
| 35 | `generic_ipairs_50k` | 0.002125 | 0.008375 | 0.000195 | 3.94x | 0.09x | 16/4/256 | `1250025000` |
| 36 | `string_concat_10k` | 0.010937 | 0.011375 | 0.010188 | 1.04x | 0.93x | 2/1/2 | `10000` |
| 37 | `string_sub_50k` | 0.007750 | 0.012000 | 0.000025 | 1.55x | 0.00x | 4/2/1024 | `150000` |
| 38 | `string_byte_100k` | 0.009500 | 0.023750 | 0.000051 | 2.50x | 0.01x | 4/2/512 | `9700000` |
| 39 | `string_format_50k` | 0.007375 | 0.013250 | 0.002875 | 1.80x | 0.39x | 4/2/8 | `238894` |
| 40 | `string_gsub_10k` | 0.002188 | 0.003000 | 0.000781 | 1.37x | 0.36x | 16/2/32 | `30000` |
| 41 | `math_sqrt_100k` | 0.009125 | 0.016000 | 0.000453 | 1.75x | 0.05x | 4/1/64 | `21082008.973918` |
| 42 | `math_sin_100k` | 0.009750 | 0.021000 | 0.000516 | 2.15x | 0.05x | 4/2/64 | `1.8477771036304` |
| 43 | `math_floor_100k` | 0.009750 | 0.016750 | 0.000102 | 1.72x | 0.01x | 4/1/256 | `1666650000` |
| 44 | `varargs_count_100k` | 0.060000 | 0.148500 | 0.000051 | 2.48x | 0.00x | 1/1/512 | `200000` |
| 45 | `varargs_sum_100k` | 0.026000 | 0.150500 | 0.000064 | 5.79x | 0.00x | 1/1/512 | `10000200000` |
| 46 | `multiret_100k` | 0.025000 | 0.134000 | 0.000152 | 5.36x | 0.01x | 1/1/256 | `15000450000` |
| 47 | `multi_assign_100k` | 0.003500 | 0.005000 | 0.000051 | 1.43x | 0.01x | 8/4/512 | `300000` |
| 48 | `method_call_100k` | 0.021000 | 0.124500 | 0.000051 | 5.93x | 0.00x | 1/1/512 | `100000` |
| 49 | `metatable_add_100k` | 0.014000 | 0.121000 | 0.000051 | 8.64x | 0.00x | 2/1/512 | `300000` |
| 50 | `prime_count_10k` | 0.005437 | 0.008250 | 0.000234 | 1.52x | 0.04x | 4/4/128 | `1229` |

## Aggregate (median execution times)

- Cases: **50** (failures: 0).
- GoogiVM faster than FiOne (>5%): **46**; slower (<-5%): **3**; within 5%: **1**.
- Geometric mean FiOne/GoogiVM speed ratio: **2.27x**.
- Sum of medians: GoogiVM **1.1443 s**, FiOne **4.8809 s** (**4.27x**).

## Limitations

- These are 50 project-local microbenchmarks, not a standardized suite.
- Execution only: FiOne bytecode compilation and GoogiVM compilation are excluded.
- FiOne is a Lua 5.1 bytecode interpreter; it needs an external Lua 5.1 compiler.
- LuaJIT native uses `loadstring` and JIT; it is not a pure-Lua competitor.
- Single machine; absolute seconds drift with host load, so the ratios are the stable metric.
- The median over 10 runs suppresses outliers; a trimmed mean (fastest and slowest run dropped) and the plain mean agree with it within a few percent.
