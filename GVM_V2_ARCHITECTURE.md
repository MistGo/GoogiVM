# GoogiVM v2 — block-threaded closure VM

Status: branch `gvm-closure-v2`; phase 0 (module boundary), phase 1
(straight-line chain) and phase 2 (base branches/loops/budget) are implemented
and tested. `main` remains the stable single-file VM.

## Why a new backend

The current VM is a fused register interpreter with a balanced range-tree
dispatch. It is fast with LuaJIT disabled because one loop iteration can
execute a complete superinstruction. A closure-threaded VM removes the central
dispatch but pays a Lua call per operation, so the default must not be
per-instruction closures.

The v2 backend is therefore **block-threaded**:

- basic blocks and fused superinstructions become Lua closures;
- a trampoline runs the chain;
- operand kinds are specialized at compile time (`K` constant, `R` register);
- complex or not-yet-supported blocks fall back to the current interpreter.

This keeps the fast path (JIT off) close to the existing VM while creating a
structure the host JIT can inline.

## Files

| File | Responsibility |
|---|---|
| `gvm_compiler.lua` | lexer, parser, emitter, peephole optimizer, prototype builder |
| `gvm_runtime.lua` | prototypes, closures, frames, cells, calls, operators, limits, tracebacks, v2 backend |
| `custom_loadstring_full.lua` | public API, option validation, module loading |

The public API is unchanged:

```lua
local custom_loadstring = dofile("custom_loadstring_full.lua")
local chunk, err = custom_loadstring(source, env, options)
```

`dofile` is used only to load the two modules at startup. The interpreter still
does not use `load`, `loadstring`, FFI, `debug`, `io`, or `os`.

## Execution model

```
compile source
  -> prototypes with code/lines/consts/updesc
  -> optimize_code (existing fusions)
  -> block plan (pc, slot lengths, successors)
  -> lazy block closures
  -> trampoline: while op do op = op(state) end
```

A block closure receives the VM state and returns the next closure (or `nil` to
stop). It must not recurse through the host stack for guest calls; those use
explicit frames and return a continuation.

### Block contents

A block ends at a jump target, branch, call, return, loop back-edge, or a hard
instruction. The builder records the exact slot length of every instruction so
fused instructions can be chained without decoding the whole stream at run time.

### Operand specialization

Handlers are selected by shape, not by a runtime type check:

- `ADD_KK`, `ADD_RK`, `ADD_RR`;
- `INDEX_RK`, `INDEX_RR`;
- `CALL_RR1`, `CALL_RR2`;
- compound assignment and loop variants.

The first implementation may reuse the existing fused opcode numbers; the
important part is that the shape is fixed when the closure is built.

### Frames and calls

- `state.S`, `state.top`, `state.frames`, `state.fi` mirror the current VM.
- A guest call pushes a frame and returns the callee's entry closure.
- A return pops the frame and resumes the caller's continuation.
- Tail calls reuse the current frame.
- Varargs, multiple returns, `pcall`/`xpcall`, `getfenv`/`setfenv`, metamethods,
  cells and limits must behave exactly as in the current VM.

### Fallback

`proto.backend` selects `legacy` or `closure`. Until a block is supported,
the prototype stays on `legacy`. There is no mixed execution inside one
prototype in the first phase; that keeps error line mapping and limits simple.

## Correctness invariants

1. Do not fuse across a jump target; the existing optimizer rule still applies.
2. The block builder must use the same slot lengths as `put()`: 2, 3, 4, 5, 6,
   8, 9, 10, 12, 14, 18, 24 slots.
3. Register collisions and captured-local checks must not be weakened.
4. `CALLD` result counts, table tails, generic-for paths and tail-call flags
   must keep their current meaning.
5. A closure backend error must still produce `sourceName:line` and a Lua-style
   traceback.
6. The default environment remains empty.
7. Every new path needs a regression test; do not remove existing checks.

## Phases

### Phase 0 — module boundary (done)

