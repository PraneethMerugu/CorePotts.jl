using Test
import CorePotts
import Metal

isdefined(@__MODULE__, :test_program) || include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
isdefined(@__MODULE__, :CellStageIncrement) || include(joinpath(@__DIR__, "..", "fixtures", "cell_stage_support.jl"))
isdefined(@__MODULE__, :receipt_descriptor) || include(joinpath(@__DIR__, "..", "fixtures", "lifecycle_descriptor_support.jl"))
include(joinpath(@__DIR__, "..", "fixtures", "cell_stage_domain_support.jl"))

@testset "cell, model, and site stage transactions on Metal" begin
    Metal.functional() || error("cell domain boundaries require functional Metal")
    Metal.allowscalar(false)
    for fail in (false, true)
        host, handles = mixed_cell_stage_runtime(CorePotts.CheckerboardProgramEngine(); fail)
        runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
        before = CorePotts.program_snapshot(runtime)
        CorePotts.advance_mcs!(runtime)
        after = CorePotts.program_snapshot(runtime)
        @test CorePotts.program_failed(runtime) == fail
        @test after.mcs == (fail ? 0 : 1)
        expected = fail ? (1.0f0, 3.0f0, 5.0f0, 7.0f0) : (3.0f0, 1.0f0, 6.0f0, 8.0f0)
        for (index, handle) in enumerate(handles)
            expected_values = copy(CorePotts.state_block(before.descriptor_state, handle).values)
            if index <= 2
                expected_values[1] = expected[index]
            else
                fill!(expected_values, expected[index])
            end
            @test CorePotts.state_block(after.descriptor_state, handle).values == expected_values
        end
        @test after.ownership == before.ownership
        @test after.trackers.values == before.trackers.values
    end
end
