# [CorePotts API](@id corepotts-api)

Most users should author with Potts. CorePotts intentionally exposes a
narrow MTK-free runtime boundary:

- `ProgramInitialState`, `ProgramRuntime`, `ProgramSnapshot`;
- `initialize_program`, `initialize_history!`, `advance_mcs!`, `program_snapshot`;
- parameter updates, execution/capability reports, and failure reports;
- `ProgramCheckpoint`, `program_checkpoint`, and
  `restore_program_checkpoint`; and
- generation-safe lifecycle identities, events, receipts, and receipt access.

Compiler and backend implementation protocols are quarantined in the named
`CorePotts.CompilerSPI` and `CorePotts.BackendSPI` modules. A downstream
extension should use the smallest public member of those modules and pass its
owner-package conformance suite. Private file topology and underscored helpers
are not extension points.

`CompilerSPI` constructs and inspects validated compiler IR. `BackendSPI`
implements admitted runtime, transaction, adaptation, and settlement behavior.
They are explicit facades over CorePotts bindings rather than parallel
implementations, and an extension should not mix them merely for convenience:
compiler extensions describe validated scientific/compiler meaning, while
backend extensions provide execution, storage, and settlement behavior for an
admitted device profile.

```@example core_boundary
using CorePotts
runtime_api = Set((
    :ProgramInitialState,
    :ProgramRuntime,
    :initialize_program,
    :initialize_history!,
    :advance_mcs!,
    :program_checkpoint,
))
(
    all(name -> Base.ispublic(CorePotts, name), runtime_api),
    Base.ispublic(CorePotts, :CompilerSPI),
    Base.ispublic(CorePotts, :BackendSPI),
)
```

CorePotts owns numerical invariants and logical persistence; it does not own
symbolic biological authoring, ModelingToolkit systems, SciML solver
selection, or presentation.

## Compiler extension boundary

Compiler extensions build the same concrete expression values consumed by the
CorePotts compiler. For example, this one-node evaluator requests the proposal
target site; it is data, not a host callback or runtime expression interpreter.

```@example core_compiler_spi
using CorePotts
const SPI = CorePotts.CompilerSPI

target_site = SPI.StaticEvaluator(
    SPI.ContextExpression(SPI.ContextOperation{:target_site}()),
)

(nodes = SPI.evaluator_node_count(target_site),
 callable = isbitstype(typeof(target_site)))
```

Descriptor sources are checked while constructing the compiler plan. A
foreign or out-of-range source handle is rejected with the descriptor,
operation, role, and source-table context instead of becoming an anonymous
integer provenance value.

### Scheduled state and relationship publication

History storage has one dense trailing retention axis over its declared source
domain. `history_sample_handle` constructs only validated read-only whole-sample
projections; every write remains a canonical layout handle. The source relation
is derived from the actual `ShiftAppendEffect`, not another runtime registry.

`initialize_program` captures histories explicitly scheduled with `AtMCSCadence`
at zero after fresh preparation. It replaces only the newest sample, retaining
older prehistory, without executing ordinary MCS processes or changing counters.
An embedding initializer may set `capture_initial_history=false`, settle its
initial source values, and call `initialize_history!` once. Nonzero construction
and checkpoint restoration never capture automatically. Checkerboard initialization
executes existing prepared history laws against the inactive bank; successful
`InitializationSettlement` materializes that candidate for the validated state
publisher, while failure retains the active bank. Ordinary settlement's positive
failure-boundary checks are unchanged.

