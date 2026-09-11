using Test
import CorePotts
import Metal

include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
include(joinpath(@__DIR__, "..", "fixtures", "cell_stage_support.jl"))
include(joinpath(@__DIR__, "..", "fixtures", "cell_stage_lifecycle_support.jl"))

@testset "cell identity stages on Metal" begin
    Metal.functional() || error("cell stages require functional Metal")
    Metal.allowscalar(false)
    for initial_value in (1.0f0, StaticArrays.SVector(1.0f0, 3.0f0), (; count = Int32(1), signal = StaticArrays.SVector(2.0f0, 4.0f0)))
        for fail in (false, true)
            host, handles = cell_stage_runtime(
                CorePotts.CheckerboardProgramEngine(); initial_value, swap = true,
                after_transform = fail ? NonfiniteCellStageValue() : nothing
            )
            runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
            before = CorePotts.program_snapshot(runtime)
            CorePotts.advance_mcs!(runtime)
            after = CorePotts.program_snapshot(runtime)
            @test CorePotts.program_failed(runtime) == fail
            @test runtime.settled
            @test after.mcs == (fail ? 0 : 1)
            @test after.ownership == before.ownership
            @test after.cell_kinds == before.cell_kinds
            @test after.cell_generations == before.cell_generations
            @test after.trackers.values == before.trackers.values
            for (index, handle) in enumerate(handles)
                reference = fail ? handle : handles[3 - index]
                @test CorePotts.state_block(after.descriptor_state, handle).values[1:2] == CorePotts.state_block(before.descriptor_state, reference).values[1:2]
                @test CorePotts.state_block(after.descriptor_state, handle).values[3:6] == CorePotts.state_block(before.descriptor_state, handle).values[3:6]
            end
            if fail
                failure = CorePotts.program_failure_report(runtime)
                @test failure.code === CorePotts.ProgramStatusEvaluator
                @test failure.detail === CorePotts.LifecycleDetailNonfiniteResult
                @test failure.source == 2
                @test CorePotts.program_lifecycle_receipt(runtime) === nothing
            end
        end
    end
    for conditions in ((true, false), (false, false), (false, true))
        host, handles = cell_stage_runtime(CorePotts.CheckerboardProgramEngine(); same_target = true, conditions)
        runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
        CorePotts.advance_mcs!(runtime)
        @test !CorePotts.program_failed(runtime)
        @test CorePotts.state_block(CorePotts.program_snapshot(runtime).descriptor_state, handles[1]).values ==
            Float32[any(conditions) ? 2 : 1, any(conditions) ? 2 : 1, 0, 1, 1, 1]
    end
    for capacity in (0, 4)
        host, handles = cell_stage_runtime(CorePotts.CheckerboardProgramEngine(); empty = true, bank_capacity = capacity)
        runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
        before = CorePotts.program_snapshot(runtime)
        CorePotts.advance_mcs!(runtime)
        after = CorePotts.program_snapshot(runtime)
        @test !CorePotts.program_failed(runtime)
        @test after.mcs == 1
        @test CorePotts.state_block(after.descriptor_state, handles[1]).values == CorePotts.state_block(before.descriptor_state, handles[1]).values
    end
    host, handle = cell_stage_lifecycle_runtime(CorePotts.CheckerboardProgramEngine())
    runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
    CorePotts.advance_mcs!(runtime)
    @test !CorePotts.program_failed(runtime)
    @test CorePotts.program_snapshot(runtime).cell_kinds == Int16[2, 0]
    @test count(event -> event isa CorePotts.RemoveCellLifecycleEvent, CorePotts.program_lifecycle_receipt(runtime)) == 1
    CorePotts.advance_mcs!(runtime)
    snapshot = CorePotts.program_snapshot(runtime)
    @test !CorePotts.program_failed(runtime)
    @test snapshot.cell_kinds == Int16[2, 2]
    @test CorePotts.state_block(snapshot.descriptor_state, handle).values == Float32[5, 11, 1, 1, 1, 1]
    @test count(event -> event isa CorePotts.CreateLifecycleEvent, CorePotts.program_lifecycle_receipt(runtime)) == 1
end
