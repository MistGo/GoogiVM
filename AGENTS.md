# AGENTS.md

Short operating guide for AI coding agents working on **LuaSandbox VM**.

## What this project is

A single-file Lua 5.1 compiler and bytecode interpreter written in pure Lua. It exists for hosts where `load`, `loadstring`, FFI, `debug`, `io`, and `os` are unavailable.

Public API:

```lua
local custom_loadstring = dofile("custom_loadstring_full.lua")
local chunk, err = custom_loadstring(source, env, options)
```

- `source` must be a string.
- `env` is optional; `nil` means a fresh empty table, **not** `_G`.
- `options` is optional and may contain execution/compile limits.
- Success returns a callable function.
- Compile failure returns `nil, error_string`.
- Runtime errors propagate out of the chunk.

## Hard constraints

- Keep the public API compatible.
- Keep the implementation pure Lua.
- Do not use `load`, `loadstring`, FFI, `debug`, `io`, or `os` in the interpreter.
- Do not add runtime dependencies.
- Keep the default environment empty.
- Keep the Lua 5.1 target grammar: no `goto`, `//`, `_ENV`, or 5.2+ attributes.
- Do not claim this interpreter is faster than native LuaJIT.
- Do not weaken existing tests to make a change pass.

The test harness may use `loadstring`/`load`, `os.clock`, `print`, and `dofile`. That is test infrastructure, not the library.

## Files

| Path | Role |
|---|---|
| `custom_loadstring_full.lua` | Compiler + VM |
| `run_all_tests.lua` | Test runner |
| `tests/helpers.lua` | Shared test harness |
| `tests/test_*.lua` | Test modules; `test_limits.lua` covers budgets and native-fenv rejection |
| `README.md`, `README.ru.md` | User docs |
| `TECHNICAL.md`, `TECHNICAL.ru.md` | Short implementation guide |
| `LICENSE` | MIT |

## Commands

From the repository root:

```bash
luajit run_all_tests.lua
lua run_all_tests.lua
```

LuaJIT is the primary target. Lua 5.4 is a compatibility smoke run; some `setfenv`/`getfenv`/`__len` checks are skipped.

Expected baseline:

- LuaJIT: 18,658 checks, 0 failed.
- Lua 5.4: 18,640 checks, 0 failed.

If `luajit` is unavailable in the environment, run the Lua suite and report that the primary host was not tested.

For a longer explanation, read `TECHNICAL.md`.

## Architecture in one minute

```text
source
  -> integrated lexer/parser (no AST)
  -> per-function bytecode prototype
  -> linear peephole optimizer
  -> native Lua closure + VM
```

Important details:

- Instructions are stored as four numbers: `{OPCODE, A, B, C}`.
- Normal opcodes are 1–51; fused opcodes are 52–111.
- Fused instructions skip dead slots; the program counter can advance by 8, 12, 16, or 24 numbers.
- The optimizer does not shift code. It overwrites the first slot and marks the rest dead.
- Captured locals become heap cells (`GETCELL`/`SETCELL`); loop variables can get a fresh cell per iteration.
- Calls use `CALLD`; custom-to-custom calls push explicit VM frames instead of recursing through the host.
- Multi-return uses `MARK`, `POP`, `PEEK`, `VARARG`, and `SETLISTMULTI`.

## Invariants

Do not fuse across a jump target. `optimize_code` records targets for `JMP`, `JMPF`, `TESTF`, `TESTT`, `JMPNIL`, `FORPREP`, and `FORLOOP`; `can()` must guard every candidate.

The fused skip length must match `put()`:

- `MOVLOCAL` → 2 slots → `pc + 8`;
- `ADD_RR` → 3 slots → `pc + 12`;
- compound assignment → 4 slots → `pc + 16`;
- indexed writes/compound assignment → 6 slots → `pc + 24`.

Preserve register-collision checks. Do not treat captured locals as plain registers. Do not change `CALLD` result semantics without checking assignment, return, call arguments, table tails, and generic-for paths.

## Workflow

1. Reproduce the issue with a minimal script.
2. Add or update a focused test.
3. Change the smallest relevant section:
   - parser/lexer: `advance`, `parse_*`, `compile_*`;
   - emitter: `emit`, `new_fc`, `compile_funcbody`;
   - optimizer: `optimize_code`;
   - VM: `run_closure`;
   - API: `custom_loadstring`.
4. Run both test commands.
5. Update both language READMEs for user-facing changes.
6. Do not change the license without the maintainer's decision.

## Definition of done

- [ ] API compatible.
- [ ] Regression test added or updated.
- [ ] `luajit run_all_tests.lua` passes.
- [ ] `lua run_all_tests.lua` passes on Lua 5.4.
- [ ] No new dependencies or forbidden host calls.
- [ ] Peephole jump targets, dead slots, and skip lengths are correct.
- [ ] Both READMEs updated if behavior changed.

## License

MIT. See `LICENSE`. Do not relicense the project.
