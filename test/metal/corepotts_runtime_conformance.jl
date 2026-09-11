include(joinpath(@__DIR__, "..", "backend_conformance", "localmath_execution.jl"))

@testset "CorePotts full checkerboard runtime on Metal" begin
    test_metal_capability_rejects_cpu_only_descriptor(Metal.MtlArray)

    vertical = run_localmath_checkerboard_vertical(
        Metal.MtlArray;
        backend_name = :metal,
    )
    @test vertical.submitted_mcs == 12
    @test vertical.committed_mcs == 12
    @test vertical.continuation_mcs == 14

    failures = run_localmath_checkerboard_failures(
        Metal.MtlArray; backend_name = :metal
    )
    @test failures.scientific_failure == :ProposalAcceptanceFailure
    @test failures.scientific_failure_commit == 0
    @test failures.provider_failure_type == :LifecycleBackendFailure
end

@testset "compiled explicit draws preserve CPU and Metal continuation" begin
    for branch in (:explicit_draw, :explicit_uniform)
        result = run_localmath_checkerboard_vertical(
            Metal.MtlArray; backend_name = :metal, mcs_count = 4, branch
        )
        @test result.committed_mcs == 4
        @test result.accepted > 0
        @test (result.constraint_rejections > 0) == (branch === :explicit_draw)
    end
end
