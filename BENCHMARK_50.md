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
| 1 | `loop_sum_100k` | 0.001062 | 0.002063 | 0.000055 | 1.94x | 0.05x | 32/16/512 | `5000050000` |
| 2 | `loop_sum_1m` | 0.009250 | 0.019000 | 0.000500 | 2.05x | 0.05x | 4/2/64 | `500000500000` |
| 3 | `loop_add_const_1m` | 0.009375 | 0.018250 | 0.000500 | 1.95x | 0.05x | 4/2/64 | `2000000` |
| 4 | `loop_sub_1m` | 0.008875 | 0.018500 | 0.000500 | 2.08x | 0.06x | 4/2/64 | `-1000000` |
| 5 | `loop_mul_100k` | 0.000906 | 0.001875 | 0.000102 | 2.07x | 0.11x | 32/16/256 | `1.1051708628081` |
| 6 | `loop_mod_100k` | 0.001812 | 0.003250 | 0.000781 | 1.79x | 0.43x | 16/8/32 | `1` |
| 7 | `nested_loop_100x100` | 0.000102 | 0.000203 | 0.000005 | 2.00x | 0.05x | 256/128/4096 | `10000` |
| 8 | `while_sum_100k` | 0.002750 | 0.003875 | 0.000051 | 1.41x | 0.02x | 8/8/512 | `5000050000` |
| 9 | `repeat_sum_100k` | 0.003000 | 0.003250 | 0.000051 | 1.08x | 0.02x | 8/8/512 | `5000050000` |
| 10 | `loop_break_100k` | 0.001500 | 0.001875 | 0.000025 | 1.25x | 0.02x | 16/16/1024 | `1249975000` |
| 11 | `branch_if_1m` | 0.033000 | 0.045500 | 0.002437 | 1.38x | 0.07x | 1/1/16 | `250000000000` |
| 12 | `branch_and_or_100k` | 0.005000 | 0.004875 | 0.000453 | 0.98x | 0.09x | 4/8/64 | `99949` |
| 13 | `branch_mod3_100k` | 0.004375 | 0.006500 | 0.000359 | 1.49x | 0.08x | 8/4/64 | `1666716665` |
| 14 | `branch_nested_100k` | 0.004125 | 0.005500 | 0.000242 | 1.33x | 0.06x | 8/4/128 | `25000` |
| 15 | `calls_simple_1m` | 0.122000 | 0.720000 | 0.000508 | 5.90x | 0.00x | 1/1/64 | `1000000` |
| 16 | `calls_twoarg_1m` | 0.127000 | 0.805500 | 0.000516 | 6.34x | 0.00x | 1/1/64 | `1000000` |
| 17 | `calls_threearg_500k` | 0.078000 | 0.447000 | 0.000508 | 5.73x | 0.01x | 1/1/64 | `1500000` |
| 18 | `recursion_fib_20` | 0.002563 | 0.020000 | 0.000145 | 7.80x | 0.06x | 8/1/256 | `6765` |
| 19 | `recursion_fact_10` | 0.000011 | 0.000016 | 0.000000 | 1.48x | 0.01x | 4096/2048/8192 | `3628800` |
| 20 | `mutual_recursion_1000` | 0.000078 | 0.000656 | 0.000007 | 8.40x | 0.09x | 256/16/4096 | `true` |
| 21 | `tail_recursion_1000` | 0.000088 | 0.000781 | 0.000008 | 8.89x | 0.09x | 256/16/4096 | `500500` |
| 22 | `closures_create_100k` | 0.071500 | 0.072000 | 0.012000 | 1.01x | 0.17x | 1/1/4 | `100000` |
| 23 | `closure_upvalue_1m` | 0.136000 | 1.460000 | 0.000516 | 10.74x | 0.00x | 1/1/64 | `1000000` |
| 24 | `closure_factory_100k` | 0.097000 | 0.387500 | 0.012250 | 3.99x | 0.13x | 1/1/4 | `5000150000` |
| 25 | `closure_loop_capture_100k` | 0.045500 | 0.038000 | 0.009875 | 0.84x | 0.22x | 1/1/8 | `100000` |
| 26 | `table_write_200k` | 0.002625 | 0.006000 | 0.000641 | 2.29x | 0.24x | 8/4/64 | `200000` |
| 27 | `table_read_200k` | 0.006500 | 0.012500 | 0.000750 | 1.92x | 0.12x | 4/2/32 | `20000100000` |
| 28 | `table_mixed_100k` | 0.003125 | 0.005250 | 0.000344 | 1.68x | 0.11x | 8/4/64 | `5000050000` |
| 29 | `table_string_keys_50k` | 0.001094 | 0.002031 | 0.000094 | 1.86x | 0.09x | 32/16/32 | `4945050` |
| 30 | `table_constructor_100k` | 0.017000 | 0.020000 | 0.000051 | 1.18x | 0.00x | 1/1/512 | `5000050000` |
| 31 | `table_nested_50k` | 0.005375 | 0.006625 | 0.005750 | 1.23x | 1.07x | 4/4/8 | `1250025000` |
| 32 | `ipairs_100k` | 0.004250 | 0.016500 | 0.000391 | 3.88x | 0.09x | 8/2/128 | `5000050000` |
| 33 | `pairs_20k` | 0.000938 | 0.003750 | 0.000129 | 4.00x | 0.14x | 32/8/256 | `200010000` |
| 34 | `generic_next_100k` | 0.018000 | 0.026500 | 0.001016 | 1.47x | 0.06x | 1/1/32 | `5000050000` |
| 35 | `generic_ipairs_50k` | 0.002156 | 0.008250 | 0.000207 | 3.83x | 0.10x | 16/4/256 | `1250025000` |
| 36 | `string_concat_10k` | 0.004375 | 0.004625 | 0.003625 | 1.06x | 0.83x | 8/4/8 | `10000` |
| 37 | `string_sub_50k` | 0.007250 | 0.010875 | 0.000025 | 1.50x | 0.00x | 4/4/1024 | `150000` |
| 38 | `string_byte_100k` | 0.009000 | 0.017250 | 0.000051 | 1.92x | 0.01x | 4/2/512 | `9700000` |
| 39 | `string_format_50k` | 0.007375 | 0.013750 | 0.003125 | 1.86x | 0.42x | 4/2/8 | `238894` |
| 40 | `string_gsub_10k` | 0.002125 | 0.003250 | 0.000797 | 1.53x | 0.38x | 16/8/32 | `30000` |
| 41 | `math_sqrt_100k` | 0.008750 | 0.016750 | 0.000453 | 1.91x | 0.05x | 4/2/64 | `21082008.973918` |
| 42 | `math_sin_100k` | 0.009250 | 0.018500 | 0.000508 | 2.00x | 0.05x | 4/2/64 | `1.8477771036304` |
| 43 | `math_floor_100k` | 0.009000 | 0.018000 | 0.000105 | 2.00x | 0.01x | 4/1/256 | `1666650000` |
| 44 | `varargs_count_100k` | 0.062500 | 0.192000 | 0.000051 | 3.07x | 0.00x | 1/1/512 | `200000` |
| 45 | `varargs_sum_100k` | 0.027500 | 0.165000 | 0.000065 | 6.00x | 0.00x | 1/1/512 | `10000200000` |
| 46 | `multiret_100k` | 0.021000 | 0.160000 | 0.000152 | 7.62x | 0.01x | 1/1/256 | `15000450000` |
| 47 | `multi_assign_100k` | 0.003375 | 0.005000 | 0.000052 | 1.48x | 0.02x | 8/4/512 | `300000` |
| 48 | `method_call_100k` | 0.018000 | 0.150000 | 0.000051 | 8.33x | 0.00x | 2/1/512 | `100000` |
| 49 | `metatable_add_100k` | 0.012000 | 0.132500 | 0.000051 | 11.04x | 0.00x | 2/1/512 | `300000` |
| 50 | `prime_count_10k` | 0.005500 | 0.008125 | 0.000238 | 1.48x | 0.04x | 4/4/128 | `1229` |

## Aggregate (median execution times)

- Cases: **50** (failures: 0).
- GoogiVM faster than FiOne (>5%): **47**; slower (<-5%): **1**; within 5%: **2**.
- Geometric mean FiOne/GoogiVM speed ratio: **2.41x**.
- Sum of medians: GoogiVM **1.0329 s**, FiOne **5.1090 s** (**4.95x**).

## Limitations

- These are 50 project-local microbenchmarks, not a standardized suite.
- Execution only: FiOne bytecode compilation and GoogiVM compilation are excluded.
- FiOne is a Lua 5.1 bytecode interpreter; it needs an external Lua 5.1 compiler.
- LuaJIT native uses `loadstring` and JIT; it is not a pure-Lua competitor.
- Single machine, one process, JIT traces flushed per engine/case; results are indicative, not statistically rigorous.
