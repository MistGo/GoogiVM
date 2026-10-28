# Technical overview

This is a short implementation guide for LuaSandbox VM. For usage, see [`README.md`](README.md).

The whole runtime is in one file: `custom_loadstring_full.lua`. It contains the lexer, parser, bytecode emitter, peephole optimizer, and virtual machine.

## Pipeline

```text
Lua source
  -> integrated lexer + recursive-descent parser
  -> per-function bytecode prototypes
  -> linear peephole optimizer
  -> native Lua closure + weak metadata
  -> stack VM with explicit call frames
```

There is no AST. The parser emits bytecode while it parses.

## Compiler

The lexer keeps only the current token (`tk`), its value (`tv`), its source position (`tp`), and the scanner position (`pos`). It does not build a token array.

Each function is compiled into a frame context (`fc`) containing:

- `code` — flat bytecode array;
- `consts` — 1-based constant table;
- `locals` — active local descriptors;
- `upvals` — captured upvalue descriptors;
- `nextreg` / `maxreg` — local register allocation;
- `loop_breaks` — pending `break` jumps.

A base instruction is four numbers:

```text
[OPCODE, A, B, C]
```

A local variable occupies a frame-relative register. If a nested function captures it, the compiler:

1. replaces its `NOP` placeholder with `CELL`;
2. rewrites `GETLOCAL`/`SETLOCAL` accesses to `GETCELL`/`SETCELL`;
3. shares the resulting `{ v = value }` cell with the nested closure.

Function prototypes are stored in a shared prototype list. The root chunk is itself a vararg prototype with no fixed parameters.

## Bytecode

Normal opcodes are numbered **1–51**. Fused opcodes produced by the optimizer are numbered **52–111** and grouped by purpose:

| Range | Purpose |
|---:|---|
| 52–57 | local moves and simple stores |
| 58–69 | arithmetic with register/constant operands |
| 70–87 | comparisons |
| 88–94 | table/index reads and writes |
| 95–101 | compound assignment patterns |
| 102–109 | conditional jumps |
| 110–111 | numeric-for loop-variable copies |

The bytecode is private. It is not serialized, has no stable ABI, and should not be persisted between versions.

## Peephole optimizer

`optimize_code` runs after a function has been fully compiled. It first records jump targets, then fuses common instruction sequences.

Key rule: **the optimizer does not shift code**. It writes the fused instruction into the first slot and marks the following slots dead. The VM skips those dead slots:

- 2 slots → `pc + 8`;
- 3 slots → `pc + 12`;
- 4 slots → `pc + 16`;
- 6 slots → `pc + 24`.

A fusion is never allowed to cross a jump target. `can()` checks the target and dead-slot maps before a pattern is applied.

The optimizer also folds a numeric-for loop-variable copy into `FORLOOP_MOV` or `FORLOOP_CELL`. The first iteration still uses the body copy; later iterations are handled by the loop opcode.

## VM

A top-level invocation creates:

- `S` — shared value stack;
- `top` — current stack top;
- `frames` — explicit call frames;
- `base` — current frame base;
- `pc` — program counter;
- `C`, `K`, `U` — current code, constants, upvalues;
- `e` — current environment.

The VM loop uses local aliases for these values because table lookups in the dispatch loop would dominate performance.

### Calls

All calls use `CALLD`:

- a marker register stores the function's stack position;
- arguments are above the function value;
- the result count is `-1` (all), `0` (none), or an exact number.

For a custom closure, the VM pushes a new explicit frame, shifts arguments into parameter slots, clears the callee's local registers, and continues the same dispatch loop. Custom-to-custom calls do not recurse through the host once per call.

Native functions use fast paths for 0/1/2 arguments and `unpack` for larger argument lists.

### Closures and multiple returns

A closure is a real Lua function whose prototype/upvalue/environment metadata lives in the weak-key `closure_info` table. Upvalues point to cells when a value is shared.

Multiple returns use `MARK`, `POP`, `PEEK`, `VARARG`, and `SETLISTMULTI`. The compiler tracks `top_multi` / `last_multi_pc` and patches the requested result count when the surrounding expression list is known.

### Tables and metatables

Table reads and writes use the host's normal `t[k]` operations. Arithmetic, comparison, concatenation, length, and `__call` therefore use host metamethod semantics; the VM does not implement a second metamethod engine.

### Environment

Global reads and writes use the supplied `env` table directly, so `__index` and `__newindex` work. The default is an empty table, never `_G`.

`getfenv`/`setfenv` are special-cased in `CALLD` when the host provides them. `setfenv(0, ...)` is intentionally rejected.

### Errors

Syntax errors are caught by `pcall(compile)` and returned as `nil, message`. Runtime errors are not caught: they propagate out of the chunk and preserve the original error object. Runtime errors do not have a script-level line map.

## Source map

Useful places in `custom_loadstring_full.lua`:

| Area | Functions |
|---|---|
| Lexer | `advance`, `skip_space`, string/number scanners |
| Parser | `parse_stmt`, `parse_block`, `compile_expr` |
| Emitter | `emit`, `new_fc`, `compile_funcbody` |
| Optimizer | `optimize_code`, `try_stmt`, `try_expr` |
| VM | `run_closure` |
| API | `custom_loadstring` |

## Changing the implementation

Before adding a fused opcode:

1. choose an unused number and add it to `FOP`;
2. add a dispatch branch in `run_closure`;
3. add a pattern in `optimize_code`;
4. make the `pc` skip match `put()`;
5. add a test in `tests/test_superinstructions.lua`;
6. run both test commands from the README.

Never fuse across a jump target and never skip a live instruction.

## Known limits

- No tail-call optimization.
- No runtime source-line mapping.
- No instruction, time, or memory budget.
- No bytecode serialization.
- No Lua 5.2+ grammar.
- Deep recursion is limited by the host stack.
- Behavior of `#` on sparse tables and some metamethod edge cases is host-defined.
