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
  evaluation of compiled terms over gathered values;
- `checkerboard_science.jl`: proposal geometry, topology declarations, and
  Core scientific evaluator callables;
- `checkerboard_transaction.jl`: accepted tracker and relationship scratch,
  packed shadow-state settlement, and terminal transaction fragments;
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
