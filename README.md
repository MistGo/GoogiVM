# GoogiVM

**A fast, pure-Lua Lua 5.1 compiler and bytecode interpreter for hosts where `loadstring` is unavailable.**

![Lua](https://img.shields.io/badge/Lua-5.1%20%7C%20LuaJIT-2C2D72)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

`custom_loadstring_full.lua` compiles a Lua 5.1 source string into a callable Lua function. It is a single self-contained file with zero external dependencies and does not use `load`, `loadstring`, FFI, `debug`, `io`, or `os`.

It is built for game mods (such as Scrap Mechanic), embedded runtimes, and sandboxed environments that need to execute Lua source code without access to the host loader.

> **Only one file is needed to use the library:** `custom_loadstring_full.lua`. The `tests/` folder is for development and can be ignored by users.

## Quick start

Copy `custom_loadstring_full.lua` into your project and load it:

```lua
local custom_loadstring = dofile("custom_loadstring_full.lua")

local env = {
    math = math,
    string = string,
    table = table,
}

local chunk, err = custom_loadstring([[
    local t = {}
    for i = 1, 5 do
        t[i] = i * i
    end
    return table.concat(t, ",")
]], env)

if not chunk then
    error("compile error: " .. tostring(err))
end

print(chunk()) --> 1,4,9,16,25
```

The environment is explicit. If you omit it, the chunk gets a fresh empty table, **not** `_G`. Add only the globals the script is allowed to use.

## API

```lua
local chunk, err = custom_loadstring(source, env, options)
```

| Argument | Type | Meaning |
|---|---|---|
| `source` | string | Lua 5.1 source code |
| `env` | table or `nil` | Global environment; `nil` means a new empty table |
| `options` | table or `nil` | Optional execution/compile limits |

Returns:

- a callable Lua function on success;
- `nil, error_string` for an invalid argument or a syntax error.

Syntax errors include a line and a nearby token. Runtime errors are mapped to the interpreted source location and include a short call trace (`sourceName:line: message`), so catch them with `pcall` if needed:

```lua
local ok, result = pcall(chunk)
if not ok then
    print("runtime error:", result)
end
```

### Options and limits

The third argument is optional and backward compatible. It accepts positive numeric limits and an optional source name:

| Option | Default | Meaning |
|---|---:|---|
| `sourceName` | `"<string>"` | Name used in runtime errors and tracebacks |
| `maxSourceBytes` | 4 MiB | Maximum source size in bytes |
| `maxCodeSlots` | 8,000,000 | Maximum bytecode slots per prototype |
| `maxInstructions` | 50,000,000 | VM instructions per chunk invocation |
| `maxCallDepth` | 10,000 | Maximum interpreted call depth |
| `maxStack` | 1,000,000 | Maximum VM value-stack index |
| `maxArgs` | 1,000 | Maximum arguments per call |
| `maxReturns` | 1,000 | Maximum return values per return |

```lua
local chunk, err = custom_loadstring(source, env, {
    sourceName = "user_script",
    maxInstructions = 5e6,
    maxCallDepth = 500,
    maxSourceBytes = 512 * 1024,
})
```

Limits are enabled by default. Set a numeric limit to `math.huge` to disable that individual limit. Unknown option keys are ignored. Invalid, zero, negative, or NaN limit values make compilation fail; `sourceName` must be a string.

The returned chunk can be called many times. Locals are fresh on every call; the environment table is shared.

## Supported language

The compiler targets Lua 5.1:

- `if`, `while`, `repeat`, numeric and generic `for`;
- functions, closures, upvalues, varargs;
- tail calls (`return f(...)`) with frame reuse;
- tables, methods, multiple assignment, multiple returns;
- all Lua 5.1 operators;
- metatables through the host;
- `getfenv`/`setfenv` when the host provides them.

Lua 5.2+ syntax such as `goto`, `//`, `_ENV`, and variable attributes is not supported. There are no bitwise operators in Lua 5.1; expose a library such as `bit` through `env` if needed.

## Safety

This is a sandbox-first interpreter, **not a hardened security boundary**.

- The default instruction, call-depth, stack, argument, and return-value limits can be overridden through the options table.
- There is no wall-clock timeout. For hostile code, use a separate process/worker with an external timeout.
- There is no memory limit inside Lua.
- Non-tail recursion is bounded by `maxCallDepth`; tail calls reuse the current frame and do not grow the call stack.
- Any host function you put in `env` can do whatever that function can do.
- Do not expose `os`, `io`, `debug`, `package`, `loadstring`, or FFI to untrusted code.
- `getfenv`/`setfenv` are special-cased for interpreted closures. Accessing native function environments is rejected.

For untrusted scripts, also use a separate process/worker, timeouts, and memory limits outside Lua.

## Tests

Run from the repository root:

```bash
luajit run_all_tests.lua
```

or:

```bash
lua run_all_tests.lua
```

Expected results:

- LuaJIT: **18,681 checks**, 0 failed;
- Lua 5.4: **18,663 checks**, 0 failed (some `setfenv`/`getfenv`/`__len` checks are skipped).

The `tests/` directory is only for development; it is not needed to use the library. Detailed test coverage is in [`tests/README.md`](tests/README.md).

## Performance

On focused benchmarks and in-game Scrap Mechanic tests, **GoogiVM** is roughly **2.05–2.26x faster overall than standard FiOne** (and **1.56x faster than SComputers' FiOne fork**), winning across recursion, function/closure calls, upvalues, `ipairs`/`pairs`, table constructors, prime sieves, and metamethods. It is still slower than native LuaJIT, which is a different execution model.

A broader **50-case head-to-head** against FiOne (actual FiOne execution) gives **32 wins, 14 losses, and 4 near-ties**, with a geometric-mean speed ratio of **1.30x** and a **2.69x** total speedup across all 50 medians (**1.96 s vs 5.28 s**). Full data: [`BENCHMARK_50.md`](BENCHMARK_50.md).

Tail calls reuse the current VM frame, so `return f(...)` does not grow the call-depth budget or the frame stack.

**LuaJIT 2.1 note:** the base comparison path runs through a small non-JIT helper, and fused ordering-comparison opcodes route through that helper when a `jit` table is present. Equality and inequality fusions remain JIT-compiled. This avoids an intermittent LuaJIT miscompile observed under long differential-fuzz runs while keeping common conditions fast. Arithmetic and loop execution remain JIT-compiled.

## Files

```text
custom_loadstring_full.lua   # GoogiVM single-file compiler + VM
README.md                    # documentation
TECHNICAL.md                 # implementation guide
BENCHMARK_50.md              # 50-case benchmark report vs FiOne
BENCHMARK_50.csv             # raw benchmark timings
LICENSE                      # MIT
run_all_tests.lua            # test runner
tests/                       # test suite
AGENTS.md                    # notes for AI coding agents
.gitignore
.gitattributes
```

For how the compiler, bytecode, and VM work, see [`TECHNICAL.md`](TECHNICAL.md).

## License

MIT. See [`LICENSE`](LICENSE).

## For AI agents

If you are an AI coding agent, read [`AGENTS.md`](AGENTS.md) before changing the interpreter.
