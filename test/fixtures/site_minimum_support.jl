using Test
import CorePotts
import LocalMath
isdefined(@__MODULE__, :test_program) || include("compiled_program_support.jl")
isdefined(@__MODULE__, :site_sum_runtime) || include("site_sum_support.jl")
isdefined(@__MODULE__, :scheduled_history_tracker_runtime) || include("site_tracker_history_support.jl")

function test_site_minimum_history(engine; adapt_to = identity, backend = CorePotts.CPUProgramBackend())
    C = CorePotts
    fixture = scheduled_history_tracker_runtime(
        engine; quantity = Val(:site_minimum), backend,
        tracker_builder = (key, expression) -> C.SiteMinimumTracker(Float32, key, expression; maximum_sites = 36, empty = 19.0f0)
    )
    runtime = adapt_to === identity ? fixture.runtime : C.adapt_program_runtime(adapt_to, fixture.runtime)
    for (boundary, expected) in enumerate(((2, 10, 5), (3, 3, 10), (4, 3, 10)))
        C.advance_mcs!(runtime)
        snapshot = C.program_snapshot(runtime)
        @test snapshot.mcs == boundary
        for (key, handle, value) in zip(fixture.keys, fixture.reads, expected)
            samples = C.state_block(snapshot.descriptor_state, handle).values
            @test all(==(Float32(value)), samples)
            @test C.program_tracker_values(runtime.program, snapshot, key) == Float32[value, value, 19]
            @test C.program_tracker_values(runtime.program, snapshot, key) ==
                site_minimum_oracle(snapshot.ownership, samples, 1.0f0, 3, 19.0f0)
        end
    end
    restored = C.restore_program_checkpoint(runtime.program, C.program_checkpoint(runtime))
    restored = adapt_to === identity ? restored : C.adapt_program_runtime(adapt_to, restored)
    for continued in (runtime, restored)
        C.advance_mcs!(continued)
        snapshot = C.program_snapshot(continued)
        for (key, handle) in zip(fixture.keys, fixture.reads)
            @test C.program_tracker_values(continued.program, snapshot, key) == site_minimum_oracle(
                snapshot.ownership, C.state_block(snapshot.descriptor_state, handle).values, 1.0f0, 3, 19.0f0
            )
        end
    end
    @test C.program_snapshot(runtime).trackers.values == C.program_snapshot(restored).trackers.values
    return
end

function site_minimum_runtime(
        engine; maximum_sites = 36, empty = 19.0f0,
        gain = 1.0f0, kwargs...
    )
    C = CorePotts
    key = C.QualifiedTrackerKey(Val(:site_minimum), 1)
    factory = descriptor -> (C.SiteMinimumTracker(Float32, key, descriptor.expression; maximum_sites, empty),)
    runtime, handle, _ = site_sum_runtime(engine; gain, tracker_descriptors = factory, kwargs...)
    # Active identities must own a site at initialization. Zero-area
    # reconstruction is checked separately through the tracker rebuild contract.
    initial = C.ProgramInitialState(
        copy(runtime.ownership), Int16[2, 2, 0, 0];
        scalar_type = Float32, descriptor_state = C.copy_auxiliary_state(runtime.descriptor_state)
    )
    return C.initialize_program(runtime.program, initial, Float32[gain], UInt64(0x3826), UInt32(1)), handle, key
end

function site_minimum_oracle(ownership, signal, gain, owner_count, empty)
    return map(1:owner_count) do owner
        values = Float32[gain * signal[site] for site in eachindex(ownership) if ownership[site] == owner]
        isempty(values) ? empty : minimum(values)
    end
end

function site_minimum_snapshot_matches(runtime, handle, key, gain, empty)
    C = CorePotts
    snapshot = C.program_snapshot(runtime)
    values = C.state_block(snapshot.descriptor_state, handle).values
    @test C.program_tracker_values(runtime.program, snapshot, key) ==
        site_minimum_oracle(snapshot.ownership, values, gain, length(snapshot.cell_kinds), empty)
    return snapshot
end

function minimum_removal_constraint(handle)
    C = CorePotts
    target = C.OperationExpression(C.operation_callable(Val(:proposal_bound_state_value), v"1.0.0"), C.StateExpression(handle))
    owner = C.ContextExpression(C.operation_callable(Val(:target_cell), v"1.0.0"))
    return C.OperationExpression(
        &,
        C.OperationExpression(==, owner, C.LiteralExpression(Int32(1))),
        C.OperationExpression(==, target, C.LiteralExpression(-4.0f0))
    )
