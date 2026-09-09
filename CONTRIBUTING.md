# Contributing

CorePotts.jl follows the ordinary Julia package workflow. Julia 1.12 or a later
Julia 1.x release is required.

## Semantic names and direct cutovers

Internal phases, gates, and review checkpoints may organize development, but
they are not supported product states. Live identifiers, errors, configuration,
serialized fields, extensions, and current documentation must name durable
scientific, mathematical, numerical, hardware, protocol, ownership, or
execution meaning rather than when an implementation was developed.

Replace temporary names and representations directly across source, tests,
documentation, examples, and downstream packages. Delete the replaced name in
the same edit; do not add forwarding aliases, deprecated spellings, old/new
selectors, feature flags, or parallel migration implementations. Breaking
renames use ordinary package versioning.

Classify names by meaning, not by a word blacklist. Scientific phases,
mathematical/compiler candidates, genuine algorithm and backend choices,
checkpoint/import behavior, independent test oracles, and durable protocol or
schema versions are valid product concepts. Historical milestone terminology
may remain in specifications, design records, audits, and archived evidence.

Use ordinary package tests, integration tests, documentation builds, Aqua,
ExplicitImports, and relevant GPU witnesses to validate a cutover. Do not add a
custom policy gate script; review establishes that the surviving name has
durable meaning and normal tests establish behavioral preservation.

No evidence hashes, milestone scripts, frozen pass/fail timing gates, or
committee paperwork are part of development. Reviews are ordinary technical
reviews. Focused benchmarks remain valuable for investigation and reproducible
performance claims, but machine-dependent timing observations do not become
brittle acceptance thresholds. Historical specifications, audits, and evidence
may record earlier processes without making them current contributor workflow.

## Prevent development debt

Keep one production authority for each fact. Scientific meaning belongs to its
domain package, spatial and publication meaning belongs to LocalMath, and
physical execution belongs to the shared KernelAbstractions path. Inspection
and diagnostics project those authorities rather than storing parallel evidence.

New abstractions must delete an existing authority or demonstrate reuse by real
consumers. Keep exploratory runtimes and compiler prototypes outside production
source. Once an approach qualifies, move it into the sole production path and
delete the prototype in the same edit. Downstream packages must use public APIs;
private structures are contracts only inside their owning package.

Tests should assert observable behavior: scientific results, deterministic and
ordered semantics, failure atomicity, checkpoint continuation, ownership,
allocation, compilation behavior, and CPU/GPU parity where applicable. Avoid
assertions about milestone labels, arbitrary device ordinals, evidence metadata,
implementation slogans, or incidental struct layout. When an independent
scientific oracle is useful, keep one oracle and one production implementation;
the oracle must not become another executor.

Treat functional support and stronger guarantees independently. Exact replay,
checkpoint portability, deterministic conflict resolution, and performance each
need evidence that directly exercises that claim. Ordinary compatibility
environments remain broad; pin a complete dependency environment only for a
guarantee that genuinely depends on exact dependency replay.

Before handing off a change, check:

1. Did it create another semantic authority or execution path?
2. Did development chronology enter a live identifier or schema?
3. Does a test assert an incidental implementation detail?
4. Does a downstream package reach through another package's private API?
5. Did a replaced name, representation, or implementation remain active?
6. Do CPU and GPU still use the same semantic KernelAbstractions path?
7. Is every claimed guarantee exercised by the appropriate ordinary test or
   reproducible benchmark?

Resolve any affirmative answer as part of the same change.

## Scheduled publication ownership

Scheduled randomness follows the existing `:draw` operation into
`execution/program_rng.jl`'s immutable invocation context and then
`rng/semantic.jl`'s shared addressed distribution transform. Proposal and
lifecycle consumers use that same transform; each execution context supplies
its own scientific address. `stage_runtime.jl` selects host identity and
generation, while `checkerboard_stage_compiler.jl` builds concrete gathered
contexts from the existing kind/generation reads. Its shared submission schema
and `checkerboard_queue.jl` carry the actual MCS and zero-based substep, never a
launch counter. The owning coordinate and numerical witnesses are
`test_scheduled_process_draws.jl` and `fixtures/scheduled_draw_support.jl`.

`src/execution/static_evaluator.jl` owns the versioned operation-callable catalog,
including immutable fixed-vector construction, indexing, named-product field
projection by declared ordinal, and standard sine/cosine numerical callables.
`test_trigonometric_operations.jl` defends their concrete expression inference.
Authoring compilers validate dimensions, expression shapes, and indices before
lowering; Core evaluates those
concrete operations through the existing expression path. The owning numerical
and inference checks are in `test/test_fixed_vector_operations.jl` and
`test/test_product_field_operations.jl`.

