# Test Suite (`tests/`)

This directory contains the automated verification suite for **GoogiVM** (`custom_loadstring_full.lua`).

## Running the Tests

From the repository root:

```bash
luajit run_all_tests.lua
lua run_all_tests.lua
```

- **LuaJIT 2.1 (primary target):** `18,681 checks, 0 failed`
- **Lua 5.4 (compatibility target):** `18,663 checks, 0 failed` (18 checks that depend on Lua 5.1 `getfenv`/`setfenv` or LuaJIT `__len` table semantics are skipped automatically when those features are absent).

---

## Test Modules (17 Suites)

| Module | Checks (LuaJIT) | Coverage |
|---|---:|---|
| `test_lexer.lua` | 77 | Decimal/hex/scientific numbers, malformed numbers (`1..2`, `0x1..2`), short/long strings, escapes, comments, operators, line tracking |
| `test_syntax.lua` | 154 | Valid and invalid Lua 5.1 grammar, rejection of Lua 5.2+ features (`goto`, `::label::`, `//`) |
| `test_expressions.lua` | 83 | Arithmetic, relational, logical short-circuit (`and`/`or`), concatenation, unary ops, precedence |
| `test_statements.lua` | 53 | Locals, globals, multiple assignment, `if`/`elseif`/`else`, `while`, `repeat`/`until`, numeric & generic `for`, `break`, `do`, `return` |
| `test_functions.lua` | 30 | Parameters, recursion, closures, mutable shared upvalues, method definitions & calls (`:`) |
| `test_tables.lua` | 41 | List, hash, and mixed table constructors, nested tables, multi-return tail expansion (`{1, f()}`) |
| `test_varargs_multiret.lua` | 47 | `...`, `select`, multi-return adjustment, `(f())` truncation, varargs in calls/returns/tables |
| `test_metatables.lua` | 23 | `__index`, `__newindex`, `__add`..`__pow`, `__unm`, `__concat`, `__eq`, `__lt`, `__le`, `__call`, `__len`, `__tostring` |
| `test_environment.lua` | 28 | Sandbox isolation, empty default `env`, `env` metatables, `getfenv`/`setfenv` across stack levels and closures |
| `test_errors.lua` | 37 | API argument validation, syntax errors with line numbers, runtime error propagation through `pcall`/`xpcall` |
| `test_host_interop.lua` | 17 | Interop with host `pcall`, `table.sort`, `string.gsub`, `coroutine.create`/`resume`/`wrap`, and C callbacks |
| `test_regressions.lua` | 18 | Edge cases: `false` iterator keys, per-iteration captured loop cells, upvalue backpatching, evaluation order, 100 upvalues |
| `test_superinstructions.lua` | 24 | Peephole fusions: arithmetic/compound assignments, table reads/writes, `while`/`for` branches, `ipairs` cells, metamethod preservation |
| `test_fuzz.lua` | 18,000 | Differential fuzzing against native `loadstring`/`load`: 15,000 random expressions + 3,000 random multi-statement programs |
| `test_stress.lua` | 14 | 5,000-deep recursion, 150 locals, 1,000-element table constructors, 120 parameters, 100 return values, 100 KB strings |
| `test_limits.lua` | 18 | `maxSourceBytes`, `maxCodeSlots`, `maxInstructions`, `maxCallDepth`, `maxStack`, `maxArgs`, `maxReturns`, native `getfenv`/`setfenv` rejection, source-line tracebacks |
| `test_tailcalls.lua` | 17 | Frame-reusing tail calls (`return f(...)`), 100,000-step self & mutual tail recursion under `maxCallDepth = 10`, vararg/method/native tail calls |
| **Total** | **18,681** | **All modules pass with 0 failures** |
