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
