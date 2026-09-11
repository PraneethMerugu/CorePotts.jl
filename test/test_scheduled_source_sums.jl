isdefined(@__MODULE__, :site_sum_runtime) || include("fixtures/site_sum_support.jl")
isdefined(@__MODULE__, :_history_sample_fixture) || include("fixtures/history_sample_support.jl")
import LocalMath

function scheduled_site_sum_plan(handle; kwargs...)
    descriptor = scheduled_site_sum_assignment(handle; kwargs...)
    return CorePotts.StageExecutionPlan((), (CorePotts.StageDescriptorGroup([descriptor]),), (), 0, 1, "scheduled-site-sum-source")
end

include("fixtures/site_tracker_history_support.jl")

function source_sum_copy_constraint()
    C = CorePotts
    equal(name, value) = C.OperationExpression(
        ==,
        C.ContextExpression(C.operation_callable(Val(name), v"1.0.0")), C.LiteralExpression(value)
    )
    return C.OperationExpression(&, equal(:source_cell, Int32(2)), equal(:target_cell, Int32(1)))
end

function advance_to_source_sum_cancellation!(runtime)
    C = CorePotts
    for _ in 1:32
        runtime.accepted > 0 && break
        C.advance_mcs!(runtime)
    end
    @test runtime.accepted == 1
    @test runtime.ownership[1] == 1
    return @test runtime.ownership[2] == 2
end

@testset "checkerboard no-write boundaries retain a real nearest-neighbor cancellation" begin
    C = CorePotts
    small = 2.0f0^-25
    signal = zeros(Float32, 6, 6)
    signal[1], signal[2] = small, 1.0f0
    runtime, handle, key = site_sum_runtime(
        C.CheckerboardProgramEngine(); gain = 1.0f0,
        signal, absolute_tolerance = small, constraint = source_sum_copy_constraint(),
        stage_builder = handle -> scheduled_site_sum_plan(
            handle;
            condition = source -> C.LiteralExpression(false), value = identity
        )
    )
    advance_to_source_sum_cancellation!(runtime)
    @test C.program_tracker_value(runtime, key, 1) === 0.0f0
    @test site_sum_oracle(runtime.ownership, signal, 1.0f0, 3)[1] == small
    restored = C.restore_program_checkpoint(runtime.program, C.program_checkpoint(runtime))
    for _ in 1:3, continued in (runtime, restored)
        C.advance_mcs!(continued)
        @test continued.accepted == 1
        @test C.program_tracker_value(continued, key, 1) === 0.0f0
        @test C.state_block(continued.descriptor_state, handle).values == signal
    end
    @test runtime.trackers.values == restored.trackers.values
end

@testset "active source publication does not refresh an inactive lag cache" begin
    C = CorePotts
    small = 2.0f0^-25
    samples = zeros(Float32, 6, 6, 2)
    for lag in 1:2
        samples[1, 1, lag], samples[2, 1, lag] = small, 1.0f0
    end
    (; runtime, source, reads, keys) = scheduled_history_tracker_runtime(
        C.CheckerboardProgramEngine();
        cadence_value = 1000, constraint = source_sum_copy_constraint(), initial_samples = samples, absolute_tolerance = small
    )
    advance_to_source_sum_cancellation!(runtime)
    for _ in 1:3
        C.advance_mcs!(runtime)
        current = C.state_block(runtime.descriptor_state, source).values
        @test all(==(Float32(runtime.mcs + 1)), current)
        @test C.program_tracker_values(runtime, keys[1]) == site_sum_oracle(runtime.ownership, current, 1.0f0, 3)
        for index in 2:3
            @test C.program_tracker_value(runtime, keys[index], 1) === 0.0f0
            @test site_sum_oracle(
                runtime.ownership,
                C.state_block(runtime.descriptor_state, reads[index]).values, 1.0f0, 3
            )[1] == small
        end
    end
end

@testset "iterated write flags reset before a later real cancellation" begin
    C = CorePotts
    small = 2.0f0^-25
    signal = zeros(Float32, 6, 6)
    signal[1], signal[2] = small, -1.0f0
    constraint = handle -> C.OperationExpression(
        &, source_sum_copy_constraint(),
        C.OperationExpression(
            >,
            C.OperationExpression(C.operation_callable(Val(:proposal_bound_state_value), v"1.0.0"), C.StateExpression(handle)),
            C.LiteralExpression(0.0f0)
        )
    )
    runtime, handle, key = site_sum_runtime(
        C.CheckerboardProgramEngine(); gain = 1.0f0,
        signal, absolute_tolerance = small, constraint,
        stage_builder = handle -> scheduled_site_sum_plan(
            handle; iterations = 3,
            condition = source -> C.OperationExpression(<, source, C.LiteralExpression(0.0f0)),
            value = source -> C.OperationExpression(*, C.LiteralExpression(-1.0f0), source)
        )
    )
    C.advance_mcs!(runtime)
    @test runtime.accepted == 0
    @test C.state_block(runtime.descriptor_state, handle).values[2] == 1.0f0
    @test C.program_tracker_value(runtime, key, 1) === 1.0f0
    advance_to_source_sum_cancellation!(runtime)
    for _ in 1:3
        @test C.program_tracker_value(runtime, key, 1) === 0.0f0
        @test site_sum_oracle(
            runtime.ownership,
            C.state_block(runtime.descriptor_state, handle).values, 1.0f0, 3
        )[1] == small
        C.advance_mcs!(runtime)
    end
