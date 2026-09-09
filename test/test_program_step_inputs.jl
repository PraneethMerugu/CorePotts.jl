isdefined(@__MODULE__, :test_program) || include("fixtures/compiled_program_support.jl")
isdefined(@__MODULE__, :site_sum_runtime) || include("fixtures/site_sum_support.jl")
import LocalMath

@testset "staged inputs survive alternating commits and aborts: $(nameof(typeof(engine)))" for engine in (
        CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine(),
    )
    C = CorePotts
    runtime, handle, key = site_sum_runtime(engine)
    for (iteration, gain) in enumerate(Float32[3, 4, 5, 6])
        before = C.program_snapshot(runtime)
        previous_parameters = copy(runtime.parameters)
        aborted = C.stage_program_mcs!(runtime)
        staged = C.copy_auxiliary_state(C.program_step_snapshot(aborted).descriptor_state)
        fill!(C.state_block(staged, handle).values, 3.0f0)
        C.stage_program_descriptor_state!(aborted, staged)
        C.stage_program_parameters!(aborted, Float32[99])
        C.prevalidate_program_step_transaction(aborted)
        @test runtime.parameters == previous_parameters
        @test runtime.ownership == before.ownership
        @test runtime.cell_kinds == before.cell_kinds
        @test runtime.cell_generations == before.cell_generations
        @test runtime.trackers.values == before.trackers.values
        @test C.state_block(runtime.descriptor_state, handle).values == C.state_block(before.descriptor_state, handle).values
        C.abort_program_step!(aborted)
        after_abort = C.program_snapshot(runtime)
        @test after_abort.mcs == before.mcs
        @test after_abort.ownership == before.ownership
        @test after_abort.trackers.values == before.trackers.values
        @test C.state_block(after_abort.descriptor_state, handle).values == C.state_block(before.descriptor_state, handle).values
        @test runtime.parameters == previous_parameters
        transaction = C.stage_program_mcs!(runtime)
        C.stage_program_parameters!(transaction, Float32[gain])
        candidate = C.program_step_snapshot(transaction)
        @test runtime.parameters == previous_parameters
        signal = C.state_block(candidate.descriptor_state, handle).values
        expected = site_sum_oracle(candidate.ownership, signal, gain, 3)
        @test C.program_tracker_values(runtime.program, candidate, key) == expected
        C.commit_program_step!(transaction)
        @test runtime.parameters == Float32[gain]
        @test C.program_tracker_values(runtime, key) == expected
        iseven(iteration) && C.advance_mcs!(runtime)
        published = C.program_snapshot(runtime)
        @test published.mcs == before.mcs + 1 + iseven(iteration)
        @test runtime.parameters == Float32[gain]
        @test C.program_tracker_values(runtime, key) == site_sum_oracle(
            published.ownership, C.state_block(published.descriptor_state, handle).values, gain, 3
        )
    end
end

@testset "no-input transactions retain incremental rounding" begin
    C = CorePotts
    small = 2.0f0^-25
    signal = zeros(Float32, 6, 6)
    signal[1] = 1.0f0
    signal[2] = small
    equal(name, value) = C.OperationExpression(
        ==,
        C.OperationExpression(C.operation_callable(Val(name), v"1.0.0")), C.LiteralExpression(value)
    )
    constraint = C.OperationExpression(&, equal(:source_cell, Int32(2)), equal(:target_cell, Int32(1)))
    runtime, handle, key = site_sum_runtime(
        C.SequentialProgramEngine();
        gain = 1.0f0, signal, absolute_tolerance = small, constraint
    )
    @test C._attempt_selected!(runtime, CartesianIndex(3, 1), CartesianIndex(1, 1), 1, 1, Val(:scripted), 0.5f0)
    @test C.program_tracker_value(runtime, key, 1) == 0.0f0
    @test site_sum_oracle(runtime.ownership, signal, 1.0f0, 3)[1] == small
    before = C.program_snapshot(runtime)
    transaction = C.stage_program_mcs!(runtime)
    for _ in 1:2
        C.prevalidate_program_step_transaction(transaction)
        candidate = C.program_step_snapshot(transaction)
        @test candidate.ownership == before.ownership
        @test C.program_tracker_values(runtime.program, candidate, key)[1] == 0.0f0
    end
    C.commit_program_step!(transaction)
    @test C.program_tracker_value(runtime, key, 1) == 0.0f0
    @test C.program_snapshot(runtime).mcs == 1
