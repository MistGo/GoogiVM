# GoogiVM Technical Guide

This document explains how **GoogiVM** compiles and executes Lua 5.1 source code. For public API usage and benchmarks, see [`README.md`](README.md).

The implementation is split across three runtime files:

- `custom_loadstring_full.lua` — public API and module loader;
- `gvm_compiler.lua` — lexer, parser, emitter and optimizer;
- `gvm_runtime.lua` — prototypes, frames, closures, legacy VM and the experimental closure slice.

---

## 1. Execution Pipeline

```text
Lua 5.1 Source String
  -> 1. Streaming Lexer (`advance`, `read_number`, `read_string`)
  -> 2. Single-Pass Recursive-Descent Compiler (`parse_stmt`, `compile_expr`)
  -> 3. Per-Function Bytecode Prototype (`code`, `consts`, `updesc`, `lines`, `slotlen`)
  -> 4. Peephole Superinstruction Optimizer (`optimize_code`)
  -> 5. Explicit-Frame Stack/Register Virtual Machine (`run_closure`)
  -> 6. Opt-in block-threaded closure slice (`build_block_chain`)
```

There is no intermediate AST. Bytecode is emitted directly during parsing.

---

## 2. Lexer & Source Line Mapping

- The scanner maintains only the current token (`tk`), its semantic value (`tv`), its byte offset (`tp`), the previous token's byte offset (`last_tp`), and the cursor (`pos`).
- Before scanning, `compile()` builds an array of newline offsets (`line_starts`).
- Whenever `emit()` writes an instruction, it records `line_of(last_tp)` (via binary search over `line_starts`) into `fc.lines[pc]`.
- Number scanning validates adjacent dots (`1..2`, `0x1..2`) as syntax errors while allowing string concatenation (`1 .. 2`).

---

## 3. Compiler & Function Prototypes

Each function (including the top-level chunk, which is compiled as an implicit `...` vararg function) has a compilation context `fc`:

- `code` — flat 1-based numeric array; every base instruction occupies 4 numbers: `[OPCODE, A, B, C]`.
- `slotlen` — exact span of each live instruction in 4-number units. `emit` writes 1; fused `put` writes 2, 3, 4, 5, 6, 8, 9, 10, 12, 14, 18 or 24. The closure builder rejects a missing entry.
- `consts` / `cmap` — deduplicated constant pool (`K`).
- `locals` — active local variable descriptors (`name`, `slot`, `captured`, `cell_pc`, `access`).
- `upvals` — upvalue descriptors (`name`, `instack`, `idx`).
- `nextreg` / `maxreg` — frame-relative register allocator for locals and temporaries.
- `loop_breaks` — per-loop lists of pending `break` jump addresses to patch at loop exit.

### Upvalues and Heap-Cell Backpatching

Un-captured local variables live directly in frame registers `S[base + slot - 1]` and are read/written with `GETLOCAL`/`SETLOCAL`.

When a local variable is declared, the compiler emits a `NOP` placeholder (`cell_pc`) and records every `GETLOCAL`/`SETLOCAL` PC in `desc.access`. If an inner function captures that local:
1. `mark_captured(desc)` patches `co[desc.cell_pc]` from `NOP` to `CELL` (which wraps the register value in `{ v = value }`).
2. All previously emitted `GETLOCAL`/`SETLOCAL` instructions for that variable are backpatched to `GETCELL`/`SETCELL`, and future accesses emit `GETCELL`/`SETCELL` directly.
3. Both outer and inner closures share the same `{ v = value }` table cell.

---

## 4. Bytecode & Superinstructions (Opcodes 1-208)

### Base Opcodes (`1–51`)