Compiler extensions declare scheduled effects in `src/execution/stage_plan.jl`.
Model-owned proposal reads use the existing `model_bound_state_value` operation.
`descriptor_plan.jl` validates intrinsic source and descriptor contracts. Complete
program assembly in `program/types.jl` validates proposal, parameter-constraint,
and stage read domains against the actual stage plan and sole state layout;
`proposal_context.jl` selects the sole value for sequential evaluation.
`checkerboard_science.jl` gathers that same bank region through a repeated-address
relation, with bindings in `checkerboard_law.jl`. Model state is not a spatial
fold input. `test_model_state_proposal_reads.jl` exercises actionable proposal
rejection, continuation, and malformed domain declarations on both CPU engines.
History sample reads use `history_sample_handle` and `state_read_source` in
`stage_plan.jl`: the unique shift-append effect proves the source domain and
whole-sample projection. These read views do not create layout entries and are
never valid write targets. Assignment, ownership-change, and lifecycle targets
continue to require exact canonical layout identity. The same owner tests
cover wrong read domains in conditions and values and wrong assignment targets.
Cell history lifecycle rules retain the full canonical target. Complete-program
admission proves its sampled source is cell-owned; `lifecycle_commit_state.jl`
applies the existing state-policy body to each dense sample. The canonical
`lifecycle_occurrence` in `lifecycle_context.jl` identifies the retained lag;
Before reads the immutable bank and Planned reads the request-local candidate.
`test_history_lifecycle.jl` defends corresponding-sample reads, real identity,
and late-sample rollback alongside ordinary cell-state behavior.
Site-history ownership changes use the same canonical source proof. Sequential
copy and lifecycle publication share `_clear_site_samples!`; the checkerboard
accepted-copy law compares live ownership with its existing candidate ownership
and publishes every dense sample through a degree-one source-site relation.
Its history shadows use the same transaction gate and commit order as ordinary
state. `test_history_ownership_change.jl` covers accepted/rejected copies,
unequal proposal batches, all retained samples, and failure rollback.
The ordinary and Metal runners share the scientific oracles in
`test/fixtures/history_ownership_support.jl` and `history_sample_support.jl`.
The latter preserves explicit prehistory at initialization and exercises two-lag
feedback with checkpoint continuation. Device continuation declares its provider
in the compiled program before initialization; restoring then adapting that same
program preserves the existing exact execution-identity checks.
`stage_runtime.jl` owns sequential boundary evaluation and application;
`checkerboard_stage_compiler.jl` lowers the same boundary-entry reads and
ordered publications into LocalMath plans. Its evaluation and publication
plans share the allocated scratch storage, not a second representation of
state. `storage_runtime.jl` owns logical-value zero and finiteness policies;
ownership-change paths delegate there instead of defining backend-specific
product semantics.
`checkerboard_science.jl` owns the shared parameter view; its semantic consumers
provide their execution-domain shapes without expanding parameter storage.
Cell effects use the same boundary emission/application transaction and the
same identity-domain publication builder as singleton model effects. Their
distinct evaluation context reads finite-cell slots, not lattice sites.
The cell-domain validator derives expression requirements using the sole
walker in `static_evaluator.jl`; the descriptor's kind and the runtime
kind/generation tables remain the eligibility authorities.
Extra allocated state capacity is bound as a view over the same storage, not
another identity registry. `test_cell_stage_execution.jl` owns once-per-cell,
inactive-slot, structured-value, and capacity behavior.
`test_cell_stage_transactions.jl` covers conditions and failure rollback;
`test_cell_stage_lifecycle.jl` covers removal, generation reuse, and continuation;
`test_cell_stage_domain_boundaries.jl` covers mixed-domain publication and
retirement after the final-site copy. Shared fixtures also feed the ordinary
Metal inventory. `test_empty_logical_storage.jl` defends zero-length bank regions,
whose allocation and copying remain owned by `storage_runtime.jl`.
The `CompiledPottsProgram` constructor joins the stage plan with the existing
state layout in `_validate_stage_state_domains`: target/read ownership,
declared read resources, and finite-cell kind validity are checked there.
Runtime materialization checks only coverage of the realized cell capacity.
Checkerboard preparation threads that same layout into the existing site and
identity assignment laws. Both reuse a degree-one model read relation and bank
view binding; model values are neither copied per cell nor published early.

Lifecycle value conversion remains owned by `lifecycle_commit_state.jl`;
`test_lifecycle_value_conversion.jl` and its Metal counterpart cover heterogeneous
evaluator banks, legitimate scalar/vector conversions and equal-length reshapes,
and incompatible-value or length rollback through the same lifecycle transaction.
`test_lifecycle_numeric_conversion.jl` covers integer/Boolean exactness, range,
signed zero and subnormal behavior for scalar and fixed-vector values.
`test_lifecycle_integer_conversion_bounds.jl` compares boundary admission with
ordinary Julia conversion; its Metal counterpart also exercises the owning
predicate directly. A primitive conversion check is not a state-bank support
claim: Int8 and Int64 banks are currently outside checkerboard admission.