- Split the stable VM into compiler/runtime modules.
- Public entry loads modules through relative and `$CONTENT_DATA` paths.
- Full suite: 18,737 LuaJIT / 18,713 Lua 5.4 checks.

### Phase 1 - block plan and chain prototype (done)

- Record slot lengths during emission/optimization.
- Build a block plan for a prototype.
- Implemented `slotlen`, `scan_block`, `build_block_chain`, `build_program`
  and `run_block_chain`.
- Opt-in through `backend = "closure"`; default remains `legacy`.
- Focused tests compare chain results with the legacy interpreter.

### Phase 2 - branches and loops (base opcodes done)

- Implemented `JMP`, `JMPF`, `TESTF`, `TESTT`, `JMPNIL`, `FORPREP`, `FORLOOP`.
- Continuations are returned instead of recursing through the host stack.
- `maxInstructions` is enforced at every chain step.
- Tests cover `if`, `while`, `repeat`, numeric `for`, `break` and negative steps.
- Closure mode currently disables peephole fusions so the builder sees base
  opcodes; fused control-flow specialization is a later optimization.
- Generic `for` needs calls/iterators and moves to phase 3.

Measured with `benchmarks/bench_closure_backend.lua` under `luajit -joff`
after the block-closure change: a straight-line leaf call is about **1.8x**
faster than legacy, and the recognized numeric-`for` sum (`acc = acc + i`) is
about **1.9x** faster. The sum case uses a loop superinstruction closure; other
loop bodies still pay per-block/per-op dispatch and may be slower. More loop
shapes need their own superinstructions before the closure backend can be a
general default.

### Phase 3 - calls, closures and cells (partial)

- Implemented `CALLD` for native and interpreted targets, tail-call returns,
  result adjustment, `CLOSURE`, `GETUPVAL`/`SETUPVAL`, `CELL`/`GETCELL`/
  `SETCELL`, `MARK`/`POP`/`PEEK` and `SETLISTMULTI`.
- Calls now suspend explicit VM frames; tail calls reuse the current frame.
- `VARARG`, open returns and vararg table tails are implemented.
- Globals and generic `for` work through `CALLD`/`MARK`/`JMPNIL`.
- `maxInstructions`, `maxArgs`, `maxReturns`, `maxStack` and `maxCallDepth`
  are enforced.
- A basic source-located traceback is attached to chain runtime errors.
- Fresh-per-iteration loop cells with captured variables work.
- Guest `pcall`/`xpcall` work; broader traceback/sandbox edge cases are still
  being filled in.

### Phase 4 - tables, operators and metamethods (partial)

- Implemented `NEWTABLE`, `FIELD`/`INDEX`/`SETFIELD`/`SETINDEX`, `SELF`,
  `SETLIST` and `SETLISTMULTI`.
- Host metamethod behavior is preserved through normal Lua table operations.
- Broader metamethod and constructor tests are still pending.

### Current 16-task baseline (local)

`benchmarks/bench_backend_compare.lua` runs `benchmarks/benchreal.lua` through
both backends.

| Host mode | Legacy | Closure | Closure / legacy |
|---|---:|---:|---:|
| `luajit -joff` | 3.86 s | 14.77 s | **0.26x** |
| `luajit` | 1.42 s | 7.19 s | **0.20x** |

All 16 tasks returned the correct result under both backends. The closure
backend is therefore **semantically validated** on the real suite, but it is
still much slower overall: general loop bodies pay per-block dispatch and the
mode disables peephole fusions. The `acc = acc + i` loop superinstruction only
covers one shape. Do not switch the default until more loop shapes are
specialized and the total improves.

### Phase 5 - selection and benchmarks

- Compare `legacy` and `closure` on the 16-task real suite and 50-case suite.
- Select the backend per prototype only when it wins and is correct.
- Keep a runtime switch for diagnosis.
- Do not claim a speedup before measuring both hosts, with JIT on and off.

## Non-goals

- Native code generation inside pure Lua (requires FFI/executable memory).
- Using host `loadstring` to generate optimized closures (violates constraints).
- Copying FiOne/Fin code; their designs are reference material only.
