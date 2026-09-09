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

## Settled input publication

The public `update_program_inputs!` entrypoint in
`execution/program_settlement.jl` owns combined parameter and auxiliary-state
publication. Auxiliary-state validation uses the storage owner; input-dependent
tracker reconstruction uses `execution/tracker_plan_runtime.jl` and the
LocalMath reduction in `execution/tracker_source_execution.jl`. Publication
updates the host mirror and both execution banks only after scientific
validation, without creating a separate downstream transaction authority.

`program_snapshot` exposes the resulting settled state. Ordinary behavior is
covered by `test_program_input_publication.jl`, its shared
`fixtures/program_input_publication_support.jl`, and
`test_source_aware_trackers.jl`; the device entrypoint is
`metal/corepotts_input_publication.jl`. Device and continuation guarantees
require the corresponding tests to pass for the selected execution profile.

Coordinated native stepping remains owned by `ProgramStepTransaction` in
`execution/sequential_program.jl`. Explicitly staged inputs use the same tracker
reconstruction owner during prevalidation; ordinary no-input transactions retain
incrementally accumulated values. Candidate snapshot validation receives the
effective pending parameters without publishing them. The owning regressions
are in `test_program_step_inputs.jl`, alongside the existing transaction tests in
`test_compiled_program_execution.jl`.

Checkerboard scientific state and parameter buffers belong to each execution
bank, independently of the published host state. `execution/checkerboard_workspace.jl` constructs
and adapts those buffers; the scientific copy schema in
`execution/checkerboard_program_declaration.jl` carries their values when the
active bank changes. Parameters do not have a separate copy executor. Staging
can therefore change the candidate's coefficients without publishing host
inputs; abort restores the execution position through the existing
KernelAbstractions control kernel. Alternating commit/abort and no-input-step
regressions live in `test_program_step_inputs.jl`, while
`test_lifecycle_receipts.jl` exercises copy-schema validation, including empty
storage. Adaptation additionally requires the device publication tests above.

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
