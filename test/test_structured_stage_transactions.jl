include(joinpath(@__DIR__, "fixtures", "structured_stage_support.jl"))

@testset "logical model-state assignments preserve transaction boundaries" begin
    pairs = (
        (1.0f0, 3.0f0),
        (SVector(1.0f0, 2.0f0), SVector(3.0f0, 4.0f0)),
        (
            (active = false, count = Int32(2), polarity = SVector(1.0f0, 2.0f0)),
            (active = true, count = Int32(7), polarity = SVector(3.0f0, 4.0f0)),
        ),
    )
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            for (left, right) in pairs
                @testset "$(typeof(left))" begin
                    @testset "same-boundary assignments swap from one snapshot" begin
                        runtime, handles = _structured_stage_runtime(engine, left, right)
                        CorePotts.advance_mcs!(runtime)
                        @test !CorePotts.program_failed(runtime)
                        snapshot = CorePotts.program_snapshot(runtime)
                        @test snapshot.mcs == 1
                        @test _structured_stage_values(snapshot, handles) == [right, left]
                    end
                    @testset "before and after lifecycle assignments are ordered" begin
                        runtime, handles = _structured_stage_runtime(engine, left, right; ordered = true)
                        CorePotts.advance_mcs!(runtime)
                        @test !CorePotts.program_failed(runtime)
                        snapshot = CorePotts.program_snapshot(runtime)
                        @test snapshot.mcs == 1
                        @test _structured_stage_values(snapshot, handles) == [right, right]
                    end
                    @testset "zero-dimensional model state preserves logical shape" begin
                        runtime, handles = _structured_stage_runtime(engine, left, right; model_shape = ())
                        CorePotts.advance_mcs!(runtime)
                        snapshot = CorePotts.program_snapshot(runtime)
                        @test !CorePotts.program_failed(runtime)
                        @test _structured_stage_values(snapshot, handles) == [right, left]
                        @test all(handle -> size(CorePotts.state_block(snapshot.descriptor_state, handle).values) == (), handles)
                        restored = CorePotts.restore_program_checkpoint(
                            runtime.program, CorePotts.program_checkpoint(runtime),
                        )
                        restored_snapshot = CorePotts.program_snapshot(restored)
                        @test _structured_stage_values(restored_snapshot, handles) == [right, left]
                        @test all(handle -> size(CorePotts.state_block(restored_snapshot.descriptor_state, handle).values) == (), handles)
                    end
                    @testset "disabled model assignments do not undo enabled writes" begin
                        for conditions in ((true, false), (false, false), (false, true))
                            runtime, handles = _structured_stage_runtime(
                                engine, left, right; same_target = true, conditions,
                            )
                            CorePotts.advance_mcs!(runtime)
                            snapshot = CorePotts.program_snapshot(runtime)
                            @test !CorePotts.program_failed(runtime)
                            @test snapshot.mcs == 1
                            @test _structured_stage_values(snapshot, handles) ==
                                [any(conditions) ? right : left, right]
                        end
                    end
                    @testset "late nonfinite output restores every published value" begin
                        runtime, handles = _structured_stage_runtime(
                            engine, left, right; after_transform = NonfiniteStructuredStageValue(),
                        )
                        before = CorePotts.program_snapshot(runtime)
                        # A valid before-lifecycle swap precedes this failure.
                        # The externally published MCS must retain its entry state.
                        if engine isa CorePotts.SequentialProgramEngine
                            @test_throws DomainError CorePotts.advance_mcs!(runtime)
                        else
                            CorePotts.advance_mcs!(runtime)
                            @test CorePotts.program_failed(runtime)
                        end
                        @test runtime.settled
                        after = CorePotts.program_snapshot(runtime)
                        @test after.mcs == before.mcs == 0
                        @test _structured_stage_values(after, handles) == [left, right]
                        @test after.ownership == before.ownership
                        @test after.cell_kinds == before.cell_kinds
                        @test after.cell_generations == before.cell_generations
                        @test after.trackers.values == before.trackers.values
                        @test CorePotts.program_lifecycle_receipt(runtime) === nothing
                    end
                end
            end
        end
    end
end

@testset "finite model RHS overflowing its target type rolls back" begin
    rhs = OverflowingModelStageValue()(1.0f0)
    @test isfinite(rhs)
    @test !isfinite(convert(Float32, rhs))
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        runtime, handles = _structured_stage_runtime(
            engine, 1.0f0, 3.0f0; after_transform = OverflowingModelStageValue(),
        )
        before = CorePotts.program_snapshot(runtime)
        if engine isa CorePotts.SequentialProgramEngine
            @test_throws DomainError CorePotts.advance_mcs!(runtime)
        else
            CorePotts.advance_mcs!(runtime)
            @test CorePotts.program_failed(runtime)
        end
        @test runtime.settled
        after = CorePotts.program_snapshot(runtime)
        @test after.mcs == before.mcs == 0
        @test _structured_stage_values(after, handles) == [1.0f0, 3.0f0]
        @test after.ownership == before.ownership
        @test after.cell_kinds == before.cell_kinds
        @test after.cell_generations == before.cell_generations
        @test after.trackers.values == before.trackers.values
        @test CorePotts.program_lifecycle_receipt(runtime) === nothing
    end
end