end

@testset "initial history sums capture once and checkpoint restoration does not recapture: $(nameof(typeof(engine)))" for engine in (
        CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine(),
    )
    C = CorePotts
    (; runtime, source, reads, keys) = scheduled_history_tracker_runtime(engine; cadence = C.AtMCSCadence, cadence_value = 0)
    @test runtime.mcs == 0
    @test C.program_tracker_values(runtime, keys[2]) == Float32[2, 1, 0]
    @test C.program_tracker_values(runtime, keys[3]) == Float32[10, 5, 0]
    state = C.copy_auxiliary_state(runtime.descriptor_state)
    C.state_block(state, source).values .= 7.0f0
    C.update_program_inputs!(runtime; descriptor_state = state)
    restored = C.restore_program_checkpoint(runtime.program, C.program_checkpoint(runtime))
    for continued in (runtime, restored)
        @test all(==(1.0f0), C.state_block(continued.descriptor_state, reads[2]).values)
        C.advance_mcs!(continued)
        @test C.program_tracker_values(continued, keys[1]) == Float32[16, 8, 0]
        @test C.program_tracker_values(continued, keys[2]) == Float32[2, 1, 0]
        @test C.program_tracker_values(continued, keys[3]) == Float32[10, 5, 0]
    end
end

@testset "late derived overflow rejects the whole scheduled boundary: $(nameof(typeof(engine)))" for engine in (
        CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine(),
    )
    C = CorePotts
    runtime, handle, key = site_sum_runtime(
        engine; gain = 1.0f0, constraint = C.LiteralExpression(false),
        stage_builder = handle -> scheduled_site_sum_plan(handle; value = source -> C.LiteralExpression(floatmax(Float32)))
    )
    before = C.program_snapshot(runtime)
    checkpoint = C.program_checkpoint(runtime)
    failure = try
        C.advance_mcs!(runtime)
        nothing
    catch exception
        exception
    end
    @test failure isa Union{LocalMath.LocalMathValidationError, C.LifecycleBackendFailure}
    @test occursin("runtime_stage_validation", sprint(showerror, failure))
    if engine isa C.CheckerboardProgramEngine
        # Completed-prefix recovery has restored a settled boundary, so the
        # ordinary snapshot must expose the same pre-transaction science.
        failed_snapshot = C.program_snapshot(runtime)
        @test runtime.settled
        @test failed_snapshot.mcs == before.mcs
        @test failed_snapshot.ownership == before.ownership
        @test failed_snapshot.cell_kinds == before.cell_kinds
        @test failed_snapshot.cell_generations == before.cell_generations
        @test failed_snapshot.trackers.values == before.trackers.values
        @test collect(failed_snapshot.relationships) == collect(before.relationships)
        @test C.state_block(failed_snapshot.descriptor_state, handle).values ==
            C.state_block(before.descriptor_state, handle).values
    end
    # These owning-package checks also defend the last published host science.
    @test runtime.mcs == before.mcs == 0
    @test runtime.ownership == before.ownership
    @test runtime.trackers.values == before.trackers.values
    @test C.state_block(runtime.descriptor_state, handle).values == C.state_block(before.descriptor_state, handle).values
    # Retry starts from the saved checkpoint, not a repaired failed runtime.
    restored = C.restore_program_checkpoint(runtime.program, checkpoint)
    C.update_program_inputs!(restored; parameters = Float32[0.25])
    C.advance_mcs!(restored)
    values = C.state_block(restored.descriptor_state, handle).values
    @test all(==(floatmax(Float32)), values)
    @test C.program_tracker_values(restored, key) == site_sum_oracle(restored.ownership, values, 0.25f0, 3)
end