end

@testset "staged program inputs share one derived-state publication: $(nameof(typeof(engine)))" for engine in (
        CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine(),
    )
    C = CorePotts
    for mode in (:parameters, :state, :combined)
        runtime, handle, key = site_sum_runtime(engine)
        before = C.program_snapshot(runtime)
        transaction = C.stage_program_mcs!(runtime)
        entry = C.program_step_snapshot(transaction)
        state = C.copy_auxiliary_state(entry.descriptor_state)
        fill!(C.state_block(state, handle).values, 3.0f0)
        mode !== :parameters && C.stage_program_descriptor_state!(transaction, state)
        mode !== :state && C.stage_program_parameters!(transaction, Float32[4])
        candidate = C.program_step_snapshot(transaction)
        gain = mode === :state ? 2.0f0 : 4.0f0
        signal = C.state_block(candidate.descriptor_state, handle).values
        expected = site_sum_oracle(candidate.ownership, signal, gain, 3)
        @test C.program_tracker_values(runtime.program, candidate, key) == expected
        C.prevalidate_program_step_transaction(transaction)
        again = C.program_step_snapshot(transaction)
        @test again.trackers.values == candidate.trackers.values
        @test runtime.parameters == Float32[2]
        @test runtime.ownership == before.ownership
        fill!(C.state_block(candidate.descriptor_state, handle).values, -99.0f0)
        preserved = C.state_block(C.program_step_snapshot(transaction).descriptor_state, handle).values
        @test all(==(mode === :parameters ? 1.0f0 : 3.0f0), preserved)
        C.commit_program_step!(transaction)
        published = C.program_snapshot(runtime)
        @test published.mcs == 1
        @test runtime.parameters == Float32[gain]
        @test C.program_tracker_values(runtime, key) == expected
    end
end

@testset "failed staged input validation leaves publication abortable: $(nameof(typeof(engine)))" for engine in (
        CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine(),
    )
    C = CorePotts
    runtime, handle, key = site_sum_runtime(engine)
    before = C.program_snapshot(runtime)
    transaction = C.stage_program_mcs!(runtime)
    entry = C.program_step_snapshot(transaction)
    state = C.copy_auxiliary_state(entry.descriptor_state)
    fill!(C.state_block(state, handle).values, floatmax(Float32))
    C.stage_program_descriptor_state!(transaction, state)
    C.stage_program_parameters!(transaction, Float32[2])
    failure = try
        C.prevalidate_program_step_transaction(transaction)
        nothing
    catch exception
        exception
    end
    @test failure isa LocalMath.LocalMathValidationError
    @test occursin("contract: :runtime_stage_validation", sprint(showerror, failure))
    @test runtime.parameters == Float32[2]
    @test runtime.ownership == before.ownership
    @test C.program_tracker_values(runtime, key) == C.program_tracker_values(runtime.program, before, key)
    C.abort_program_step!(transaction)
    after = C.program_snapshot(runtime)
    @test after.mcs == before.mcs
    @test after.ownership == before.ownership
    @test after.trackers.values == before.trackers.values
    @test C.state_block(after.descriptor_state, handle).values == C.state_block(before.descriptor_state, handle).values
    @test !C.program_failed(runtime)
    @test_throws ArgumentError C.commit_program_step!(transaction)
end

@testset "valid staged input abort preserves published values: $(nameof(typeof(engine)))" for engine in (
        CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine(),
    )
    C = CorePotts
    runtime, handle, key = site_sum_runtime(engine)
    before = C.program_snapshot(runtime)
    transaction = C.stage_program_mcs!(runtime)
    entry = C.program_step_snapshot(transaction)
    state = C.copy_auxiliary_state(entry.descriptor_state)
    fill!(C.state_block(state, handle).values, 3.0f0)
    C.stage_program_descriptor_state!(transaction, state)
    C.stage_program_parameters!(transaction, Float32[4])
    C.prevalidate_program_step_transaction(transaction)
    C.abort_program_step!(transaction)
    after = C.program_snapshot(runtime)
    @test runtime.parameters == Float32[2]
    @test after.mcs == before.mcs
    @test after.ownership == before.ownership
    @test after.trackers.values == before.trackers.values
    @test C.state_block(after.descriptor_state, handle).values == C.state_block(before.descriptor_state, handle).values
end