The ordinary behavioral tests are `test_structured_stage_transactions.jl`
(simultaneous assignments, ordered history and substeps, failure rollback),
`test_site_assignment_conversion.jl` (target conversion and overflow rollback),
`test_stage_relationship_snapshot.jl` (relationship requests share entry state),
and `test_logical_ownership_change.jl` (accepted copies clear only changed site
values and preserve logical checkpoint state). Keep device-specific witnesses
in the ordinary Metal inventory, and distinguish tested device behavior from
CPU-only coverage.

## Test

During development, start with the smallest self-contained test file that owns
the changed behavior. For example, a focused root check can load the shared
setup explicitly:

```sh
julia --project=. --startup-file=no -e 'using Test; import CorePotts, LocalMath; include("test/fixtures/compiled_program_support.jl"); include("test/test_acceptance.jl")'
```

Focused commands shorten the edit loop; they are not a second test inventory
or release gate. Before handoff, run the complete suite of every changed
package. Add the integration suite when a package boundary, extension, SciML
lifecycle, or persistence behavior changed; add the strict documentation build
when a public name, docstring, example, or manual page changed. Applicable
real-GPU tests are required when device execution, adaptation, admission, or
lifetime changed.

Run the package suite from the repository root:

```sh
julia --project=. -e 'using Pkg; Pkg.test()'
```

Build documentation with:

```sh
julia --project=docs docs/make.jl
```

Run the lifecycle compiler flagship from its ordinary benchmark environment.
For local cross-package development, develop the package checkout and a
compatible LocalMath checkout temporarily; neither path is recorded in the
repository:

```sh
julia --project=benchmark -e 'using Pkg; Pkg.develop([Pkg.PackageSpec(path="."), Pkg.PackageSpec(path=ARGS[1])]); Pkg.instantiate()' /absolute/path/to/LocalMath.jl
julia --project=benchmark --startup-file=no benchmark/compiler_scaling/corepotts_flagship.jl --warm-samples=7
```

The report records cold preparation, first execution compilation, warm
allocation and compilation observations, and physical launch structure. These
measurements are engineering evidence rather than pass/fail timing gates. The
fixture exercises empty lifecycle selection after resetting the workspace; it
does not represent populated divide/retire throughput.

The package suite includes Aqua and ExplicitImports checks. Real-Metal
qualification lives in `test/metal` and uses Julia 1.12.6.

## Format Julia changes

This repository adopts [Runic](https://github.com/fredrikekre/Runic.jl) for
new and modified Julia code. During incremental adoption, check only the files
you touched; do not mechanically reformat the repository as part of an
unrelated change. With Runic 1 installed as a Julia app, check explicit files
without modifying them:

```sh
runic --check --diff path/to/file.jl another/file.jl
```

Use `runic --inplace` on those same explicit paths to apply formatting. A
future dedicated baseline commit may extend the check to all tracked Julia
files.

## Build the documentation

The manual uses a strict Documenter build: doctest, executable-example, and
cross-reference failures fail the command.

```sh
julia --project=docs -e 'using Pkg; Pkg.instantiate()'
julia --project=docs docs/make.jl
```

The manual documents CorePotts scientific execution and extension contracts.
Complete biological models belong to PottsModels; visualization belongs to
MakiePotts. Package and backend suites defend CorePotts behavior independently.

## Continuous integration

Pull requests run the full owning package suite, macOS API smoke and strict
documentation build. The hosted `macos-15` Metal job runs unless the whole PR
diff consists only of explicitly listed non-executable prose/metadata paths.
Source, tests, executable docs, examples, dependency/workflow changes and unknown
paths retain device checks. Main and manual runs also run Metal and the full
macOS package suite. The Metal runner rejects unavailable hardware.

CI uses an explicit LocalMath revision by default; manual dispatch can select
a candidate revision. Every test job logs its actual checkout tuple. Ordinary
compatibility ranges remain broad and these runs do not claim an exact-replay
dependency profile. Benchmarks remain diagnostic and run when their measured
path changes.

Run real-Metal semantic tests independently from performance measurements:

```sh
julia --project=test/metal --startup-file=no test/metal/runtests.jl
```

The runner owns CorePotts feasibility, stage-boundary and runtime-conformance
witnesses; performance campaigns remain separate. Use Julia 1.12.6 for this
Metal profile. Ordinary environments do not commit a complete dependency
manifest or imply an exact-replay guarantee.

Current specifications and decisions live under `spec/`. Historical interviews and evidence under
`design/audits/`, and retired qualification scripts under `scripts/archive/`, document earlier
repository states but are not active development gates.
