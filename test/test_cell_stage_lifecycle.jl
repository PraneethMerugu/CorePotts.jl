isdefined(@__MODULE__, :CellStageIncrement) || include("fixtures/cell_stage_support.jl")
include("fixtures/cell_stage_lifecycle_support.jl")

@testset "lifecycle state actions require their participant identities" begin
    handle = CorePotts.StateHandle(1)
    source_actions = (CorePotts.RetireToLifecycleState, CorePotts.ResetLifecycleState, CorePotts.TransformLifecycleState)
    daughter_actions = (
        CorePotts.CopyDaughtersLifecycleState, CorePotts.PreserveParentResetDaughterLifecycleState,
        CorePotts.ResetBothLifecycleState, CorePotts.SplitConservativelyLifecycleState,
        CorePotts.TransformDaughtersLifecycleState, CorePotts.RedrawDaughtersLifecycleState,
    )
    for action in (source_actions..., daughter_actions...)
        @test_throws ArgumentError cell_stage_lifecycle_plan(handle; effect = CorePotts.CreateCellLifecycleEffect, action)
    end
    for effect in (CorePotts.RemoveCellLifecycleEffect, CorePotts.RetireCellLifecycleEffect, CorePotts.TransitionCellLifecycleEffect)
        for action in (CorePotts.InitializeLifecycleState, daughter_actions...)
            @test_throws ArgumentError cell_stage_lifecycle_plan(handle; effect, action)
        end
        for action in source_actions
            @test cell_stage_lifecycle_plan(handle; effect, action) isa CorePotts.LifecycleExecutionPlan
        end
    end
    for action in daughter_actions
        @test cell_stage_lifecycle_plan(handle; effect = CorePotts.DivideCellLifecycleEffect, action) isa CorePotts.LifecycleExecutionPlan
    end
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @test_throws ArgumentError cell_stage_lifecycle_runtime(engine; birth_action = CorePotts.ResetLifecycleState)
    end
end

@testset "cell stages follow lifecycle identity publication" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            runtime, handle = cell_stage_lifecycle_runtime(engine)
            CorePotts.advance_mcs!(runtime)
            @test !CorePotts.program_failed(runtime)
            after_remove = CorePotts.program_snapshot(runtime)
            @test after_remove.cell_kinds == Int16[2, 0]
            @test CorePotts.state_block(after_remove.descriptor_state, handle).values[1] == 3.0f0
            @test count(event -> event isa CorePotts.RemoveCellLifecycleEvent, CorePotts.program_lifecycle_receipt(runtime)) == 1
            restored = CorePotts.restore_program_checkpoint(runtime.program, CorePotts.program_checkpoint(runtime))
            for current in (runtime, restored)
                CorePotts.advance_mcs!(current)
                @test !CorePotts.program_failed(current)
                after_create = CorePotts.program_snapshot(current)
                @test after_create.cell_kinds == Int16[2, 2]
                @test after_create.cell_generations[2] == after_remove.cell_generations[2] + UInt32(1)
                @test CorePotts.state_block(after_create.descriptor_state, handle).values == Float32[5, 11, 1, 1, 1, 1]
                @test count(event -> event isa CorePotts.CreateLifecycleEvent, CorePotts.program_lifecycle_receipt(current)) == 1
            end
        end
    end
end

@testset "lifecycle reset writes the existing source identity" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        runtime, handle = cell_stage_lifecycle_runtime(
            engine;
            birth_action = CorePotts.ResetLifecycleState,
            second_effect = CorePotts.TransitionCellLifecycleEffect
        )
        CorePotts.advance_mcs!(runtime)
        CorePotts.advance_mcs!(runtime)
        @test !CorePotts.program_failed(runtime)
        snapshot = CorePotts.program_snapshot(runtime)
        @test snapshot.cell_kinds == Int16[3, 0]
        @test CorePotts.state_block(snapshot.descriptor_state, handle).values == Float32[10, 1, 1, 1, 1, 1]
    end
end
