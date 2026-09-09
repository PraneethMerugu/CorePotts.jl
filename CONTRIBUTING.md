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

`src/execution/static_evaluator.jl` owns the versioned operation-callable catalog,
including immutable fixed-vector construction, indexing, and named-product field
projection by declared ordinal. Authoring compilers
validate expression shapes and indices before lowering; Core evaluates those
concrete operations through the existing expression path. The owning numerical
and inference checks are in `test/test_fixed_vector_operations.jl` and
`test/test_product_field_operations.jl`.

Compiler extensions declare scheduled effects in `src/execution/stage_plan.jl`.
Model-owned proposal reads use the existing `model_bound_state_value` operation.
`descriptor_plan.jl` validates its declared storage domain before execution;
`proposal_context.jl` selects the sole value for sequential evaluation.
`checkerboard_science.jl` gathers that same bank region through a repeated-address
relation, with bindings in `checkerboard_law.jl`. Model state is not a spatial
fold input. `test_model_state_proposal_reads.jl` exercises actionable proposal
rejection, continuation, and malformed domain declarations on both CPU engines.
Scheduled model reads reuse this validation in `_validate_stage_state_domains`
at the `CompiledPottsProgram` construction boundary in `program/types.jl`, where
the stage plan and sole descriptor state layout meet. The same owner tests
cover wrong read domains in conditions and values and wrong assignment targets.
`stage_runtime.jl` owns sequential boundary evaluation and application;
`checkerboard_stage_compiler.jl` lowers the same boundary-entry reads and
ordered publications into LocalMath plans. Its evaluation and publication
plans share the allocated scratch storage, not a second representation of
state. `storage_runtime.jl` owns logical-value zero and finiteness policies;
ownership-change paths delegate there instead of defining backend-specific
product semantics.
`checkerboard_science.jl` owns the shared parameter view; its semantic consumers
provide their execution-domain shapes without expanding parameter storage.

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

The manual executes bounded serial Wortel and Merks integration programs. The
separate Makie package and backend suites exercise rendering; the published-
model documentation does not claim to render figures or reproduce the papers.

## Continuous integration

Pull requests target the four package suites, independently runnable
integration families, applicable platform installation smokes, and the active
documentation build. Real-GPU hardware tests are manual commands when suitable
hardware is available; the hosted workflow does not currently provide Metal
hardware. Benchmarks remain diagnostic and are run when their measured path
changes.

Run real-Metal semantic tests independently from performance measurements:

```sh
julia --project=test/metal --startup-file=no test/metal/runtests.jl
```

The runner includes the active semantic, parity, lifecycle, native-component,
and extension-load witnesses; performance campaigns remain separate. Use the
repository Julia version for these commands. The root `.julia-version` and
Metal manifest select Julia 1.12.6; do not invoke the Metal environment through
a separate Julia release channel.

Current specifications and decisions live under `spec/`. Historical interviews and evidence under
`design/audits/`, and retired qualification scripts under `scripts/archive/`, document earlier
repository states but are not active development gates.