@testset "lag sums refresh from the physical history publication: $(nameof(typeof(engine)))" for engine in (
        CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine(),
    )
    C = CorePotts
    (; runtime, source, history, reads, descriptors, keys) = scheduled_history_tracker_runtime(engine)
    layout, plan = runtime.program.descriptor_plan.state_layout, runtime.program.stage_plan
    for index in 2:3
        @test C.state_read_source(plan, layout, reads[index]).handle == source
        @test C._site_tracker_reads_write(descriptors[index], history, layout, plan)
        @test !C._site_tracker_reads_write(descriptors[index], source, layout, plan)
    end
    for (boundary, samples) in enumerate(((2, 10, 5), (3, 3, 10), (4, 3, 10)))
        C.advance_mcs!(runtime)
        @test runtime.mcs == boundary
        for (key, handle, value) in zip(keys, reads, samples)
            actual = C.state_block(runtime.descriptor_state, handle).values
            @test all(==(Float32(value)), actual)
            @test C.program_tracker_values(runtime, key) == Float32[2value, value, 0]
            @test C.program_tracker_values(runtime, key) == site_sum_oracle(runtime.ownership, actual, 1.0f0, 3)
        end
    end
    checkpoint = C.program_checkpoint(runtime)
    restored = C.restore_program_checkpoint(runtime.program, checkpoint)
    C.advance_mcs!(runtime)
    C.advance_mcs!(restored)
    @test runtime.trackers.values == restored.trackers.values
    @test C.state_block(runtime.descriptor_state, history).values == C.state_block(restored.descriptor_state, history).values
end

@testset "actual no-write boundaries retain accepted-copy rounding" begin
    C = CorePotts
    small = 2.0f0^-25
    signal = zeros(Float32, 6, 6)
    signal[1], signal[2] = 1.0f0, small
    equal(name, value) = C.OperationExpression(
        ==,
        C.ContextExpression(C.operation_callable(Val(name), v"1.0.0")), C.LiteralExpression(value)
    )
    constraint = C.OperationExpression(&, equal(:source_cell, Int32(2)), equal(:target_cell, Int32(1)))
    for enabled in (false, true)
        runtime, handle, key = site_sum_runtime(
            C.SequentialProgramEngine(); gain = 1.0f0,
            signal, absolute_tolerance = small, constraint,
            stage_builder = handle -> scheduled_site_sum_plan(
                handle;
                condition = source -> C.LiteralExpression(enabled), value = identity
            )
        )
        @test C._attempt_selected!(runtime, CartesianIndex(3, 1), CartesianIndex(1, 1), 1, 1, Val(:scripted), 0.5f0)
        @test C.program_tracker_value(runtime, key, 1) === 0.0f0
        @test site_sum_oracle(runtime.ownership, signal, 1.0f0, 3)[1] == small
        checkpoint = C.program_checkpoint(runtime)
        restored = C.restore_program_checkpoint(runtime.program, checkpoint)
        for continued in (runtime, restored)
            C.advance_mcs!(continued)
            @test C.program_tracker_value(continued, key, 1) === (enabled ? small : 0.0f0)
            @test C.state_block(continued.descriptor_state, handle).values == signal
        end
        @test runtime.trackers.values == restored.trackers.values
    end
end

@testset "shared cell sum readers retain boundary-entry values: $(nameof(typeof(engine)))" for engine in (
        CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine(),
    )
    C = CorePotts
    runtime, handles, key = site_sum_cell_read_runtime(engine; source_process = scheduled_site_sum_assignment)
    for boundary in 1:2
        C.advance_mcs!(runtime)
        snapshot = C.program_snapshot(runtime)
        @test snapshot.mcs == boundary
        @test all(==(Float32(boundary + 1)), C.state_block(snapshot.descriptor_state, handles[1]).values)
        for handle in handles[2:3]
            @test C.state_block(snapshot.descriptor_state, handle).values == Float32[4boundary, 2boundary, 0]
        end
        @test C.program_tracker_values(runtime, key) == Float32[4(boundary + 1), 2(boundary + 1), 0]
        @test C.program_tracker_values(runtime, key) == site_sum_oracle(
            snapshot.ownership,
            C.state_block(snapshot.descriptor_state, handles[1]).values, 2.0f0, 3
        )
    end
end

@testset "iterated source publication includes earlier enabled substeps: $(nameof(typeof(engine)))" for engine in (
        CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine(),
    )
    C = CorePotts
    runtime, handle, key = site_sum_runtime(
        engine;
        constraint = C.LiteralExpression(false),
        stage_builder = handle -> scheduled_site_sum_plan(
            handle; iterations = 3,
            condition = source -> C.OperationExpression(<, source, C.LiteralExpression(2.0f0))
        )
    )
    for _ in 1:2
        C.advance_mcs!(runtime)
        @test all(==(2.0f0), C.state_block(runtime.descriptor_state, handle).values)
        @test C.program_tracker_values(runtime, key) == Float32[8, 4, 0]
    end
end
