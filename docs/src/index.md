# CorePotts.jl

CorePotts owns the scientific execution contracts beneath Potts: proposal
meaning, semantic randomness, scheduling, lifecycle transactions, rollback,
bank authorization, and checkpoint continuation.

CorePotts compiles eligible bounded mechanics to LocalMath while retaining
those domain authorities explicitly.

## Execution architecture

The scientific compiler follows one explicit path:

```text
DescriptorExecutionPlan + ResourceAccess + StageExecutionPlan
    → bounded LocalMath color and lifecycle-boundary laws
    → prepared KernelAbstractions execution
    → checkerboard queue and Core-owned lifecycle transaction
    → failure-atomic bank settlement and checkpoint continuation
```

`ResourceAccess` describes the scientific information a descriptor requires;
CorePotts chooses its bounded LocalMath representation. LocalMath owns spatial
access, conflict laws, publication, and physical execution. CorePotts retains
Hamiltonian order, proposal and acceptance meaning, semantic RNG coordinates,
lifecycle selection, rollback, and bank authorization. Lifecycle selection is
therefore reported as a Core KernelAbstractions operation followed by a genuine
LocalMath compacted-request publication, rather than as one LocalMath law.

Staged native stepping uses `BackendSPI.stage_program_mcs!`, input staging,
prevalidation, and commit/abort in `execution/sequential_program.jl`. Both
checkerboard scientific banks own storage independently of the published host
state. `execution/checkerboard_workspace.jl` constructs and adapts these banks;
the copy schema in `execution/checkerboard_program_declaration.jl` carries
scientific values and parameters between them. Commit publishes a settled
snapshot; abort restores the execution position through the existing
KernelAbstractions control kernel. `program_snapshot` exposes only settled
state. Repeated staged publication and abort across both bank parities are
defended by `test_compiled_program_execution.jl`; schema and lifecycle-bank
ownership are covered by `test_lifecycle_receipts.jl`. Device guarantees require
the corresponding actual-backend execution tests, not CPU tests alone.

`adapt_program_runtime` is a source-preserving ownership boundary, not an
ownership transfer. Its public path copies mutable host science and proposal
scratch; ordinary internal runtime rebuilding retains the same owner by
default. Workspace adaptation uses the existing storage-specific Adapt
traversal and copies array leaves, including controls and scratch when source
and destination use the same backend. Lifecycle staged-state aliases are then
rebound by their existing owner, and execution preparation creates fresh
provider resources. Compiled declarations and logically immutable lifecycle
receipts may be shared; no supported operation mutates them.
Storage adaptation retains the topology identity computed from the canonical
host declaration. Tracker admission uses the actual destination backend while
preserving each tracker's adaptation hook and structural checks.

The shared `fixtures/program_adaptation_support.jl` tests retain and advance
the source and two adapted runtimes, checking ordinary state, staged inputs,
abort, lifecycle removal, counters and receipts. The ordinary CPU entrypoint
is `test_program_adaptation.jl`; the actual Metal entrypoint is
`metal/corepotts_program_adaptation.jl`. Storage adaptation does not itself
establish cross-backend checkpoint portability or bitwise trajectory parity.

## Qualified semantic randomness

The active RNG contract is `Philox4x64x10V3`, version `3.0.0`. Its 128-bit
operation key and 256-bit counter keep component identity, cell generation,
scientific invocation and sampler retry separate. Existing stream families
retain their scientific meanings, but this contract intentionally changes their
random words. Older RNG checkpoints cannot resume exactly in this runtime;
reproducing them requires their released environment, not a compatibility mode.

Compiler authors submit the complete operation declaration batch through
`CompilerSPI.rng_operation_keys`. Each declaration contains an owner
`CompilerSPI.RNGNamespace` and a canonical identity string for the component
instance, process/boundary and lexical draw label. The returned keys follow
input order without depending on that order. Duplicate identities, derived-key
collisions and collisions with Core's reserved operations are rejected. The
compiler retains the mapping in its existing executable/provenance authority;
Core maintains no mutable RNG registry. `RNGOperationKey()` denotes an absent
draw in an inactive descriptor policy and cannot form an executable address.

The contributor path is `rng/operations.jl` (cold identity derivation),
`rng/semantic.jl` (packing, Philox and numerical transforms),
`execution/program_rng.jl` (scientific context addressing), and ordinary
`test_rng_operations.jl`, `test_rng_contract.jl`,
`test_rng_program_continuation.jl` and `metal/corepotts_rng_contract.jl` tests.
Address-family availability does not itself admit a scheduled evaluator or a
new distribution; those require their owning execution and numerical contracts.
Gathered lowering specializes a declared literal distribution family so a
Bernoulli constraint retains a Boolean result while numerical draws retain the
scientific scalar type. It uses the same draw consumer and runtime validation.

## Logical auxiliary-state values

`CompilerSPI.StateBlockSchema.element_type` describes one logical value;
`shape` describes the block's domain extent. A fixed vector or tensor therefore
does not introduce additional lattice axes. The storage owner initializes scalar,
fixed-array, tuple, and named-product values without converting Boolean or integer
leaves to floating point. Its `:shape_and_finite` validation visits numeric leaves
of tuples, named products, and fixed arrays, including checkpoint reconstruction.
Independently owned snapshots of structured values require immutable leaves
(for example, `SVector` rather than `MVector`): the existing block-copy codecs
do not deep-copy arbitrary mutable objects nested inside an element.

Storage admission alone does not establish executable stage, lifecycle, or GPU
support for a value type. Each of those paths must support the declared operations
and policies; arbitrary Julia objects are not a promised device value format.
The implementation and storage-level behavioral tests are in
`execution/storage_runtime.jl` and `test_logical_state_values.jl` respectively.
