# [CorePotts API](@id corepotts-api)

Most users should author with Potts. CorePotts intentionally exposes a
narrow MTK-free runtime boundary:

- `ProgramInitialState`, `ProgramRuntime`, `ProgramSnapshot`;
- `initialize_program`, `advance_mcs!`, `program_snapshot`;
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
