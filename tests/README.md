# Test Suite (`tests/`)

This directory contains the automated test suite for **GoogiVM** (`custom_loadstring_full.lua`).

Run the entire suite from the repository root:

```bash
luajit run_all_tests.lua
```

or with standard Lua:

```bash
lua run_all_tests.lua
```

## Structure

- `helpers.lua` — shared test harness (`expect`, `expect1`, `compile_error`, `runtime_error`, `compare` against the host `loadstring`/`load`).
- `test_lexer.lua` — numbers (decimal, hex, scientific), strings, escape sequences, long strings, comments, operators, line numbers.
- `test_syntax.lua` — valid and invalid Lua 5.1 syntax, rejection of Lua 5.2+ constructs (`goto`, `//`, labels).
- `test_expressions.lua` — arithmetic, relational, logical (`and`/`or` short-circuit), concatenation, precedence, associativity.
- `test_statements.lua` — `local`, globals, multiple assignment, `if`/`elseif`/`else`, `while`, `repeat`/`until`, numeric `for`, generic `for`, `break`, `do`/`end`, `return`.
- `test_functions.lua` — parameters, recursion, closures, shared upvalues, mutation of outer locals, nested functions, methods (`:`).
- `test_tables.lua` — array/hash/mixed table constructors, nested tables, trailing multireturn expansion.
- `test_varargs_multiret.lua` — `...`, `select`, multiple return adjustment, truncation with `(...)`, calls in argument lists, returns, and table constructors.
- `test_metatables.lua` — `__index`, `__newindex`, arithmetic metamethods, `__eq`, `__lt`, `__le`, `__concat`, `__unm`, `__call`, `__len` (where supported by the host).
- `test_environment.lua` — environment isolation, `__index`/`__newindex` on `env`, `getfenv`/`setfenv` on levels and functions.
- `test_errors.lua` — API validation, syntax error reporting, runtime error propagation, `pcall`/`xpcall`.
- `test_host_interop.lua` — passing interpreted closures to `pcall`, `xpcall`, `table.sort`, `string.gsub`, `coroutine.*`, and C/host callbacks.
- `test_regressions.lua` — tricky Lua 5.1 edge cases (`false` keys in generic `for`, per-iteration closure cells, upvalue backpatching, evaluation order, >60 upvalues).
- `test_superinstructions.lua` — regression coverage for peephole fusions, loop-body fusions, conditional jumps, and side-effect ordering.
- `test_fuzz.lua` — 18,000 differential tests (15,000 generated expressions + 3,000 generated programs) compared against the host Lua compiler.
- `test_stress.lua` — deep recursion (5,000 frames), 150 locals, 1,000-element table constructors, 100-argument functions, 100-value returns, long strings.
- `test_limits.lua` — compile/runtime resource limits (`maxSourceBytes`, `maxCodeSlots`, `maxInstructions`, `maxCallDepth`, `maxStack`, `maxArgs`, `maxReturns`), native `getfenv`/`setfenv` protection, and source-line tracebacks.
- `test_tailcalls.lua` — frame-reusing tail calls (`return f(...)`), mutual tail recursion, vararg/method tail calls, and native tail calls.

## Expected Check Counts

- **LuaJIT 2.1:** `18,681 checks, 0 failed`
- **Lua 5.4:** `18,663 checks, 0 failed` (checks requiring `getfenv`/`setfenv` or Lua 5.1-specific `__len` behavior are skipped automatically).
