using Test
import CorePotts
import Metal

include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
include(joinpath(@__DIR__, "..", "fixtures", "scheduled_draw_support.jl"))

@testset "scheduled entities and substeps execute on Metal" begin
    Metal.functional() || error("scheduled draws require functional Metal")
    Metal.allowscalar(false)
    host, handles, keys = scheduled_draw_runtime(CorePotts.CheckerboardProgramEngine())
    runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
    initial = CorePotts.program_snapshot(runtime)
    expected_iterated = zeros(Float32, 6, 6)
    for mcs in 1:2
        CorePotts.advance_mcs!(runtime)
        snapshot = CorePotts.program_snapshot(runtime)
        @test !CorePotts.program_failed(runtime)
        @test snapshot.mcs == mcs
        @test snapshot.ownership == initial.ownership
        @test snapshot.cell_generations == initial.cell_generations
        @test only(CorePotts.state_block(snapshot.descriptor_state, handles[1]).values) == scheduled_uniform(keys[1], mcs, CorePotts.ModelEntity, 0)
        @test CorePotts.state_block(snapshot.descriptor_state, handles[2]).values == Float32[
            scheduled_uniform(keys[2], mcs, CorePotts.CellEntity, 1; generation = 7),
            scheduled_uniform(keys[2], mcs, CorePotts.CellEntity, 2; generation = 11), -1, -1,
        ]
        expected_sites = reshape(Float32[scheduled_uniform(keys[3], mcs, CorePotts.SiteEntity, site) for site in 1:36], 6, 6)
        @test CorePotts.state_block(snapshot.descriptor_state, handles[3]).values == expected_sites
        for invocation in 0:2, site in 1:36
            expected_iterated[site] += scheduled_uniform(keys[4], mcs, CorePotts.SiteEntity, site; invocation, after_lifecycle = true)
        end
        @test CorePotts.state_block(snapshot.descriptor_state, handles[4]).values == expected_iterated
    end

    failed_host, handles, _ = scheduled_draw_runtime(CorePotts.CheckerboardProgramEngine(); failure = true)
    failed = CorePotts.adapt_program_runtime(Metal.MtlArray, failed_host)
    before = CorePotts.program_snapshot(failed)
    CorePotts.advance_mcs!(failed)
    after = CorePotts.program_snapshot(failed)
    @test CorePotts.program_failed(failed)
    @test failed.settled
    @test after.mcs == before.mcs == 0
    @test after.ownership == before.ownership
    @test after.cell_kinds == before.cell_kinds
    @test after.cell_generations == before.cell_generations
    @test after.trackers.values == before.trackers.values
    report = CorePotts.program_failure_report(failed)
    @test report.code === CorePotts.ProgramStatusEvaluator
    @test report.detail === CorePotts.LifecycleDetailNonfiniteResult
    @test report.source == 4
    for handle in handles
        @test CorePotts.state_block(after.descriptor_state, handle).values ==
            CorePotts.state_block(before.descriptor_state, handle).values
    end
end
