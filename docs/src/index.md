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
