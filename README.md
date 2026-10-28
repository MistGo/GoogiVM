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
local chunk, err = custom_loadstring(source, env)
```

| Argument | Type | Meaning |
|---|---|---|
| `source` | string | Lua 5.1 source code |
| `env` | table or `nil` | Global environment; `nil` means a new empty table |

Returns:

- a callable Lua function on success;
- `nil, error_string` for an invalid argument or a syntax error.

Syntax errors include a line and a nearby token. Runtime errors propagate out of the chunk, so catch them with `pcall` if needed:

```lua
local ok, result = pcall(chunk)
if not ok then
    print("runtime error:", result)
end
```

The returned chunk can be called many times. Locals are fresh on every call; the environment table is shared.

## Supported language

The compiler targets Lua 5.1:

- `if`, `while`, `repeat`, numeric and generic `for`;
- functions, closures, upvalues, varargs;
- tables, methods, multiple assignment, multiple returns;
- all Lua 5.1 operators;
- metatables through the host;
- `getfenv`/`setfenv` when the host provides them.

Lua 5.2+ syntax such as `goto`, `//`, `_ENV`, and variable attributes is not supported. There are no bitwise operators in Lua 5.1; expose a library such as `bit` through `env` if needed.

## Safety

This is a sandbox-first interpreter, **not a hardened security boundary**.

- There is no CPU limit, timeout, or instruction budget.
- There is no memory limit.
- There is no stack-depth protection; there is no tail-call optimization.
- Any host function you put in `env` can do whatever that function can do.
- Do not expose `os`, `io`, `debug`, `package`, `loadstring`, or FFI to untrusted code.
- Do not expose `getfenv`/`setfenv` unless the script really needs them.

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

- LuaJIT: **18,644 checks**, 0 failed;
- Lua 5.4: **18,630 checks**, 0 failed (some `setfenv`/`getfenv`/`__len` checks are skipped).

The `tests/` directory is only for development; it is not needed to use the library. Detailed test coverage is in [`tests/README.md`](tests/README.md).

## Performance

On the project microbenchmarks, this interpreter was about **1.6x faster than FiOne** overall after the peephole/superinstruction work. It is still much slower than native LuaJIT, which is a different execution model. These are microbenchmarks, not a representative game workload.

## Files

```text
custom_loadstring_full.lua   # the library
README.md                    # this file
README.ru.md                 # Russian version
LICENSE                      # MIT
run_all_tests.lua            # test runner
tests/                       # test suite
AGENTS.md                    # notes for AI coding agents
.gitignore
.gitattributes
```

## License

MIT. See [`LICENSE`](LICENSE).

## For AI agents

If you are an AI coding agent, read [`AGENTS.md`](AGENTS.md) before changing the interpreter.