| Range | Opcodes | Purpose |
|---:|---|---|
| `1–3` | `LOADK`, `LOADBOOL`, `LOADNIL` | Push constants, booleans, and `nil`s |
| `4–8` | `GETLOCAL`, `SETLOCAL`, `GETCELL`, `SETCELL`, `CELL` | Local register and captured-cell access |
| `9–12` | `GETUPVAL`, `SETUPVAL`, `GETGLOBAL`, `SETGLOBAL` | Upvalues and `env` table globals |
| `13–22` | `ADD`..`POW`, `CONCAT`, `UNM`, `NOT`, `LEN` | Arithmetic, string concat, and unary operators |
| `23–28` | `EQ`, `NE`, `LT`, `LE`, `GT`, `GE` | Relational operators |
| `29–32`, `51` | `TESTF`, `TESTT`, `JMPF`, `JMP`, `JMPNIL` | Short-circuit logical tests and jumps |
| `33–35` | `CALLD`, `RET`, `VARARG` | Function calls (including tail calls), returns, and `...` |
| `36–43` | `NEWTABLE`, `FIELD`, `INDEX`, `SETFIELD`, `SETINDEX`, `SELF`, `SETLIST`, `SETLISTMULTI` | Table creation, reads, writes, methods, and array initializers |
| `44–50` | `MARK`, `POP`, `FORPREP`, `FORLOOP`, `CLOSURE`, `PEEK`, `NOP` | Multi-return markers, numeric `for`, closures, and stack helpers |

### Fused Superinstructions (`52–208`)

`optimize_code(co, n)` runs after a function is compiled. **It never shifts instruction addresses:** it overwrites the first instruction of a matched pattern and marks the remaining `len - 1` instruction slots in `dead[]`. The VM advances `pc` by `4 * len` (e.g., `+8`, `+12`, `+16`, `+20`, `+24`, `+32`, `+36`, `+40`, `+48`, `+56`, `+72`, or `+96`).

A fusion is only applied if `can(pos, len)` confirms that none of the interior slots is a jump target (`targets[]`) or already dead. `can_tail(pos, len)` relaxes this for the last slot only: it may stay a jump target because the instruction itself remains physically present and valid, while the fall-through path skips it.

Several opcode families share one opcode and carry a **kind** in a dead slot (`C[pc + 4]`):

