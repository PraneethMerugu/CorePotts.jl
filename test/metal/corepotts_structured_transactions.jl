using Test
import CorePotts
import Metal

include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
include(joinpath(@__DIR__, "..", "fixtures", "structured_stage_support.jl"))

@testset "structured model transactions on Metal" begin
    Metal.functional() || error("structured transactions require functional Metal")
    Metal.allowscalar(false)
    pairs = (
        (SVector(1.0f0, 2.0f0), SVector(3.0f0, 4.0f0)),
        (
            (active = false, count = Int32(2), polarity = SVector(1.0f0, 2.0f0)),
            (active = true, count = Int32(7), polarity = SVector(3.0f0, 4.0f0)),
        ),
    )
    for (left, right) in pairs
        @testset "$(typeof(left))" begin
            host, handles = _structured_stage_runtime(
                CorePotts.CheckerboardProgramEngine(), left, right; model_shape = (),
            )
            runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
            CorePotts.advance_mcs!(runtime)
            snapshot = CorePotts.program_snapshot(runtime)
            @test !CorePotts.program_failed(runtime)
            @test _structured_stage_values(snapshot, handles) == [right, left]
            @test all(handle -> size(CorePotts.state_block(snapshot.descriptor_state, handle).values) == (), handles)
            for nonfinite in (false, true)
                host, handles = _structured_stage_runtime(
                    CorePotts.CheckerboardProgramEngine(), left, right;
                    after_transform = nonfinite ? NonfiniteStructuredStageValue() : nothing,
                )
                runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
                before = CorePotts.program_snapshot(runtime)
                CorePotts.advance_mcs!(runtime)
                after = CorePotts.program_snapshot(runtime)
                @test CorePotts.program_failed(runtime) == nonfinite
                @test runtime.settled
                @test after.mcs == (nonfinite ? 0 : 1)
                @test _structured_stage_values(after, handles) ==
                    (nonfinite ? [left, right] : [right, left])
                @test after.ownership == before.ownership
                @test after.cell_kinds == before.cell_kinds
                @test after.cell_generations == before.cell_generations
                @test after.trackers.values == before.trackers.values
                @test _structured_stage_values(before, handles) == [left, right]
                if nonfinite
                    failure = CorePotts.program_failure_report(runtime)
                    @test failure.code === CorePotts.ProgramStatusEvaluator
                    @test failure.detail === CorePotts.LifecycleDetailNonfiniteResult
                    @test failure.source == 3
                    @test CorePotts.program_lifecycle_receipt(runtime) === nothing
                else
                    @test CorePotts.program_failure_report(runtime) === nothing
                    @test isempty(CorePotts.program_lifecycle_receipt(runtime))
                end
            end
            for conditions in ((true, false), (false, false), (false, true))
                host, handles = _structured_stage_runtime(
                    CorePotts.CheckerboardProgramEngine(), left, right;
                    same_target = true, conditions,
                )
                runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
                before = CorePotts.program_snapshot(runtime)
                CorePotts.advance_mcs!(runtime)
                after = CorePotts.program_snapshot(runtime)
                @test !CorePotts.program_failed(runtime)
                @test after.mcs == 1
                @test _structured_stage_values(after, handles) ==
                    [any(conditions) ? right : left, right]
                @test _structured_stage_values(before, handles) == [left, right]
            end
        end
    end
end
