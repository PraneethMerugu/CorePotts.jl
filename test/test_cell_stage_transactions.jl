isdefined(@__MODULE__, :CellStageIncrement) || include("fixtures/cell_stage_support.jl")

@testset "cell assignment conditions preserve selected writes" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        for conditions in ((true, false), (false, false), (false, true))
            runtime, handles = cell_stage_runtime(engine; same_target = true, conditions)
            CorePotts.advance_mcs!(runtime)
            snapshot = CorePotts.program_snapshot(runtime)
            @test !CorePotts.program_failed(runtime)
            @test CorePotts.state_block(snapshot.descriptor_state, handles[1]).values ==
                Float32[any(conditions) ? 2 : 1, any(conditions) ? 2 : 1, 0, 1, 1, 1]
        end
        for inactive in (false, true)
            # No eligible condition/RHS is evaluated for inactive identities;
            # active identities with a false condition must not evaluate an invalid RHS.
            conditions = inactive ? (7, 7) : (false, false)
            runtime, handles = cell_stage_runtime(engine; inactive, conditions, transform = NonfiniteCellStageValue())
            before = CorePotts.program_snapshot(runtime)
            CorePotts.advance_mcs!(runtime)
            after = CorePotts.program_snapshot(runtime)
            @test !CorePotts.program_failed(runtime)
            @test after.mcs == 1
            @test CorePotts.state_block(after.descriptor_state, handles[1]).values ==
                CorePotts.state_block(before.descriptor_state, handles[1]).values
        end
    end
end

@testset "late cell failures restore the complete MCS" begin
    rhs = OverflowingCellStageValue()(1.0f0)
    @test isfinite(rhs)
    @test !isfinite(convert(Float32, rhs))
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        for (initial_value, transform) in (
                (1.0f0, NonfiniteCellStageValue()),
                (StaticArrays.SVector(1.0f0, 3.0f0), NonfiniteCellStageValue()),
                ((; count = Int32(1), signal = StaticArrays.SVector(2.0f0, 4.0f0)), NonfiniteCellStageValue()),
                (1.0f0, OverflowingCellStageValue()),
            )
            runtime, handles = cell_stage_runtime(engine; initial_value, swap = true, after_transform = transform)
            before = CorePotts.program_snapshot(runtime)
            if engine isa CorePotts.SequentialProgramEngine
                @test_throws DomainError CorePotts.advance_mcs!(runtime)
            else
                CorePotts.advance_mcs!(runtime)
                @test CorePotts.program_failed(runtime)
            end
            after = CorePotts.program_snapshot(runtime)
            @test runtime.settled
            @test after.mcs == before.mcs == 0
            @test after.ownership == before.ownership
            @test after.cell_kinds == before.cell_kinds
            @test after.cell_generations == before.cell_generations
            @test after.trackers.values == before.trackers.values
            for handle in handles
                @test CorePotts.state_block(after.descriptor_state, handle).values ==
                    CorePotts.state_block(before.descriptor_state, handle).values
            end
            @test CorePotts.program_lifecycle_receipt(runtime) === nothing
        end
    end
end