| Range | Superinstructions | What They Fuse |
|---:|---|---|
| `52–57` | `MOVLOCAL`, `MOVLOCAL_NOP`, `MOVLOCAL_CELL`, `SETLOCAL_K`, `SETLOCAL_INDEX`, `SETLOCAL_FIELD` | Direct local-to-local moves, constant stores, and `dest = t[k]` / `dest = t.field` without stack push/pop |
| `58–87` | `ADD_RR`/`RK` .. `POW_RR`/`RK`, `EQ_RR`/`RK` .. `GE_RR`/`RK`, `EQ_K` .. `GE_K` | Binary arithmetic and comparisons directly from local registers and constants |
| `88–94` | `INDEX_RR`, `INDEX_RK`, `FIELD_R`, `SETINDEX_RR`, `SETINDEX_RK`, `SETFIELD_RV`, `SETFIELD_RK` | Single-dispatch table reads and writes (`t[k] = v`, `t.f = v`) |
| `102–103` | `JMPF_LOCAL`, `JMPNIL_LOCAL` | Zero-stack local tests |
| `110–119`, `142`, `145–146` | `FORLOOP_MOV`, `FORLOOP_CELL`, `FORLOOP_ADD_RR`/`RK`/`INDEX`, `FORLOOP_SETINDEX_RR`/`RK`, `FORLOOP_SUB_RR`/`RK`, `JMPF_MOD_EQ_K`, `JMPF_MOD_RR_EQ_K`, `FORLOOP_MOD_RR_EQ_K`, `FORLOOP_NEWTABLE_SETINDEX_R` | Numeric `for` step fused with loop-variable copy and the first loop-body statement/branch, plus `x % d == k` branches |
| `132–133` | `TFOR_2`, `TFOR_1` | Full generic `for` header fused into 1 dispatch; runs `ipairs` and `pairs`/`next` directly in-VM without per-iteration function call overhead |
| `134–141` | `NEWTABLE_LOCAL`, `SETLIST_R`, `SETLIST_K`, `SETLIST_ADD_RK`, `NEWTABLE_FIELD_R`/`K`, `NEWTABLE_SETINDEX_R`, `NEWTABLE_LIST3_ADD_RK` | Fast table allocation and inline array/hash constructor population |
| `143–144` | `ADD_ASSIGN_BINOP_RR`, `SETLOCAL_BOOL` | In-place update with an in-VM `__add` frame push; `dest = true/false` |
| `147–150` | `TESTF_CMP_RR`/`RK`, `TESTT_CMP_RR`/`RK` | Comparison fused with the short-circuit test of `and`/`or`; the comparison kind (23–28) rides in the dead slot |
| `151–153` | `JMPF_CMP_RR`, `JMPF_CMP_RK`, `JMPF_CMP_K` | Comparison fused with `JMPF` for `if`/`while`/`until`; the kind replaces 18 separate opcodes |
| `154–156` | `ASSIGN_RR`, `ASSIGN_RK`, `ASSIGN_INDEX` | Compound assignment for all seven arithmetic operators; the operator (ADD=13 .. CONCAT=19) rides in the dead slot, replacing 7 separate opcodes |
| `157` | `SWAP` | `a, b = b, a` |
| `158–159` | `ASSIGN_MOD_ADD_RK`, `SETINDEX_MOD_RK` | `s = (s + i) % k` and `t[i % k] = v` |
| `160–161` | `CLOSURE_CELL`, `SETINDEX_CLOSURE_CELL` | Per-iteration boxed loop variable plus closure creation, and `t[i] = function() return i end` |
| `162–163` | `FORLOOP_ASSIGN_RR`, `FORLOOP_ASSIGN_RK` | Numeric `for` step fused with a loop-body assignment for `*`, `/`, `%`, `^` and `..`; the operator rides in the dead slot (`13`–`19` encoding) |
| `164–166` | `PUSH_OP_RK`, `PUSH_OP_RS`, `PUSH_OP_KS` | Left-to-right arithmetic chains (`k <op> a`, `<stack> <op> a`, `<stack> <op> k`) that the register-only `*_RR`/`*_RK` opcodes cannot cover; the operator rides in the dead slot (`13`–`19`) |
| `167–168` | `ASSIGN_TO_RR`, `ASSIGN_TO_RK` | `dest = a <op> b` when the destination is not the left operand (for example `zr2 = zr * zr`): one dispatch instead of an arithmetic opcode plus `SETLOCAL`; the operator rides in the dead slot (`13`–`19`) |
| `169–180` | `JMPT_CMP_RR_*`, `JMPT_CMP_RK_*` | Loop back-edge: comparison fused with a jump back to the body when true; the comparison kind is part of the opcode number (12 opcodes) |
| `181–184` | `CALL_U_RR2`, `CALL_U_RR1`, `CALL_R_RR2`, `CALL_R_RR1` | Direct call of an upvalue/local function with one or two register arguments; skips the `GETUPVAL`/`GETLOCAL` + `MARK` setup and pushes the callee frame in the same dispatch |
| `187–190` | `ADD_RR_ADD_K`, `MUL_DIV_K`, `ADD_R_ADD_K`, `DIV_RET` | Two-step arithmetic chains: `(a + b) + k`, `(a * b) / k`, `acc + a + k`, and `1.0 / d` immediately followed by `RET` |
| `193` | `SETINDEX_MUL3` | `t[k] = t[k] ± x * y * z`; operands are encoded as `+register` or `-upvalue`, so nbody's six updates collapse from nine dispatches to one |
| `194` | `SETINDEX_MUL2` | `t[k] = t[k] ± a * t[k2]`; `a` is `+register`/`-upvalue`, `k2` is `+register`/`-constant` |
| `195` | `FORLOOP_SETTRUE` | Numeric `for` whose body is `t[i] = true` (sieve): increments the control variable and performs the store in one dispatch |
| `196` | `ASSIGN_MUL3_ADD` | `dest = k * a * b + c` (mandelbrot inner assignment) |
| `198` | `INDEX_ADD_RK` | `t[a + k]`: `GETLOCAL t; ADD_RK a k; INDEX` collapsed into one dispatch |
| `199` | `MUL_ADD_SETLOCAL` | `dest = c + b * a` for the stack form `MUL; ADD; SETLOCAL`, preserving `__mul`/`__add` operand order |
| `200` | `INDEX_CMP_JMPF` | `t[k] <op> v` fused with `JMPF`; the table is a local/upvalue and the right operand is a local/constant. Operand descriptors use `+register` and `-upvalue`/`-constant` |
| `201` | `ASSIGN_SUB_ADD` | `dest = (a - b) + c` for the mandelbrot `zr` update |
| `202` | `ADD_JMPF_K` | `(a + b) <op> k` fused with `JMPF` |
| `203` | `INDEX_INDEX_RR` | `t[a][b]`: `INDEX_RR; GETLOCAL b; INDEX` collapsed into one dispatch |
| `204` | `MUL_ADD_SETLOCAL_FORLOOP` | `dest = c + b*a` immediately followed by the numeric-for back-edge |
| `205` | `INDEX_ADD_RK_CALL_U_RR2` | `v[j + k]` pushed immediately before a two-argument upvalue call; the index result stays below the call result on the stack |
| `206` | `DIV_MUL_ADD_SETLOCAL_FORLOOP` | `acc = acc + v * (a / b)` at the end of a numeric `for` |
| `207` | `DIV_K` | `k / x`, used when inlining a leaf whose constant numerator can stay out of the caller stack |
| `208` | `DIV_K_MUL_ADD_SETLOCAL_FORLOOP` | `DIV_K` followed by the loop-end multiply/add/store |

