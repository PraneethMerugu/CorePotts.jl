using ParallelTestRunner
using Test
import CorePotts

const _COREPOTTS_COMPILED_PROGRAM_TESTS = (
    "test_compiled_program_execution.jl",
    "test_compiled_program_checkerboard_oracles.jl",
    "test_compiled_program_state.jl",
    "test_compiled_program_parallel_trackers.jl",
    "test_compiled_program_relationships_checkpoint.jl",
    "test_compiled_program_extensibility_storage.jl",
)
const _COREPOTTS_DIRECT_TESTS = (
    "test_program_adaptation.jl",
    "test_api_boundary.jl",
    "test_backend_conformance.jl",
    "test_downstream_spi.jl",
    "test_rng_contract.jl",
    "test_rng_operations.jl",
    "test_rng_program_continuation.jl",
    "test_scheduled_process_draws.jl",
    "test_scientific_reference.jl",
    "test_surface_tracker_contract.jl",
    "test_scientific_geometry_contract.jl",
    "test_relationship_access_contract.jl",
    "test_descriptor_state_spi.jl",
    "test_program_input_publication.jl",
    "test_program_step_inputs.jl",
    "test_source_aware_trackers.jl",
    "test_logical_state_values.jl",
    "test_history_sample_storage.jl",
    "test_history_lifecycle.jl",
    "test_history_ownership_change.jl",
    "test_completed_mcs_cadence.jl",
    "test_model_state_proposal_reads.jl",
    "test_model_state_energy.jl",
    "test_empty_logical_storage.jl",
    "test_cell_stage_execution.jl",
    "test_stage_anchor_contexts.jl",
    "test_cell_stage_lifecycle.jl",
    "test_cell_stage_transactions.jl",
    "test_cell_stage_domain_boundaries.jl",
    "test_logical_state_lifecycle.jl",
    "test_lifecycle_value_conversion.jl",
    "test_lifecycle_numeric_conversion.jl",
    "test_lifecycle_integer_conversion_bounds.jl",
    "test_logical_ownership_change.jl",
    "test_structured_stage_transactions.jl",
    "test_site_assignment_conversion.jl",
    "test_stage_relationship_snapshot.jl",
    "test_acceptance.jl",
    "test_capabilities.jl",
    "test_lifecycle_selection_decisions.jl",
    "test_lifecycle_receipts.jl",
    "test_localmath_compiler_boundary.jl",
    "test_fixed_vector_operations.jl",
    "test_trigonometric_operations.jl",
    "test_product_field_operations.jl",
    "test_checkerboard_read_groups.jl",
    "test_compiler_flagship_benchmark.jl",
)
const _COREPOTTS_TEST_HELPER_EXCLUSIONS = ()
const _COREPOTTS_DEVICE_CONFORMANCE_WITNESSES = (
    "localmath_execution.jl",
)

const _COREPOTTS_TEST_DIRECTORY = @__DIR__

testsuite = Dict{String, Expr}(
    replace(file, r"^test_|\.jl$" => "") =>
        :(include(joinpath($(_COREPOTTS_TEST_DIRECTORY), $file)))
        for file in _COREPOTTS_DIRECT_TESTS
)

for file in _COREPOTTS_COMPILED_PROGRAM_TESTS
    name = replace(file, r"^test_|\.jl$" => "")
    testsuite[name] =
        :(include(joinpath($(_COREPOTTS_TEST_DIRECTORY), $file)))
end

testsuite["inventory"] = quote
    @testset "ordinary test runner owns every CorePotts test file" begin
        discovered = Set(
            filter(
                name -> startswith(name, "test_") && endswith(name, ".jl"),
                readdir($(_COREPOTTS_TEST_DIRECTORY)),
            )
        )
        included = Set(
            (
                $(_COREPOTTS_DIRECT_TESTS)...,
                $(_COREPOTTS_COMPILED_PROGRAM_TESTS)...,
            )
        )
        exclusions = Set($(_COREPOTTS_TEST_HELPER_EXCLUSIONS))
        @test isempty(intersect(included, exclusions))
        @test union(included, exclusions) == discovered
    end

    @testset "CorePotts owns every device conformance witness" begin
        witness_directory = joinpath(
            $(_COREPOTTS_TEST_DIRECTORY), "backend_conformance"
        )
        discovered = Set(
            filter(
                name -> endswith(name, ".jl"), readdir(witness_directory)
            )
        )
        @test discovered == Set($(_COREPOTTS_DEVICE_CONFORMANCE_WITNESSES))
    end
end

testsuite["package_quality"] = quote
    using Aqua
    using ExplicitImports

    @testset "CorePotts package quality" begin
        # Aqua's persistent-task subprocess resolves only the standalone project.
        # Re-enable that subtest after LocalMath is available from the General
        # registry; the ordinary package runner still exercises task and
        # precompilation behavior through the developed upstream checkout.
        Aqua.test_all(
            CorePotts; ambiguities = false, persistent_tasks = false
        )
        # Exact non-public dependencies support device adaptation, atomic
        # arbitration, world-age checks, and storage alias checks. LocalMath
        # consumers use only its declared public compiler surface.
        qualified_internal_boundary = (
            Symbol("@adapt_structure"),
            Symbol("@atomic"),
            :dataids,
            :device,
            :GIT_VERSION_INFO,
            :JLOptions,
            :foreachindex,
            :get_world_counter,
            :invoke_in_world,
            :libllvm_version,
            :mightalias,
            :ones,
            :setindex,
            :zeros,
        )
        ExplicitImports.test_explicit_imports(
            CorePotts;
            all_qualified_accesses_are_public =
                (; ignore = qualified_internal_boundary),
        )
        ambiguities = Test.detect_ambiguities(CorePotts, Base; recursive = true)
        owned = filter(ambiguities) do pair
            any(method -> method.module === CorePotts, pair)
        end
        @test isempty(owned)
    end
end

init_code = quote
    import CorePotts
    import LocalMath
    include(
        joinpath(
            $(_COREPOTTS_TEST_DIRECTORY), "fixtures", "compiled_program_support.jl"
        )
    )
    include(
        joinpath(
            $(_COREPOTTS_TEST_DIRECTORY), "fixtures", "lifecycle_selection_oracle.jl"
        )
    )
    const _COREPOTTS_COMPILED_PROGRAM_TESTS =
        $(_COREPOTTS_COMPILED_PROGRAM_TESTS)
end

ParallelTestRunner.runtests(
    CorePotts,
    ARGS;
    testsuite,
    init_code,
    serial = ["inventory", "package_quality"],
)
