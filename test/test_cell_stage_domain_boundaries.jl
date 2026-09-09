isdefined(@__MODULE__, :CellStageIncrement) || include("fixtures/cell_stage_support.jl")
isdefined(@__MODULE__, :receipt_descriptor) || include("fixtures/lifecycle_descriptor_support.jl")
include("fixtures/cell_stage_domain_support.jl")

@testset "cell, model, and site stages share one MCS transaction" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine()), fail in (false, true)
        runtime, handles = mixed_cell_stage_runtime(engine; fail)
        before = CorePotts.program_snapshot(runtime)
        if fail && engine isa CorePotts.SequentialProgramEngine
            @test_throws DomainError CorePotts.advance_mcs!(runtime)
        else
            CorePotts.advance_mcs!(runtime)
            @test CorePotts.program_failed(runtime) == fail
        end
        after = CorePotts.program_snapshot(runtime)
        @test runtime.settled
        @test after.mcs == (fail ? 0 : 1)
        @test after.ownership == before.ownership
        @test after.cell_kinds == before.cell_kinds
        @test after.cell_generations == before.cell_generations
        @test after.trackers.values == before.trackers.values
        expected = fail ? (1.0f0, 3.0f0, 5.0f0, 7.0f0) : (3.0f0, 1.0f0, 6.0f0, 8.0f0)
        for (index, handle) in enumerate(handles)
            values = CorePotts.state_block(after.descriptor_state, handle).values
            @test values[1] == expected[index]
            if index <= 2
                @test values[2:6] == CorePotts.state_block(before.descriptor_state, handle).values[2:6]
            else
                @test all(==(expected[index]), values)
            end
        end
    end
end

@testset "zero-occupancy identity executes before retirement but not after" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        retired = false
        for seed in UInt64(1):UInt64(128)
            runtime, handle = retiring_cell_stage_runtime(engine, seed)
            for _ in 1:8
                before = CorePotts.program_snapshot(runtime)
                CorePotts.advance_mcs!(runtime)
                after = CorePotts.program_snapshot(runtime)
                @test !CorePotts.program_failed(runtime)
                events = CorePotts.program_lifecycle_receipt(runtime)
                if any(event -> event isa CorePotts.RetireLifecycleEvent, events)
                    @test all(iszero, after.ownership)
                    @test after.cell_kinds == Int16[0]
                    @test CorePotts.state_block(after.descriptor_state, handle).values == CorePotts.state_block(before.descriptor_state, handle).values .+ 1.0f0
                    retired = true
                    break
                end
            end
            retired && break
        end
        @test retired
    end
end
