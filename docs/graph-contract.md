# Graph contract

**Status:** implemented in `src/graph/` for milestone M3 (`docs/DELIA_REFACTOR_PLAN.md`,
sections 4.5 and 7). Every acceptance item in section 7 has a test in `src/graph/compiler.zig`.
**Sketches:** `docs/examples/graph_node_sketch.zig`, `graph_plan_sketch.zig` and
`graph_compiler_sketch.zig` preceded the implementation and use stand-in buffers and nodes; the
code in `src/graph/` is authoritative.

Builds on `docs/buffer-contract.md`. Section 8 of that document (node I/O) is the node's side of
this contract and is not repeated here.

| File | Contents |
|---|---|
| `src/graph/node.zig` | `Node(T)`, `Ports`, `PrepareContext`, `ProcessContext`, `NodeError` |
| `src/graph/nodes/gain.zig`, `src/graph/nodes/oscillator.zig` | first nodes on the new interface |
| `src/graph/nodes/root.zig`, `src/graph/root.zig` | aggregators |
| `src/graph/builder.zig` | `GraphBuilder(T)`: nodes, edges, output marker |
| `src/graph/compiler.zig` | `Compiler(T).compile()`: builder to plan |
| `src/graph/plan.zig` | `ExecutionPlan(T)`, `Op`, `render()` |

The old graph (`Graph`, `TopologyQueue`, `Scheduler` on `UniformChannelViews`) was deleted in
M4a (October 2026); it is in git history before the `remove legacy graph and backend` commit.
Its buffer assignment shared a producer's buffer with its last consumer, which is the in-place
optimization this contract defers, so it was not reused.

## 1. Phases

```text
build     GraphBuilder: add nodes, connect ports, mark the output      mutable, allocates
compile   validate, order, assign slots, prepare nodes, allocate        allocates, may fail, transactional
render    execute the op list over the pool into the caller's block    no allocation, no errors past one entry check
deinit    release plan, then builder                                    outside render
```

## 2. Node

A node is any struct with:

```text
pub const ports: Ports                                  input and output port counts, comptime
pub const name: []const u8
fn prepare(*Self, PrepareContext) NodeError!void
fn process(*Self, ProcessContext) void
```

```text
Ports                   { inputs: u8, outputs: u8 }
Node(T).PrepareContext  { sample_rate: T, max_frames: specs.BlockSize, channel_count: usize }
Node(T).ProcessContext  { inputs, outputs, frame_count }    rules: buffer-contract.md section 8
NodeError               error{allocation_error}             prepare only; createNode returns
                                                            std.mem.Allocator.Error
```

- Port counts and the name are comptime declarations, checked by `Node(T).init`. A missing or
  mistyped `ports` or `name` is a compile error. Runtime port counts are not supported.
- Every port carries the graph's channel count. A node does not choose channel counts per port.
  This closes buffer-contract open question 1 for M3: the pool stays uniform.
- `prepare` is called once per compile, may allocate through an allocator the node stores, and
  must tolerate being called again with different values on a later compile.
- `process` follows buffer-contract section 8: reads inputs, writes every active frame of every
  output, keeps no block past the call, allocates nothing, returns nothing.
- `Node(T)` is the type-erased wrapper: `ptr`, `vtable`, `ports`. It carries no status field.
  Execution order is the compiler's decision, not something nodes report.
- Nodes are `f32` or `f64` like everything else; graph audio is `f32`.

## 3. Builder

```text
GraphBuilder(T)
    addNode(node: anytype) !NodeHandle         copies the struct to the heap, wraps it in Node(T)
    connect(from, to) !void                    edge (from, output 0) -> (to, input 0)
    connectOutput(from) !void                  (from, output 0) feeds the graph output
    deinit()                                   destroys every node
```

- Edges store port numbers on both ends. `connect` is `connectPorts(from, 0, to, 0)`; multi-port
  nodes use `connectPorts` directly.
- The graph output is not a node. It behaves like one input port on a virtual sink so fan-in into
  it follows the same rule as fan-in into any port.
- The builder rejects `invalid_handle` and `port_out_of_range` at the call site, because a node's
  `ports` is known the moment it is added. Structure (connectivity, cycles) is validated at
  compile.
- The builder owns the node heap copies. A plan borrows them. The builder outlives every plan
  compiled from it and is not edited while a plan is rendering: stop, edit, recompile, restart.
  Node state (oscillator phase, filter history) lives in the node struct, so recompiling after an
  edit keeps the state of nodes that were not touched.

## 4. Compile

```text
Compiler(T).compile(allocator, *const GraphBuilder(T), CompileOptions(T)) CompileError!ExecutionPlan(T)

CompileOptions  { sample_rate: T, max_frames: specs.BlockSize, channel_count: usize }
```

Rejected, with nothing allocated on return:

| Condition | Error |
|---|---|
| an input port has no producer | `disconnected_input` |
| `connectOutput` was never called | `no_output` |
| the graph has a cycle | `cycle_detected` |
| a node's `prepare` fails | its `NodeError` |
| the pool cannot be built (`channel_count == 0`, size overflow) | its `AudioBufferError` |

Rules:

