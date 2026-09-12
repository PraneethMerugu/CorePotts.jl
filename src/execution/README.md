# CorePotts execution source map

CorePotts turns declared scientific programs into one checkerboard execution
chain:

```text
descriptors and ResourceAccess
→ cold requirement and stage lowering
→ prepared LocalMath color laws
→ queued color receipts
→ Core lifecycle and bank settlement
```

The principal source owners are:

- `descriptor_plan.jl` and `stage_plan.jl`: frozen descriptor order, resource
  access, accepted effects, and source provenance;
- `checkerboard_requirements.jl`: cold inventory, footprint validation, access
  deduction, and compilation into concrete executable terms;
- `gathered_proposal_evaluation.jl`: warm bounded proposal contexts and the
  evaluation of compiled terms over gathered values. Context construction uses
  named fields and retains concrete hot value types;
- `proposal_context.jl`: runtime proposal overlays and the shared pure
  center, covariance, and length arithmetic. Gathered evaluation and
  `lifecycle_context.jl` reuse those formulas while retaining their own bounded
  reads, third-endpoint lookup, and staged-versus-live tracker selection;
- `checkerboard_science.jl`: proposal geometry, topology declarations, and
  Core scientific evaluator callables. Cold named read groups produce both
  the LocalMath accesses and their compile-time decoder offsets; optional
  groups do not have a separately maintained positional layout. Warm contexts
  remain concrete bounded values, not stored compiler plans;
- `checkerboard_transaction.jl`: accepted tracker and relationship scratch,
  packed shadow-state settlement, and terminal transaction fragments;
- `tracker_plan_contracts.jl` and `tracker_source_execution.jl`: authoritative
  tracker contracts, cold selection of incrementally maintainable lifecycle
  entries, and binding of only their exact state/source arrays. Dense scalar
  update counts are values within a bounded capacity class; author quantity
  identity and reconstruction-only trackers do not enter this hot recipe;
- `lifecycle_commit_state.jl` and `lifecycle_commit_relationships.jl`: the
  owner-change transaction over its narrow ownership, cell-kind, tracker,
  descriptor-state, and status view. The function signature exposes the state
  required by this semantic operation instead of accepting the complete
  lifecycle workspace;
- `checkerboard_law.jl`: composition, storage binding, and preparation of the
  ordered LocalMath laws;
- `checkerboard_queue.jl` and `checkerboard_runtime.jl`: submission ordering,
  cumulative receipt ownership, status bridging, and the MCS runtime;
- `lifecycle_*`: lifecycle selection, staging, validation, rollback, and
  publication; and
- `program_settlement.jl`: provider waiting and final authorized bank
  publication.

Scientific evaluation reads the immutable stage-entry bank. Fallible work
writes scratch or packed shadow storage; live ownership, trackers, auxiliary
state, relationships, and reports are published only after the preceding
transaction succeeds. LocalMath owns bounded topology, publication laws, and
the shared KernelAbstractions execution path. CorePotts retains Hamiltonian
order, semantic RNG, acceptance, lifecycle, rollback, checkpoint, and bank
authority.

Sequential execution remains the independent scientific reference. It is not
an alternate checkerboard backend.
