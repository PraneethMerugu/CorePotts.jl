using Test
import CorePotts, Metal

include("../fixtures/compiled_program_support.jl")
include("../fixtures/scheduled_draw_support.jl")
include("../fixtures/program_input_publication_support.jl")

Metal.functional() || error("the selected Metal witness is not functional")
Metal.allowscalar(false)

@testset "Metal combined program input publication" begin
    backend = CorePotts.AdaptedProgramBackend{:MetalBackend}()
    host, handles, keys = scheduled_draw_runtime(CorePotts.CheckerboardProgramEngine(); backend)
    runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
    test_program_input_publication(runtime, handles)
    restored = CorePotts.adapt_program_runtime(Metal.MtlArray,
        CorePotts.restore_program_checkpoint(runtime.program, CorePotts.program_checkpoint(runtime)))
    expected = fill(4.0f0, 6, 6)
    for completed in 1:2
        CorePotts.advance_mcs!(runtime)
        CorePotts.advance_mcs!(restored)
        @test !CorePotts.program_failed(runtime)
        @test !CorePotts.program_failed(restored)
        actual = CorePotts.program_snapshot(runtime)
        replay = CorePotts.program_snapshot(restored)
        @test actual.mcs == replay.mcs == completed
        @test actual.ownership == replay.ownership
        @test runtime.parameters == restored.parameters == Float32[3]
        for invocation in 0:2, site in eachindex(expected)
            draw = scheduled_uniform(keys[4], completed, CorePotts.SiteEntity, site;
                invocation, after_lifecycle = true)
            expected[site] = (expected[site] + draw) / 3.0f0
        end
        @test CorePotts.state_block(actual.descriptor_state, last(handles)).values ≈
            expected rtol = 4eps(Float32) atol = 0
        for handle in handles
            @test CorePotts.state_block(actual.descriptor_state, handle).values ==
                CorePotts.state_block(replay.descriptor_state, handle).values
        end
    end
end
