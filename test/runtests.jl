using ParallelTestRunner
using Test
import CorePotts

const _COREPOTTS_COMPILED_PROGRAM_TESTS = (
    "test_compiled_program_support.jl",
    "test_compiled_program_execution.jl",
    "test_compiled_program_checkerboard_oracles.jl",
    "test_compiled_program_state.jl",
    "test_compiled_program_parallel_trackers.jl",
    "test_compiled_program_relationships_checkpoint.jl",
    "test_compiled_program_extensibility_storage.jl",
)
const _COREPOTTS_DIRECT_TESTS = (
    "test_api_boundary.jl",
    "test_backend_conformance.jl",
    "test_downstream_spi.jl",
    "test_rng_contract.jl",
    "test_scientific_reference.jl",
    "test_compiled_program.jl",
    "test_surface_tracker_contract.jl",
    "test_scientific_geometry_contract.jl",
    "test_relationship_access_contract.jl",
    "test_descriptor_state_spi.jl",
    "test_acceptance.jl",
    "test_capabilities.jl",
    "test_lifecycle_selection_oracle.jl",
    "test_lifecycle_receipts.jl",
    "test_localmath_compiler_boundary.jl",
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

# These focused contract tests use the compiled-program fixture without owning
# the compiled-program aggregate. Make that dependency explicit so each entry
# remains independently runnable under ParallelTestRunner.
for name in (
    "scientific_geometry_contract",
    "descriptor_state_spi",
    "acceptance",
    "capabilities",
)
    test_file = "test_$(name).jl"
    testsuite[name] = quote
        include(joinpath(
            $(_COREPOTTS_TEST_DIRECTORY), "test_compiled_program_support.jl"
        ))
        include(joinpath($(_COREPOTTS_TEST_DIRECTORY), $test_file))
    end
end

# Lifecycle receipt tests share the complete runtime fixture used by the
# compiled-program aggregate, but remain an independently runnable test unit.
delete!(testsuite, "lifecycle_selection_oracle")
testsuite["lifecycle_receipts"] = quote
    include(joinpath(
        $(_COREPOTTS_TEST_DIRECTORY), "test_compiled_program_support.jl"
    ))
    include(joinpath(
        $(_COREPOTTS_TEST_DIRECTORY), "test_lifecycle_selection_oracle.jl"
    ))
    include(joinpath(
        $(_COREPOTTS_TEST_DIRECTORY), "test_lifecycle_receipts.jl"
    ))
end

testsuite["inventory"] = quote
    @testset "ordinary test runner owns every CorePotts test file" begin
        discovered = Set(filter(
            name -> startswith(name, "test_") && endswith(name, ".jl"),
            readdir($(_COREPOTTS_TEST_DIRECTORY)),
        ))
        included = Set((
            $(_COREPOTTS_DIRECT_TESTS)...,
            $(_COREPOTTS_COMPILED_PROGRAM_TESTS)...,
        ))
        exclusions = Set($(_COREPOTTS_TEST_HELPER_EXCLUSIONS))
        @test isempty(intersect(included, exclusions))
        @test union(included, exclusions) == discovered
    end

    @testset "CorePotts owns every device conformance witness" begin
        witness_directory = joinpath(
            $(_COREPOTTS_TEST_DIRECTORY), "backend_conformance"
        )
        discovered = Set(filter(
            name -> endswith(name, ".jl"), readdir(witness_directory)
        ))
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
            :setindex,
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