Opcode number `197` is an unused gap.

### Leaf-Function Inlining

`compile_funcbody` keeps an unoptimized `rawcode` copy and marks a prototype `simple` when it has no upvalues, no branches, calls, cells or locals, and its body is one arithmetic `return`. At a call site whose target is a known local/upvalue function (`func_idx`), the compiler expands the raw instructions directly into the caller: parameter reads are remapped to the caller's argument registers (or constants), `LOADK` indices are merged into the caller's constant table, and the final `RET 1` is simply omitted so the value stays on the caller stack. If the first constant survives to a final `DIV` as the numerator, it is folded into `DIV_K` instead of being pushed. Inlined instructions keep the callee's line numbers for tracebacks. A caller that contains inlined code is marked `has_inline`; calls to it are compiled with `CALLD` C = 2 instead of the tail-call marker 1, so the frame is retained and an inlined error still produces an `at file:line` frame. Ranges `95–101`, `104–109` and `120–131` are retired: they were folded into `ASSIGN_*` (154–156) and `JMPF_CMP_*` (151–153).

---

## 5. Virtual Machine (`run_closure`)

- **Shared Stack (`S`) & Explicit Frames (`frames`):**
  All active interpreted functions share a single Lua table `S`. Frame `fi` has its local registers at `S[base .. base + maxreg - 1]` and its expression stack above `base + maxreg - 1`.
- **Frame Pooling (`free_frames`):**
  Returning from an interpreted call recycles the frame table into `free_frames` (up to 64 entries), eliminating table allocations on hot call paths (`fib`, recursion, closures).
- **Tail-Call Optimization (`CALLD` with `C = 1`):**
  `parse_return` marks `return f(...)` calls with `C = 1`. When `f` is an interpreted closure, `CALLD` overwrites `cur` in place and jumps to `pc = proto.entry` without growing `fi` or consuming `maxCallDepth`.
- **Entry NOP Skip:**
  `emit_cell` reserves one `NOP` slot per parameter/local in case it is captured later and must become a `CELL`. At the end of compilation, `proto.entry` points at the first non-`NOP` instruction; frame setup starts there, so uncaptured parameter placeholders are never dispatched. Captured slots have already been rewritten to `CELL`, so they are still executed.