end

function test_site_minimum_empty_value(engine; adapt_to = identity, backend = CorePotts.CPUProgramBackend())
    C = CorePotts
    host, handle, key = site_minimum_runtime(engine; signal = fill(30.0f0, 6, 6), empty = 19.0f0, backend)
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    snapshot = site_minimum_snapshot_matches(runtime, handle, key, 1.0f0, 19.0f0)
    # Empty policy is not a seed that caps an occupied owner's minimum.
    @test C.program_tracker_values(runtime.program, snapshot, key) == Float32[30, 30, 19, 19]
    return
end

function test_site_minimum_removal(
        engine; adapt_to = identity,
        backend = CorePotts.CPUProgramBackend()
    )
    C = CorePotts
    for tied in (false, true)
        signal = fill(8.0f0, 6, 6)
        signal[1] = -4.0f0
        signal[2] = tied ? -4.0f0 : 5.0f0
        host, handle, key = site_minimum_runtime(engine; signal, constraint = minimum_removal_constraint, backend)
        runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
        @test C.program_tracker_values(runtime, key) == Float32[-4, 8, 19, 19]
        for _ in 1:8
            C.advance_mcs!(runtime)
            @test !C.program_failed(runtime)
            snapshot = site_minimum_snapshot_matches(runtime, handle, key, 1.0f0, 19.0f0)
            count(==(Int32(1)), snapshot.ownership) == 1 && break
        end
        snapshot = C.program_snapshot(runtime)
        @test count(==(Int32(1)), snapshot.ownership) == 1
        @test C.program_tracker_values(runtime, key)[1] == (tied ? -4.0f0 : 5.0f0)
        @test C.program_tracker_values(runtime, key)[3:4] == Float32[19, 19]
        checkpoint = C.program_checkpoint(runtime)
        restored = C.restore_program_checkpoint(runtime.program, checkpoint)
        restored = adapt_to === identity ? restored : C.adapt_program_runtime(adapt_to, restored)
        for continued in (runtime, restored)
            C.advance_mcs!(continued)
            site_minimum_snapshot_matches(continued, handle, key, 1.0f0, 19.0f0)
        end
        @test C.program_snapshot(runtime).ownership == C.program_snapshot(restored).ownership
        @test C.program_snapshot(runtime).trackers.values == C.program_snapshot(restored).trackers.values
    end
    return
end

function test_site_minimum_inputs(engine; adapt_to = identity, backend = CorePotts.CPUProgramBackend())
    C = CorePotts
    host, handle, key = site_minimum_runtime(engine; backend)
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    state = C.copy_auxiliary_state(C.program_snapshot(runtime).descriptor_state)
    C.state_block(state, handle).values .= reshape(Float32.(1:36), 6, 6)
    C.update_program_inputs!(runtime; descriptor_state = state, parameters = Float32[-2])
    before = site_minimum_snapshot_matches(runtime, handle, key, -2.0f0, 19.0f0)
    @test C.program_tracker_values(runtime, key) == Float32[-4, -6, 19, 19]
    invalid = C.copy_auxiliary_state(state)
    C.state_block(invalid, handle).values[1] = floatmax(Float32)
    @test_throws LocalMath.LocalMathValidationError C.update_program_inputs!(runtime; descriptor_state = invalid, parameters = Float32[2])
    after = C.program_snapshot(runtime)
    @test after.trackers.values == before.trackers.values
    @test after.ownership == before.ownership
    @test C.state_block(after.descriptor_state, handle).values == C.state_block(before.descriptor_state, handle).values
    return @test runtime.parameters == Float32[-2]
end