At each before- or after-lifecycle boundary, ordinary site, cell, and model assignment
right-hand sides and relationship requests observe boundary-entry state.
Assignments then publish in descriptor order. Iterated site updates and history
appends retain their ordered position: each iteration observes the preceding
iteration, and a history append records the value at its position in the
boundary. Prepared relationship changes publish after those state operations.
Sequential and checkerboard execution share this contract; checkerboard
evaluation and publication use the existing LocalMath execution path.
Lifecycle plan construction rejects state actions without the required participant:
creation can initialize a new destination but cannot reset a source; removal,
retirement, and transition can update their source but have no new destination.
Daughter-state policies require division. `ResetLifecycleState` writes the existing
source, whereas `InitializeLifecycleState` writes the allocated destination.
Lifecycle selection requires both identity metadata arrays to match the plan's
declared cell capacity. Allocation examines that complete domain, reusing retired
identities before unused identities beyond the highest previously used slot.
Lifecycle value policies convert to the declared logical type; incompatible
values fail the transaction. Static-array conversions may reshape equal-length
values, but cannot change their element count. Integer conversions require an
exact, in-range value; Boolean conversions require zero or one. Both signed
floating zeros convert to zero, but nonzero subnormals are not integers, even
on devices that flush floating-point comparisons near zero. Invalid values
report the existing lifecycle evaluator failure and preserve the whole MCS
transaction. These checks apply recursively to fixed vectors and nested tuples
and named tuples. Julia's ordinary field-name and arity rules still govern
product conversion, including matching positional values for a named tuple.
These conversion rules do not extend backend state-bank admission.
Cell-owned histories use these same policies for every retained sample. The
state-policy `lifecycle_occurrence` is its newest-relative lag (ordinary cell
state uses zero); it does not replace the cell slot or generation.
`lifecycle_before_state_value` reads the immutable transaction-entry sample,
whereas `lifecycle_planned_state_value` reads the corresponding participant's
sample from the existing request-local staged state. A late sample failure
abandons the entire transaction, including earlier sample writes.
The ordinary lifecycle conversion tests exercise scalar values, fixed vectors,
and nested positional/named products on both sequential and checkerboard CPU
execution, with matching checkerboard Metal transactions and scalar indexing
disabled. They check successful retirement, rejected-value rollback, retained
ownership and generations, and lifecycle receipts. CPU/Metal agreement for these
transactions is not a promise of exact trajectory replay across RNG contracts;
the current RNG contract and older-checkpoint limitation are described under
[Qualified semantic randomness](@ref).
Disabled model and cell assignments do not publish: a later disabled assignment cannot
undo an earlier enabled write to the same logical value. Site assignments retain
their entry-value fallback when disabled.
Assignment results are converted to the declared logical type before finiteness is
checked; conversion overflow is a failed transaction, not a published infinity.

A site, cell, or model assignment stores one logical value, which need not be a
scalar. Supported fixed-size products retain their declared type through
assignment, logical checkpoint storage, and ownership-change clearing.
A zero-dimensional singleton model block retains its declared shape in
snapshots and checkpoints; its model-domain execution view shares that storage.

Proposal predicates can read that sole model value with
`operation_callable(Val(:model_bound_state_value), v"1.0.0")` applied to a
`StateExpression(handle)`. Declare the handle in the descriptor's state and
read inventories. Both CPU engines read the same model-owned bank region;
checkerboard gathers repeat its address, not its storage. Descriptor validation
rejects a non-model handle passed to this operation and a model handle used as
a spatial `field_value` or bounded-fold resource. The ordinary model-predicate
tests cover actual rejected attempts and checkpoint continuation.
`test_model_state_energy.jl` additionally checks model coefficients in
conservative cell-volume energy against an independent energy-difference
formula, using sequential and gathered anchor evaluation. These bounded
witnesses do not establish every Hamiltonian/contact combination or device
execution.

Stage read scope belongs to each operand, not to the assignment target. A
site assignment may combine an iteration-bound site value with a model-bound
singleton. `CompiledPottsProgram` validates these bindings against the descriptor
state layout before either engine executes; `StageExecutionPlan` does not keep
another layout. Site assignment targets remain site-owned, and model assignment
targets remain singleton model-owned blocks.

`ClearOnOwnershipChange` clears the registered value at a changed site, not the
whole block. Unsupported operations or storage still require explicit
admission; these contracts do not imply support for every value type or device.

Compiler extensions declare `CompilerSPI.CellAssignmentEffect(target, kind)`
at an existing after-MCS boundary. Its domain is the runtime's finite-cell
identity table, not the occupied lattice: each active slot of the declared kind
and a live generation is evaluated once, independently of volume. Inactive and
other-kind slots evaluate neither the condition nor the right-hand side and
retain their state. The `:cell_bound_state_value` operation reads the current
cell's declared state through `AbstractCellStageEvaluationContext`, without
converting a cell identity into a site.

