# In-game benchmark evidence (Scrap Mechanic)

These are **verbatim console transcripts** produced by
[`../benchmark11.lua`](../benchmark11.lua) inside Scrap Mechanic on a computer
block. They are user-reported in-game runs, not CI artifacts: Scrap Mechanic is
not scriptable from this repository, so the numbers cannot be regenerated here.

Environment:

- Game: Scrap Mechanic, workshop mod `3269912087` (ScrapComputers)
- Host Lua: the game's own Lua 5.1 (no JIT)
- Harness: `benchmark11.lua` pasted into `Main.lua`
- Date: 2026-10-29

To reproduce, paste `benchmarks/benchmark11.lua` into a computer's `Main.lua`
and flip `GOOGI_USE_CUSTOM_VM` in `Scripts/GoogiVMConfig.lua` between runs.
Inside the sandbox `loadstring` compiles with whichever VM is active, so the
identical script measures both engines.

---

## Run A - GoogiVM (`GOOGI_USE_CUSTOM_VM = true`)

```text
== LuaSandbox VM benchmark ==
Fibonacci: naive recursion, no memoization
fib(32) expected: 2178309
fib(30) recursive                   2.6390 s   result=832040       OK
fib(32) recursive                   6.9690 s   result=2178309      OK
1M function calls                   0.9110 s   result=1000000      OK
1M closure calls                    0.7890 s   result=1000000      OK
100k upvalue increments             0.0710 s   result=100000       OK
100k vararg calls                   0.2060 s   result=300000       OK
100k metatable adds                 0.1350 s   result=300000       OK
200k table writes + reads           0.0410 s   result=20000100000  OK
1M branch/mod iterations            0.2260 s   result=250000000000 OK
primes <= 50000                     0.2050 s   result=5133         OK
10k string concatenations           0.0250 s   result=10000        OK
--------------------------------
Total measured time: 12.2170 s
Fibonacci share: 57.0%
```

## Run B - ScrapComputers VM, first run (`GOOGI_USE_CUSTOM_VM = false`)

```text
== LuaSandbox VM benchmark ==
Fibonacci: naive recursion, no memoization
fib(32) expected: 2178309
fib(30) recursive                   5.9730 s   result=832040       OK
fib(32) recursive                  16.0980 s   result=2178309      OK
1M function calls                   2.1500 s   result=1000000      OK
1M closure calls                    2.1720 s   result=1000000      OK
100k upvalue increments             0.1800 s   result=100000       OK
100k vararg calls                   0.2950 s   result=300000       OK
100k metatable adds                 0.2050 s   result=300000       OK
200k table writes + reads           0.0430 s   result=20000100000  OK
1M branch/mod iterations            0.2540 s   result=250000000000 OK
primes <= 50000                     0.2580 s   result=5133         OK
10k string concatenations           0.0250 s   result=10000        OK
--------------------------------
Total measured time: 27.6530 s
Fibonacci share: 58.2%
```

## Run C - ScrapComputers VM, second run

```text
== LuaSandbox VM benchmark ==
Fibonacci: naive recursion, no memoization
fib(32) expected: 2178309
fib(30) recursive                   5.3080 s   result=832040       OK
fib(32) recursive                  14.7620 s   result=2178309      OK
1M function calls                   1.9440 s   result=1000000      OK
1M closure calls                    1.8290 s   result=1000000      OK
100k upvalue increments             0.1700 s   result=100000       OK
100k vararg calls                   0.2570 s   result=300000       OK
100k metatable adds                 0.1850 s   result=300000       OK
200k table writes + reads           0.0410 s   result=20000100000  OK
1M branch/mod iterations            0.2330 s   result=250000000000 OK
primes <= 50000                     0.2420 s   result=5133         OK
10k string concatenations           0.0200 s   result=10000        OK
--------------------------------
Total measured time: 24.9910 s
Fibonacci share: 59.1%
```

## Run D - SComputers (separate mod, its own FiOne fork)

```text
== LuaSandbox VM benchmark ==
Fibonacci: naive recursion, no memoization
fib(32) expected: 2178309
fib(30) recursive                   4.2030 s   result=832040
  OK
fib(32) recursive                  10.8070 s   result=2178309      OK
1M function calls                   1.4530 s   result=1000000      OK
1M closure calls                    1.5220 s   result=1000000
  OK
100k upvalue increments             0.1670 s   result=100000       OK
100k vararg calls                   0.1760 s   result=300000       OK
200k table writes + reads           0.0470 s   result=20000100000  OK
1M branch/mod iterations            0.1920 s
esult=250000000000 OK
primes <= 50000                     0.2900 s   result=5133         OK
10k string concatenations           0.0060 s   result=10000        OK
--------------------------------
Total measured time: 18.8630 s
Fibonacci share: 57.3%
```

Run D has **10 cases**: that sandbox did not report the `100k metatable adds`
line (its environment does not expose table metatables to scripts), so its
total is not comparable with the 11-case totals above. The README compares
GoogiVM against SComputers only on the 10 shared cases.

---

## Caveats

- Single machine, one world, one session. Wall-clock numbers from a game tick
  loop include engine overhead and jitter; treat differences below ~5% as noise.
- The totals are sums of medians reported by the harness, not an average of
  repeated full runs.
- These transcripts prove what the harness printed; they are not a
  statistically controlled experiment.