function test_site_minimum_scheduled(engine; adapt_to = identity, backend = CorePotts.CPUProgramBackend())
    C = CorePotts
    host, handles, key = site_sum_cell_read_runtime(
        engine; backend,
        quantity = Val(:site_minimum), tracker_operation = :cell_site_minimum,
        tracker_builder = (key, expression) -> C.SiteMinimumTracker(Float32, key, expression; maximum_sites = 36, empty = 19.0f0),
        source_process = handle -> scheduled_site_sum_assignment(handle)
    )
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    C.advance_mcs!(runtime)
    @test !C.program_failed(runtime)
    @test runtime.accepted == 0
    snapshot = C.program_snapshot(runtime)
    @test C.program_tracker_values(runtime.program, snapshot, key) == Float32[4, 4, 19]
    # Simultaneous readers use boundary-entry science. The maintained cache
    # reflects the completed source publication at the end of that boundary.
    @test C.state_block(snapshot.descriptor_state, handles[2]).values == Float32[2, 2, 0]
    @test C.state_block(snapshot.descriptor_state, handles[3]).values == Float32[2, 2, 0]
    C.advance_mcs!(runtime)
    snapshot = C.program_snapshot(runtime)
    @test C.program_tracker_values(runtime.program, snapshot, key) == Float32[6, 6, 19]
    @test C.state_block(snapshot.descriptor_state, handles[2]).values == Float32[4, 4, 0]
    @test C.state_block(snapshot.descriptor_state, handles[3]).values == Float32[4, 4, 0]
    return
end

function test_site_minimum_accepted_sources(engine; adapt_to = identity, backend = CorePotts.CPUProgramBackend())
    C = CorePotts
    host, handle, key = site_minimum_runtime(
        engine; backend,
        stage_builder = site_sum_accepted_increment,
        lifecycle = (declared = :ClearOnOwnershipChange,)
    )
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    C.advance_mcs!(runtime)
    @test !C.program_failed(runtime)
    @test runtime.accepted > 0
    site_minimum_snapshot_matches(runtime, handle, key, 1.0f0, 19.0f0)
    return
end

function test_site_minimum_accepted_nonfinite(engine; adapt_to = identity, backend = CorePotts.CPUProgramBackend())
    C = CorePotts
    signal = ones(Float32, 6, 6)
    signal[1, 2] = floatmax(Float32)
    constraint = handle -> C.OperationExpression(
        &,
        C.OperationExpression(>, C.ContextExpression(C.operation_callable(Val(:source_cell), v"1.0.0")), C.LiteralExpression(Int32(0))),
        C.OperationExpression(
            &,
            C.OperationExpression(==, C.ContextExpression(C.operation_callable(Val(:target_cell), v"1.0.0")), C.LiteralExpression(Int32(-1))),
            C.OperationExpression(
                ==, C.OperationExpression(C.operation_callable(Val(:proposal_bound_state_value), v"1.0.0"), C.StateExpression(handle)),
                C.LiteralExpression(floatmax(Float32))
            )
        )
    )
    host, handle, key = site_minimum_runtime(engine; signal, constraint, gain = 2.0f0, backend)
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    failure = nothing
    before = C.program_snapshot(runtime)
    counters = C._program_counter_snapshot(runtime)
    checkpoint = C.program_checkpoint(runtime)
    for _ in 1:32
        before = C.program_snapshot(runtime)
        counters = C._program_counter_snapshot(runtime)
        checkpoint = C.program_checkpoint(runtime)
        failure = try
            C.advance_mcs!(runtime)
            nothing
        catch error
            error
        end
        failure === nothing || break
    end
    @test failure isa Union{LocalMath.LocalMathValidationError, C.LifecycleBackendFailure}
    @test runtime.settled
    @test !C.program_failed(runtime)
    after = C.program_snapshot(runtime)
    @test after.mcs == before.mcs
    @test after.ownership == before.ownership
    @test after.cell_kinds == before.cell_kinds
    @test after.cell_generations == before.cell_generations
    @test after.trackers.values == before.trackers.values
    @test C.state_block(after.descriptor_state, handle).values == C.state_block(before.descriptor_state, handle).values
    @test C._program_counter_snapshot(runtime) == counters
    @test C.program_tracker_values(runtime, key) == Float32[2, 2, 19, 19]
    reference = C.restore_program_checkpoint(runtime.program, checkpoint)
    reference = adapt_to === identity ? reference : C.adapt_program_runtime(adapt_to, reference)
    for continued in (runtime, reference)
        C.update_program_inputs!(continued; parameters = Float32[1])
        C.advance_mcs!(continued)
        snapshot = site_minimum_snapshot_matches(continued, handle, key, 1.0f0, 19.0f0)
        @test snapshot.mcs == before.mcs + 1
        @test snapshot.ownership[1, 2] > 0
    end
    actual, expected = C.program_snapshot(runtime), C.program_snapshot(reference)
    @test actual.ownership == expected.ownership
    @test actual.trackers.values == expected.trackers.values
    @test C._program_counter_snapshot(runtime) == C._program_counter_snapshot(reference)
    return
end
