include(joinpath(@__DIR__, "backend_conformance", "localmath_execution.jl"))

@testset "full checkerboard runtime conformance on CPU" begin
    success = run_localmath_checkerboard_vertical(
        identity;
        backend_name = :cpu,
        mcs_count = 1,
    )
    @test success.submitted_mcs == 1
    @test success.committed_mcs == 1
    @test success.continuation_mcs == 3

    failure = run_localmath_checkerboard_failures(
        identity;
        backend_name = :cpu,
        mcs_count = 1,
        require_provider_failure = false,
    )
    @test failure.scientific_failure == :ProposalAcceptanceFailure
    @test failure.scientific_failure_commit == 0
end