- **Balanced Dispatch Tree:**
  `run_closure` does not walk a linear `if/elseif` opcode chain. Both the base chain (1–51) and the fused chain (52–208) are generated as balanced range trees over the opcode number, with leaves of at most four exact comparisons. A hot instruction such as `ASSIGN_RK` or `JMPF_CMP_RK` is reached in about seven `op <` tests instead of sixty to ninety `elseif` tests, which keeps LuaJIT side traces short. Adding an opcode only lengthens one leaf.
- **Fast Callback Entry (`info[4]`):**
  Root chunks wrap `run_closure` in `pcall` to format runtime errors with `format_runtime_error(err, trace)`. Inner closures (such as `__add` metamethods or `table.sort` comparators) set `info[4] = true` and invoke `run_closure` directly when called from the host.
- **Flat Closure Record:**
  A closure's metadata and its upvalue cells share one pure-array table registered in the weak `closure_info` map: `[1]` prototype, `[2]` environment, `[3]` native-fenv flag, `[4]` fast flag, and upvalue `j` at `j + 4`. Creating a closure therefore allocates a single array instead of an array plus a hash table, which cut closure-creation cost by roughly a fifth without touching upvalue reads beyond a constant `+ 4` index offset.
- **Shared Cell Record:**
  When a closure captures exactly one variable and that variable is the fresh cell created for it — the common `for i = 1, n do fs[i] = function() return i end end` shape — the cell and the record become the same table: the constructor writes `{ v = value, proto, env, false, true }` and stores that table in its own upvalue slot. This removes one allocation per closure and is what lifted the per-iteration capture benchmark above FiOne.

### 5.1 Error reporting, guest `pcall`, and sandbox hygiene

`format_runtime_error(err, trace)` builds `<sourceName>:<line>: <message>` and
appends a Lua-style `stack traceback:` with tab-indented frames. Named local,
global, and method functions use `in function 'name'`; the root chunk uses
`in main chunk`; anonymous functions use `in function <source:line>`. When the
error came from the native `error` function, a leading
`[C]: in function 'error'` frame is included. Leaf functions inlined by the
optimizer carry an `inline_sites` range; the traceback adds a synthetic callee
frame and moves the caller frame to the call site, so inlining does not erase
the callee from the trace.

Two details keep host information out of the sandbox:

1. Host operator errors arrive with a host prefix such as
   `C:\mods\vm.lua:1771: attempt to perform arithmetic on a nil value`. The
   prefix is stripped with a greedy-safe pattern (`^.-:%d+: ([^\n]*)`) so both
   POSIX and Windows paths are removed before the sandbox location is added.
2. `pcall`/`xpcall` are special-cased in `CALLD`. When the first argument is an
   interpreted closure, the VM runs the target through `run_closure` under a
   fresh trace instead of letting the host `pcall` capture a raw error. The
   guest therefore sees `<string>:1: attempt to perform arithmetic ...` inside
   `pcall`, with no `custom_loadstring_full.lua:NNNN` in the message.

### 5.2 Tail-call stack reuse

A tail call reuses the current frame **and** relocates the function plus its
arguments down to the frame's original `base` before rebinding `p`, `C`, `K`,
`base`, and `top`. Without that relocation the base drifted upward on every
iteration, so a 600k-iteration tail-recursive loop eventually tripped
`maxStack`. With relocation the stack footprint is constant, and
`tests/test_tailcalls.lua` covers 600,000 iterations under the default
`maxStack` and `maxCallDepth = 10`.
- **LuaJIT 2.1 Comparison Workaround:**
  LuaJIT 2.1 has an upstream JIT compiler bug that can intermittently miscompile ordered relational comparisons inside large dispatch functions. Ordering comparisons therefore go through the module-scope helpers `cmp_lt`/`cmp_le`/`cmp_gt`/`cmp_ge` (numeric fast path, otherwise `compare_op`, which is `jit.off`), while equality and inequality stay direct. `has_jit` also consults `jit.status()`: when LuaJIT is present but its JIT is disabled (the usual modding configuration) the ordering fusions and the direct comparison path are enabled again. The per-instruction instruction budget is skipped when the limit is `math.huge`, and the current `pc` is kept in `trace[1]` rather than a hash field.

