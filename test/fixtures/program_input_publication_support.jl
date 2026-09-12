function test_program_input_publication(runtime, handles)
    before = CorePotts.program_snapshot(runtime)
    parameters_before = copy(runtime.parameters)
    candidate = CorePotts.copy_auxiliary_state(before.descriptor_state)
    for handle in handles
        fill!(CorePotts.state_block(candidate, handle).values, 7.0f0)
    end
    invalid_state = CorePotts.copy_auxiliary_state(candidate)
    CorePotts.state_block(invalid_state, last(handles)).values[end] = Inf32

    for (parameters, descriptor_state) in (
            (Float32[2], invalid_state),
            (Float32[Inf], candidate),
            (Float32[2, 3], candidate),
        )
        @test_throws ArgumentError CorePotts.update_program_inputs!(
            runtime; parameters, descriptor_state,
        )
        after = CorePotts.program_snapshot(runtime)
        @test runtime.parameters == parameters_before
        @test after.mcs == before.mcs
        @test after.ownership == before.ownership
        @test after.cell_kinds == before.cell_kinds
        @test after.cell_generations == before.cell_generations
        @test after.trackers.values == before.trackers.values
        @test !CorePotts.program_failed(runtime)
        for handle in handles
            @test CorePotts.state_block(after.descriptor_state, handle).values ==
                CorePotts.state_block(before.descriptor_state, handle).values
        end
    end

    parameters = Float32[2]
    @test CorePotts.update_program_inputs!(runtime; parameters, descriptor_state = candidate) === runtime
    @test CorePotts.update_program_inputs!(runtime) === runtime
    # Caller-owned candidates must not become published storage.
    parameters[1] = 9.0f0
    for handle in handles
        fill!(CorePotts.state_block(candidate, handle).values, -9.0f0)
    end
    published = CorePotts.program_snapshot(runtime)
    @test runtime.parameters == Float32[2]
    @test published.mcs == 0
    for handle in handles
        @test all(==(7.0f0), CorePotts.state_block(published.descriptor_state, handle).values)
        @test CorePotts.state_block(before.descriptor_state, handle).values !=
            CorePotts.state_block(published.descriptor_state, handle).values
    end

    @test CorePotts.update_program_inputs!(runtime; parameters = Float32[3]) === runtime
    after_parameters = CorePotts.program_snapshot(runtime)
    for handle in handles
        @test CorePotts.state_block(after_parameters.descriptor_state, handle).values ==
            CorePotts.state_block(published.descriptor_state, handle).values
    end
    state_only = CorePotts.copy_auxiliary_state(published.descriptor_state)
    fill!(CorePotts.state_block(state_only, last(handles)).values, 4.0f0)
    @test CorePotts.update_program_inputs!(runtime; descriptor_state = state_only) === runtime
    @test runtime.parameters == Float32[3]
    after_state = CorePotts.program_snapshot(runtime)
    for handle in handles
        expected = handle == last(handles) ? 4.0f0 : 7.0f0
        @test all(==(expected), CorePotts.state_block(after_state.descriptor_state, handle).values)
    end

    return nothing
end