- **Order** is a topological sort. Ties break by node index, so the same builder always compiles
  to the same op list. This matters for fan-in: floating-point sums depend on the order of the
  terms, and "deterministic output" means the mix order is fixed too.
- **Slots.** One pool slot per (node, output port). One extra *mix slot* per input port, including
  the graph output, that has more than one producer. No slot is reused within a render call. This
  makes fan-out free: a producer's slot is never overwritten, so every consumer reads it as is.
- **Ops**, emitted in execution order, for each node: for every input port with `k > 1` producers,
  `clear mix` then `k` times `accumulate mix += producer` in edge insertion order; then `process`
  with the node's input slots (producer slot, or mix slot) and output slots. After the last node:
  `copy_out` from the graph output's slot.
- `prepare` runs on every node in node index order after validation and before pool allocation.
- **Transactional:** on any error, everything compile allocated is freed and the builder is
  unchanged. Nodes may have been prepared; that is why `prepare` must be repeatable.

```text
Op
    clear       { slot }
    accumulate  { dst, src }
    process     { node, inputs: []const Slot, outputs: []const Slot }
    copy_out    { slot }
```

## 5. Render

```text
ExecutionPlan(T).render(out: AudioBlock(T)) error{shape_mismatch}!void
```

- The plan records what it was prepared for: `sample_rate`, `max_frames`, `channel_count`.
  `max_frames` is a capacity. A caller renders any total length as a sequence of blocks of
  at most `max_frames`; the total does not need to be a multiple of it.
- One check at entry: `out.channel_count == channel_count` and `out.frame_count <= max_frames`.
  Otherwise `shape_mismatch` and nothing is written.
- `out.frame_count == 0` returns without calling any node.
- Every block handed to an op has `frame_count == out.frame_count`.
- The op loop performs no allocation, takes no lock, logs nothing, checks no node status, and
  looks up no names. Block-op errors (`shape_mismatch`, `forbidden_overlap`) are `unreachable`
  after the entry check: the compiler proved the shapes, and pool slots are disjoint by
  construction. This closes buffer-contract open question 2: ops keep their errors, the plan
  resolves them once.
- `out` must not alias plan storage. Debug and ReleaseSafe builds catch it through the copy's
  overlap check; it is a contract violation, not a runtime error.
- `copy_out` costs one copy per block. That is deliberate: the caller's block can have any stride
  (device buffer, `OwnedAudioBuffer`), and the pool never aliases external memory.
- The per-op `[]ConstAudioBlock` and `[]AudioBlock` slices are scratch arrays allocated at
  compile, sized to the largest port count in the plan, and refilled per op.

## 6. Ownership

| Value | Owns | Freed by |
|---|---|---|
| `GraphBuilder(T)` | node heap copies, edge list | `builder.deinit()` |
| `ExecutionPlan(T)` | pool, op list, scratch slices, node pointer table | `plan.deinit(allocator)` |
| `Node(T)` | nothing; points into the builder | n/a |

Destroy order: plan, then builder. Both outside render.

## 7. Acceptance tests

Prediction, written before implementation: Sine(440 Hz, amplitude 1) into Gain(0.5) rendered as
four blocks of 64 frames at 48 kHz matches `0.5 * sin(2*pi*440*n/48000)` computed in `f64`, to
within `1e-4` for `f32`. Phase accumulates in `f32` in `dsp.waves.Wave`, so if the tolerance has
to grow past that, the suspect is the kernel, not the graph.

- [x] Gain and Oscillator process a partial block through `Node(T)` with a sentinel in padding;
      the input block is unchanged
- [x] Oscillator keeps phase across calls: two calls of 8 frames equal one call of 16 on a
      fresh node
- [x] chain Sine -> Gain -> output over four blocks matches the reference (prediction above)
- [x] partial last block (64, 64, 17) is still continuous
- [x] every slot's active frames are overwritten during a render; padding keeps its sentinel
- [x] render allocates nothing: allocation count is unchanged after 100 blocks
- [x] fan-out and fan-in: Sine -> Gain(0.25), Sine -> Gain(0.5), both -> output gives `0.75 * sin`
- [x] diamond: Sine -> A, Sine -> B, A -> C, B -> C, C -> output
- [x] compile rejects: unconnected input, no output, cycle, bad port; render rejects: wrong channel
      count, `frame_count > max_frames`; zero frames is a no-op
- [x] failed compile leaks nothing and leaves the builder usable (`checkAllAllocationFailures`)
- [x] op list and slot count are pinned for the chain (2 slots, 3 ops) and for fan-in
      (4 slots; `clear, accumulate, accumulate, copy_out` at the end)

## 8. Open questions

Revisit when a consumer needs an answer.

- Slot reuse. Lifetime analysis is a compiler-only change; the plan and nodes do not see it.
  Add it after the acceptance list passes, with the pinned op-list tests as the comparison.
- Exact in-place execution for nodes that declare it. Also compiler-only.
- Per-port channel counts and runtime port counts. Would need a second pool or per-slot shapes.
- Unconnected inputs as silence instead of an error. Rejected for now: silent defaults hide
  wiring mistakes.
- Parameter access from outside the render thread (M5). Nothing here reserves space for it.
- Whether the plan should take ownership of nodes from the builder so the builder can be edited
  while an old plan is still rendering (7.4). Not before publication and retirement exist.