---

## 6. Experimental block-threaded closure slice

`gvm_runtime.lua` exposes `scan_block`, `build_block_chain`,
`build_program` and `run_block_chain`. They are the first vertical slices of
the v2 backend described in [`GVM_V2_ARCHITECTURE.md`](GVM_V2_ARCHITECTURE.md).

- `proto.slotlen` gives the exact span of every live instruction, including
  fused instructions.
- `scan_block` walks a block until a branch, call, loop edge or return and
  returns the instruction descriptors.
- `build_block_chain` is the per-instruction prototype: it turns supported
  stack arithmetic, locals, comparisons, branches, loops and `RET` into a chain
  of Lua closures.
- `build_block_closure` is the actual block backend: one Lua call executes a
  whole basic block through an internal dispatch, then returns the next block.
- `build_program` discovers the reachable block graph and links the closures
  through a shared entry table. It also recognizes the numeric-`for` sum shape
  (`acc = acc + i`) and replaces the whole loop with one loop-superinstruction
  closure. `maxInstructions` is enforced per block and per specialized-loop
  iteration.
- Unsupported instructions make the builder return `nil, err`, so the prototype
  falls back to `run_closure`.

The public option `backend = "closure"` is experimental. It compiles the
selected chunk without peephole fusions so the block builder sees base
opcodes, and it supports `if`/`while`/`repeat`/numeric `for`/`break` for leaf
functions. `CALLD` is handled for native and interpreted targets, including
tail calls, result adjustment and multiple returns, but through host recursion
with explicit frames and tail-call reuse. `CLOSURE`, upvalues, heap cells,
table construction/reads/writes, `SELF`, varargs/open returns, globals and
generic `for` (through `CALLD`/`MARK`/`JMPNIL`) are also handled.
`maxInstructions`, `maxArgs`, `maxReturns`, `maxStack` and `maxCallDepth` are
enforced; runtime errors get a source-located traceback. Guest `pcall`/`xpcall`
and fresh loop cells work. `fused = true` enables the data-opcode subset
(`MOVLOCAL`, arithmetic, table reads/writes, assignments, `PUSH_OP_*`), the
fused numeric-`for` terminators `112-118`, and comparison branches
`102-103`/`147-153`/`169-180`. Fused call/index and specialized loop opcodes
still fall back. Broader metamethod/edge-case coverage is still being filled
in. Keep the
default `backend = "legacy"` for production and untrusted code.

---

## 7. Host-dependent semantics

GoogiVM implements the Lua 5.1 language itself; the following behaviors are
inherited from the host and are intentionally not emulated:

| Area | Where it comes from |
|---|---|
| `#` on tables with holes | `luaH_getn` of the host; not "highest integer key". |
| `__len` on tables | Only if the host honors it (LuaJIT, Lua 5.2+); plain Lua 5.1 ignores it. |
| `getfenv` / `setfenv` | Host availability. Interpreted closures and numeric levels are supported; `setfenv(0, ...)` and native function environments are rejected. |
| Number formatting | Host `tostring`. |
| Operator error text | Host message body; only the location prefix is rewritten. |
| Standard libraries | Whatever the embedder supplies in `env`. |
| Metamethod dispatch | Host operators (`__eq`, `__lt`, `__le`, `__concat`, `__len`, ...). |
| Restricted sandboxes | Missing `setmetatable`/`getmetatable`/`rawget`/`rawset` are tolerated; the VM uses only the helpers it needs (`getmetatable` is optional). |

These are documented in [`README.md`](README.md) so that "Lua 5.1 compatible"
is not read as "host-independent standard library".
