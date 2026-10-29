# LuaSandbox VM

**A pure-Lua Lua 5.1 compiler and bytecode interpreter for hosts where `loadstring` is unavailable.**

[English](README.md) | [Русский](README.ru.md)

![Lua](https://img.shields.io/badge/Lua-5.1%20%7C%20LuaJIT-2C2D72)
![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)

`custom_loadstring_full.lua` turns a Lua 5.1 source string into a callable function. It is one file, has no dependencies, and does not use `load`, `loadstring`, FFI, `debug`, `io`, or `os`.

It is intended for game mods, embedded runtimes, and small server-side sandboxes that need to run Lua source without access to the host loader.

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

On the project microbenchmarks, this interpreter is roughly **2-3x faster than FiOne** on call-heavy, numeric-loop, and Fibonacci workloads. Table access is roughly **1.6x faster**; branch-heavy loops are slower under LuaJIT because the comparison workaround keeps them out of the JIT. It is still much slower than native LuaJIT, which is a different execution model. These are microbenchmarks, not a representative game workload.

Tail calls reuse the current VM frame, so `return f(...)` does not grow the call-depth budget or the frame stack.

**LuaJIT 2.1 note:** the base comparison path runs through a small non-JIT helper, and fused comparison opcodes are disabled when a `jit` table is present. This avoids an intermittent LuaJIT miscompile observed under long differential-fuzz runs. Arithmetic and loop execution remain JIT-compiled.

## Files

```text
custom_loadstring_full.lua   # the library
README.md                    # this file
README.ru.md                 # Russian version
TECHNICAL.md                 # short implementation guide
TECHNICAL.ru.md              # Russian implementation guide
LICENSE                      # MIT
run_all_tests.lua            # test runner
tests/                       # test suite
AGENTS.md                    # notes for AI coding agents
.gitignore
.gitattributes
```

For how the compiler, bytecode, and VM work, see [`TECHNICAL.md`](TECHNICAL.md) or [`TECHNICAL.ru.md`](TECHNICAL.ru.md).

## License

MIT. See [`LICENSE`](LICENSE).

## For AI agents

If you are an AI coding agent, read [`AGENTS.md`](AGENTS.md) before changing the interpreter.