The existing `:energy_anchor_cell` contextual operation identifies that selected
finite-cell slot in a cell-stage evaluator. The corresponding
`:energy_anchor_site` operation identifies the canonical one-based linear
lattice index in a site-stage evaluator. These anchors do not change the
effect's iteration domain; a cell anchor is not admitted in a site context, or
vice versa.

Scheduled model, cell, and site evaluators can use the existing `:draw`
operation with a compiler-declared `RNGOperationKey`. Bernoulli, uniform, and
normal draws use the same distribution transforms as proposal and lifecycle
evaluators. A draw is addressed by the trajectory, qualified operation,
completed MCS, before/after-lifecycle boundary, logical entity, cell generation
when relevant, and zero-based scientific substep. Ordinary synchronous updates
use substep zero. Iterated updates receive fresh addressed noise each substep;
held noise is an explicitly sampled state read by another process.
There is no mutable RNG cursor to checkpoint or roll back. Uniform/Bernoulli
cross-backend comparisons and normal floating-point comparisons are distinct
guarantees; normal transforms do not imply bitwise cross-backend replay.

Cell assignments admit same-cell reads from `:cell` state schemas and explicit
`:model_bound_state_value` reads from singleton `:model` schemas. Model values
are held at boundary entry, even when another model assignment updates them in
that boundary. Site reads do not acquire a cell binding implicitly.
Each referenced cell block must cover the complete finite-cell identity capacity;
an insufficient or wrong-domain block is rejected before initialization can
mutate state. Both condition and value reads must appear in the descriptor's
declared access contract; initialization does not infer missing declarations.
Extra allocated slots are not additional identities and remain
outside the execution view. An empty identity table performs no cell updates.
Logical blocks may have zero-length dimensions, retaining their declared type
and shape through allocation, adaptation, and checkpoint storage; negative
dimensions remain invalid. This does not admit an empty physical lattice.
Lifecycle ordering remains the existing before/after boundary ordering; a
transient zero-volume identity is not silently filtered out by volume.

The existing operation lookup supplies `operation_callable(Val(:fixed_vector),
v"1.0.0")` for immutable vector construction and
`operation_callable(Val(:fixed_index), v"1.0.0")` for element access. These are
ordinary concrete callables used inside `OperationExpression`; construction
preserves the promoted element type. Authoring compilers own shape and index
admission, including proving literal indices in bounds before device execution.

The same lookup supplies `:sine` and `:cosine` at schema `v"1.0.0"`; these are
the standard `sin` and `cos` numerical callables, without a separate rotation
executor. Authoring compilers own scalar and dimensionless-argument admission.
`test_trigonometric_operations.jl` checks concrete Float32/Float64 expression
evaluation, including the ordinary integer-to-floating result rather than an
incorrect integer-preservation claim.

`operation_callable(Val(:product_field), v"1.0.0")` selects one field of a
named product by its declared ordinal without converting its value. Authoring
compilers prove that the ordinal selects an existing field and retain the
selected field's type, shape, and units. Field spellings and symbolic declaration
types do not enter the execution callable or create separate operation schemas.

## Diagnosing a settled failure

`program_failure_report(runtime)` is passive: it returns the cached immutable
failure detail after settlement, or `nothing`. The `code` and `detail` fields
name the broad failure and its precise cause, while `mcs`, `stage`, `source`,
and `anchor` locate it.

```@example core_failure_report
using CorePotts

report = CorePotts.ProgramFailureReport(
    CorePotts.ProgramStatusAcceptance,
    4,
    CorePotts.ProgramStageAcceptance,
    Int32(7),
    UInt64(0),
    Int32(0),
    Int32(12),
    CorePotts.LifecycleDetailAcceptanceNonfinite,
    Int32(0),
    Int32(0),
    Int32(0),
)

(report.code, report.detail, report.mcs, report.source, report.anchor)
```

## Reference

```@docs
CorePotts.CompilerSPI
CorePotts.BackendSPI
```

```@autodocs
Modules = [CorePotts]
Private = false
```
