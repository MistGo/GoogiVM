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
| 1 | `loop_sum_100k` | 0.001917 | 0.003250 | 0.000082 | 1.70x | 0.04x | 16/8/256 | `5000050000` |
| 2 | `loop_sum_1m` | 0.018667 | 0.032333 | 0.000812 | 1.73x | 0.04x | 2/1/32 | `500000500000` |
| 3 | `loop_add_const_1m` | 0.019000 | 0.030000 | 0.000812 | 1.58x | 0.04x | 2/1/32 | `2000000` |
| 4 | `loop_sub_1m` | 0.022000 | 0.031667 | 0.000812 | 1.44x | 0.04x | 1/1/32 | `-1000000` |
| 5 | `loop_mul_100k` | 0.005750 | 0.003167 | 0.000164 | 0.55x | 0.03x | 4/8/128 | `1.1051708628081` |
| 6 | `loop_mod_100k` | 0.013333 | 0.004917 | 0.001250 | 0.37x | 0.09x | 2/4/32 | `1` |
| 7 | `nested_loop_100x100` | 0.000229 | 0.000328 | 0.000008 | 1.43x | 0.04x | 128/64/4096 | `10000` |
| 8 | `while_sum_100k` | 0.020333 | 0.006083 | 0.000082 | 0.30x | 0.00x | 1/4/256 | `5000050000` |
| 9 | `repeat_sum_100k` | 0.018667 | 0.005458 | 0.000082 | 0.29x | 0.00x | 2/4/256 | `5000050000` |
| 10 | `loop_break_100k` | 0.004875 | 0.002833 | 0.000041 | 0.58x | 0.01x | 8/8/512 | `1249975000` |
| 11 | `branch_if_1m` | 0.092667 | 0.074667 | 0.003875 | 0.81x | 0.04x | 1/1/8 | `250000000000` |
| 12 | `branch_and_or_100k` | 0.045667 | 0.008333 | 0.000740 | 0.18x | 0.02x | 1/4/32 | `99949` |
| 13 | `branch_mod3_100k` | 0.011333 | 0.010333 | 0.000594 | 0.91x | 0.05x | 2/4/64 | `1666716665` |
| 14 | `branch_nested_100k` | 0.011000 | 0.009167 | 0.000562 | 0.83x | 0.05x | 2/4/64 | `25000` |
| 15 | `calls_simple_1m` | 0.407667 | 1.284667 | 0.000812 | 3.15x | 0.00x | 1/1/32 | `1000000` |
| 16 | `calls_twoarg_1m` | 0.464000 | 1.379000 | 0.000812 | 2.97x | 0.00x | 1/1/32 | `1000000` |
| 17 | `calls_threearg_500k` | 0.281667 | 0.778000 | 0.000812 | 2.76x | 0.00x | 1/1/32 | `1500000` |
| 18 | `recursion_fib_20` | 0.010500 | 0.034000 | 0.000234 | 3.24x | 0.02x | 2/1/128 | `6765` |
| 19 | `recursion_fact_10` | 0.000020 | 0.000022 | 0.000000 | 1.13x | 0.01x | 2048/1024/8192 | `3628800` |
| 20 | `mutual_recursion_1000` | 0.000333 | 0.001542 | 0.000010 | 4.63x | 0.03x | 64/16/4096 | `true` |
| 21 | `tail_recursion_1000` | 0.000448 | 0.002021 | 0.000014 | 4.51x | 0.03x | 64/16/2048 | `500500` |
| 22 | `closures_create_100k` | 0.144000 | 0.097000 | 0.011167 | 0.67x | 0.08x | 1/1/2 | `100000` |
| 23 | `closure_upvalue_1m` | 0.364000 | 1.762667 | 0.000812 | 4.84x | 0.00x | 1/1/32 | `1000000` |
| 24 | `closure_factory_100k` | 0.204667 | 0.470333 | 0.013333 | 2.30x | 0.07x | 1/1/1 | `5000150000` |
| 25 | `closure_loop_capture_100k` | 0.104000 | 0.053667 | 0.029583 | 0.52x | 0.28x | 1/1/4 | `100000` |
| 26 | `table_write_200k` | 0.005250 | 0.008167 | 0.000932 | 1.56x | 0.18x | 4/4/64 | `200000` |
| 27 | `table_read_200k` | 0.013333 | 0.020333 | 0.001219 | 1.52x | 0.09x | 2/1/16 | `20000100000` |
| 28 | `table_mixed_100k` | 0.008000 | 0.007833 | 0.000536 | 0.98x | 0.07x | 4/4/64 | `5000050000` |
| 29 | `table_string_keys_50k` | 0.007833 | 0.002708 | 0.000137 | 0.35x | 0.02x | 4/8/16 | `4945050` |
| 30 | `table_constructor_100k` | 0.045667 | 0.037333 | 0.000082 | 0.82x | 0.00x | 1/1/256 | `5000050000` |
| 31 | `table_nested_50k` | 0.014667 | 0.011333 | 0.002083 | 0.77x | 0.14x | 2/2/4 | `1250025000` |
| 32 | `ipairs_100k` | 0.013333 | 0.026000 | 0.000385 | 1.95x | 0.03x | 2/1/64 | `5000050000` |
| 33 | `pairs_20k` | 0.002708 | 0.004542 | 0.000116 | 1.68x | 0.04x | 8/8/256 | `200010000` |
| 34 | `generic_next_100k` | 0.050000 | 0.042000 | 0.001500 | 0.84x | 0.03x | 1/1/16 | `5000050000` |
| 35 | `generic_ipairs_50k` | 0.006667 | 0.011333 | 0.000188 | 1.70x | 0.03x | 4/2/128 | `1250025000` |
| 36 | `string_concat_10k` | 0.025667 | 0.026667 | 0.024667 | 1.04x | 0.96x | 1/1/1 | `10000` |
| 37 | `string_sub_50k` | 0.019000 | 0.016167 | 0.000041 | 0.85x | 0.00x | 2/1/512 | `150000` |
| 38 | `string_byte_100k` | 0.026333 | 0.024667 | 0.000082 | 0.94x | 0.00x | 1/1/256 | `9700000` |
| 39 | `string_format_50k` | 0.018333 | 0.020500 | 0.004333 | 1.12x | 0.24x | 1/1/8 | `238894` |
| 40 | `string_gsub_10k` | 0.004667 | 0.004625 | 0.001271 | 0.99x | 0.27x | 4/4/16 | `30000` |
| 41 | `math_sqrt_100k` | 0.025333 | 0.025333 | 0.000729 | 1.00x | 0.03x | 1/1/32 | `21082008.973918` |
| 42 | `math_sin_100k` | 0.026667 | 0.026000 | 0.000812 | 0.97x | 0.03x | 1/1/32 | `1.8477771036304` |
| 43 | `math_floor_100k` | 0.031667 | 0.026333 | 0.000164 | 0.83x | 0.01x | 1/1/128 | `1666650000` |
| 44 | `varargs_count_100k` | 0.117000 | 0.202333 | 0.000082 | 1.73x | 0.00x | 1/1/256 | `200000` |
| 45 | `varargs_sum_100k` | 0.082000 | 0.202000 | 0.000103 | 2.46x | 0.00x | 1/1/256 | `10000200000` |
| 46 | `multiret_100k` | 0.083000 | 0.179000 | 0.000245 | 2.16x | 0.00x | 1/1/128 | `15000450000` |
| 47 | `multi_assign_100k` | 0.016500 | 0.008083 | 0.000082 | 0.49x | 0.00x | 2/4/256 | `300000` |
| 48 | `method_call_100k` | 0.071667 | 0.169667 | 0.000082 | 2.37x | 0.00x | 1/1/256 | `100000` |
| 49 | `metatable_add_100k` | 0.045667 | 0.163333 | 0.000083 | 3.58x | 0.00x | 1/1/256 | `300000` |
| 50 | `prime_count_10k` | 0.013333 | 0.013167 | 0.000375 | 0.99x | 0.03x | 2/2/64 | `1229` |

## Aggregate (mean execution times)

- Cases: **50** (failures: 0).
- GoogiVM faster than FiOne (>5%): **25**; slower (<-5%): **19**; within 5%: **6**.
- Geometric mean FiOne/GoogiVM speed ratio: **1.19x**.
- Sum of means: GoogiVM **3.0410 s**, FiOne **7.3649 s** (**2.42x**).

## Limitations

- These are 50 project-local microbenchmarks, not a standardized suite.
- Execution only: FiOne bytecode compilation and GoogiVM compilation are excluded.
- FiOne is a Lua 5.1 bytecode interpreter; it needs an external Lua 5.1 compiler.
- LuaJIT native uses `loadstring` and JIT; it is not a pure-Lua competitor.
- Single machine; absolute seconds drift with host load, so the ratios are the stable metric.
- Averaging 3 runs smooths per-run noise but is not a statistically rigorous treatment.
