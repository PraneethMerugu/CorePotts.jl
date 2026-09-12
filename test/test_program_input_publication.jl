isdefined(@__MODULE__, :test_program_input_publication) || include("fixtures/program_input_publication_support.jl")
isdefined(@__MODULE__, :scheduled_draw_runtime) || include("fixtures/scheduled_draw_support.jl")

@testset "combined program inputs validate before publication" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            runtime, handles, keys = scheduled_draw_runtime(engine)
            test_program_input_publication(runtime, handles)

            restored = CorePotts.restore_program_checkpoint(runtime.program, CorePotts.program_checkpoint(runtime))
            expected_iterated = fill(4.0f0, 6, 6)
            # Two steps exercise alternating execution banks as well as restart.
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
                for invocation in 0:2, site in eachindex(expected_iterated)
                    draw = scheduled_uniform(keys[4], completed, CorePotts.SiteEntity, site;
                        invocation, after_lifecycle = true)
                    expected_iterated[site] = (expected_iterated[site] + draw) / 3.0f0
                end
                @test CorePotts.state_block(actual.descriptor_state, last(handles)).values ≈
                    expected_iterated rtol = 4eps(Float32) atol = 0
                for handle in handles
                    @test CorePotts.state_block(actual.descriptor_state, handle).values ==
                        CorePotts.state_block(replay.descriptor_state, handle).values
                end
            end
        end
    end
end
