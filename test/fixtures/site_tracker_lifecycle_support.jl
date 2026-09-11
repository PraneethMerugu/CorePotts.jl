using Test
import CorePotts
isdefined(@__MODULE__, :site_minimum_oracle) || include("site_minimum_support.jl")
isdefined(@__MODULE__, :receipt_descriptor) || include("lifecycle_descriptor_support.jl")

function test_site_tracker_settlement_owner(; settled_receipts = false, adapt_to = identity, backend = CorePotts.CPUProgramBackend())
    C = CorePotts
    host, handle, minimum_key, sum_key = site_tracker_lifecycle_runtime(C.CheckerboardProgramEngine(), C.RemoveCellLifecycleEffect; backend)
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    before = C.program_snapshot(runtime)
    reference = C.restore_program_checkpoint(runtime.program, C.program_checkpoint(runtime))
    reference = adapt_to === identity ? reference : C.adapt_program_runtime(adapt_to, reference)
    C.advance_mcs!(reference)
    C.enqueue_program_mcs!(runtime)
    journal = C._checkerboard_settlement_events(runtime.engine_workspace)
    @test any(LocalMath.ispending, journal)
    settled_receipts && LocalMath.waitall(journal)
    pending = map(LocalMath.ispending, journal)
    @test any(pending) == !settled_receipts
    counters = C._program_counter_snapshot(runtime)
    failure = fetch(
        @async try
            C.settle_program!(runtime, C.ProgramSettlementRequest(C.PublicStepSettlement; full_snapshot = true))
            nothing
        catch error
            error
        end
    )
    @test failure isa LocalMath.LocalMathValidationError
    # LocalMath documents `contract` as the public structured discriminator.
    @test failure.contract === :receipt_owner
    @test !runtime.settled
    @test runtime.mcs == before.mcs
    retained = C._checkerboard_settlement_events(runtime.engine_workspace)
    @test length(retained) == length(journal)
    @test all(a === b for (a, b) in zip(journal, retained))
    @test map(LocalMath.ispending, retained) == pending
    @test C._program_counter_snapshot(runtime) == counters
    @test Array(runtime.ownership) == before.ownership
    C.settle_program!(runtime, C.ProgramSettlementRequest(C.PublicStepSettlement; full_snapshot = true))
    @test runtime.settled
    @test !C.program_failed(runtime)
    @test all(!LocalMath.ispending(receipt) for receipt in journal)
    @test isempty(C._checkerboard_settlement_events(runtime.engine_workspace))
    actual = site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key)
    expected = C.program_snapshot(reference)
    @test actual.mcs == expected.mcs == 1
    @test actual.ownership == expected.ownership
    @test actual.trackers.values == expected.trackers.values
    @test C._program_counter_snapshot(runtime) == C._program_counter_snapshot(reference)
    return
end

function test_site_tracker_late_settlement_failure(; adapt_to = identity, backend = CorePotts.CPUProgramBackend())
    C = CorePotts
    host, handle, minimum_key, _ = site_tracker_lifecycle_runtime(
        C.CheckerboardProgramEngine(), C.CreateCellLifecycleEffect; source_overflow = true, include_sum = false, backend
    )
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    C.advance_mcs!(runtime)
    before = C.program_snapshot(runtime)
    checkpoint = C.program_checkpoint(runtime)
    counters = C._program_counter_snapshot(runtime)
    # Submission must succeed: this specifically defends receipt-time failure,
    # not the synchronous structural exception exercised by the mixed tracker.
    @test C.enqueue_program_mcs!(runtime) === runtime
    journal = C._checkerboard_settlement_events(runtime.engine_workspace)
    @test any(LocalMath.ispending, journal)
    @test !runtime.settled
    failure = try
        C.settle_program!(runtime, C.ProgramSettlementRequest(C.PublicStepSettlement; full_snapshot = true))
        nothing
    catch error
        error
    end
    @test failure isa C.LifecycleBackendFailure
    @test occursin("runtime_stage_validation", sprint(showerror, failure))
    @test all(!LocalMath.ispending(receipt) for receipt in journal)
    @test isempty(C._checkerboard_settlement_events(runtime.engine_workspace))
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
    reference = C.restore_program_checkpoint(runtime.program, checkpoint)
    reference = adapt_to === identity ? reference : C.adapt_program_runtime(adapt_to, reference)
    for continued in (runtime, reference)
        C.update_program_inputs!(continued; parameters = Float32[1])
        C.advance_mcs!(continued)
        snapshot = C.program_snapshot(continued)
        @test snapshot.mcs == before.mcs + 1
        @test snapshot.ownership[6, 6] == 2
        @test C.program_tracker_values(continued, minimum_key) == site_minimum_oracle(
            snapshot.ownership, C.state_block(snapshot.descriptor_state, handle).values, 1.0f0, 2, 19.0f0
        )
    end
    @test C.program_snapshot(runtime).trackers.values == C.program_snapshot(reference).trackers.values
    @test C._program_counter_snapshot(runtime) == C._program_counter_snapshot(reference)
    return
end

function test_site_tracker_lifecycle_recovery(entrypoint)
    C = CorePotts
    runtime, handle, minimum_key, sum_key = site_tracker_lifecycle_runtime(
        C.CheckerboardProgramEngine(), C.CreateCellLifecycleEffect; source_overflow = true
    )
    reference = C.restore_program_checkpoint(runtime.program, C.program_checkpoint(runtime))
    C.advance_mcs!(reference)
    entrypoint === :through || C.advance_mcs!(runtime)
    failure = try
        if entrypoint === :through
            C.enqueue_program_through!(runtime, 2)
        elseif entrypoint === :enqueue
            C.enqueue_program_mcs!(runtime)
        elseif entrypoint === :staged
            C.stage_program_mcs!(runtime)
        else
            C.advance_mcs!(runtime)
        end
        if entrypoint in (:through, :enqueue)
            C.settle_program!(runtime, C.ProgramSettlementRequest(
                C.PublicStepSettlement; full_snapshot = true,
            ))
        end
        nothing
    catch error
        error
    end
    @test failure isa C.LifecycleInvariantFailure
    @test occursin("tracker_commit_invalid", sprint(showerror, failure))
    if entrypoint === :through
        @test runtime.mcs == 0
        @test !runtime.settled
        @test_throws ArgumentError C.program_snapshot(runtime)
        receipt = C.settle_program!(runtime, C.ProgramSettlementRequest(C.PublicStepSettlement; full_snapshot = true))
        # The failed second enqueue replaced shared lifecycle scratch. Do not
        # fabricate the first MCS's events from that incomplete second request.
        @test receipt.lifecycle_receipt === nothing
    end
    @test runtime.settled
    @test !C.program_failed(runtime)
    actual, expected = C.program_snapshot(runtime), C.program_snapshot(reference)
    @test actual.mcs == expected.mcs == 1
    @test actual.ownership == expected.ownership
    @test actual.cell_kinds == expected.cell_kinds
    @test actual.cell_generations == expected.cell_generations
    @test actual.trackers.values == expected.trackers.values
    @test C.state_block(actual.descriptor_state, handle).values == C.state_block(expected.descriptor_state, handle).values
    @test C._program_counter_snapshot(runtime) == C._program_counter_snapshot(reference)
    for continued in (runtime, reference)
        C.update_program_inputs!(continued; parameters = Float32[1])
        C.advance_mcs!(continued)
        @test C.program_snapshot(continued).mcs == 2
        site_tracker_lifecycle_snapshot(continued, handle, minimum_key, sum_key)
    end
    @test C.program_snapshot(runtime).ownership == C.program_snapshot(reference).ownership
    @test C.program_snapshot(runtime).trackers.values == C.program_snapshot(reference).trackers.values
    @test C._program_counter_snapshot(runtime) == C._program_counter_snapshot(reference)
    report = C._inspect_checkerboard_execution(runtime.engine_workspace)
    @test all(bank -> bank.pending == 0, report.completion_receipts.lifecycle.site_trackers)
    return
end

function site_tracker_lifecycle_runtime(
        engine, effect;
        tied = false, clear_source = false, late_failure = false, source_overflow = false,
        trigger = true, constraint_expression = nothing, absolute_tolerance = 0.0f0,
        initial_ownership = nothing, initial_signal = nothing, initial_kinds = Int16[2, 0],
        include_minimum = true, include_sum = true, group_sum = true,
        retained_history = false,
        backend = CorePotts.CPUProgramBackend()
    )
    C = CorePotts
    schemas = [
        C.StateBlockSchema(
            C.QualifiedResourceIdentity((), :signal), v"1.0.0", :site,
            Float32, (6, 6), 36, :structure_of_arrays, :provided_or_zero,
            :shape_and_finite, :logical,
            clear_source && !retained_history ? (declared = :ClearOnOwnershipChange,) : :preserve,
            :declared, :bounded_write, :adapt_storage, :copy, :logical_copy, :qualified, true
        ),
    ]
    if retained_history
        push!(
            schemas, C.StateBlockSchema(
                C.QualifiedResourceIdentity((), :retained_signal), v"1.0.0", :history,
                Float32, (6, 6, 2), 72, :structure_of_arrays, :provided_or_zero,
                :shape_and_finite, :logical,
                clear_source ? (declared = :ClearOnOwnershipChange,) : :preserve,
                :declared, :bounded_write, :adapt_storage, :copy, :logical_copy, :qualified, true
            )
        )
    end
    if late_failure
        push!(
            schemas, C.StateBlockSchema(
                C.QualifiedResourceIdentity((), :marker), v"1.0.0", :cell,
                Float32, (2,), 1, :structure_of_arrays, :provided_or_zero,
                :shape_and_finite, :logical, :declared, :declared, :bounded_write,
                :adapt_storage, :copy, :logical_copy, :qualified, true
            )
        )
    end
    layout = C.StateLayout(schemas)
    source = only(entry.handle for entry in layout.entries if entry.schema.identity.name === :signal)
    parent = retained_history ? only(entry.handle for entry in layout.entries if entry.schema.identity.name === :retained_signal) : source
    stage_plan = C.StageExecutionPlan()
    handle = source
    if retained_history
        footprint = C.FiniteSpatialFootprint(C.IterationSiteFootprintAnchor(), ((0, 0),))
        sampling = C.CompiledStageDescriptor(
            C.StaticEvaluator(C.LiteralExpression(true)), C.StaticEvaluator(C.LiteralExpression(0.0f0)),
            C.ShiftAppendEffect(parent, source, 3; cadence = C.PeriodicMCSCadence, cadence_value = 1000),
            C.AfterMCSStage(), C.ResourceAccess((parent, source), (parent,), footprint, footprint, C.ExclusiveWriteAccess()),
            C.DescriptorSupport(true, true, true, true), 1, 0
        )
        stage_plan = C.StageExecutionPlan((), (C.StageDescriptorGroup([sampling]),), (), 0, 0, "lifecycle-retained-source")
        handle = C.history_sample_handle(stage_plan, layout, parent, 1)
    end
    expression = C.OperationExpression(
        *, C.ParameterExpression(1.0f0, 1),
        C.OperationExpression(C.operation_callable(Val(:iteration_bound_state_value), v"1.0.0"), C.StateExpression(handle))
    )
    minimum_key = C.QualifiedTrackerKey(Val(:site_minimum), 1)
    sum_key = C.QualifiedTrackerKey(Val(:site_sum), 1)
    sum_descriptor = C.SiteSumTracker(
        Float32, sum_key, expression; absolute_tolerance,
    )
    sum_entry = group_sum ? C.DenseScalarTrackerGroup([sum_descriptor]) : sum_descriptor
    trackers = C.TrackerExecutionPlan(
        (
            C.OwnershipCountTracker(), C.CellMomentsTracker{2, Float32}(),
            (include_minimum ? (C.DenseScalarTrackerGroup([C.SiteMinimumTracker(Float32, minimum_key, expression; maximum_sites = 36, empty = 19.0f0)]),) : ())...,
            (include_sum ? (sum_entry,) : ())...,
        ), "lifecycle-site-expressions"
    )
    retire = effect === C.RetireCellLifecycleEffect
    constraint = if constraint_expression !== nothing
        constraint_expression(handle)
    elseif retire
        C.OperationExpression(
            &,
            C.OperationExpression(==, C.ContextExpression(C.operation_callable(Val(:target_cell), v"1.0.0")), C.LiteralExpression(Int32(1))),
            C.OperationExpression(<=, C.ContextExpression(C.operation_callable(Val(:source_cell), v"1.0.0")), C.LiteralExpression(Int32(0)))
        )
    else
        C.LiteralExpression(false)
    end
    reads = Tuple(C.expression_state_handles(constraint))
    footprint = isempty(reads) ? C.EmptyFootprint() :
        C.FiniteSpatialFootprint(C.ProposalTargetFootprintAnchor(), ((0, 0),))
    reject = C.ProposalDescriptor(
        C.StaticEvaluator(constraint),
        C.ResourceAccess(reads, (), footprint, C.EmptyFootprint(), C.NoWriteAccess()),
        C.DescriptorSupport(true, true, true, true), (), (), C.ProposalConstraintRole(), 1
    )
    descriptor_plan = C.DescriptorExecutionPlan(
        (C.ProposalDescriptorGroup([reject], (), (), :unsplit),), layout,
        C.WorkspaceLayout(C.WorkspaceSchema[]), (), Any[:lifecycle_site_expression], 0,
        "lifecycle-site-expression-state", C.HamiltonianDomainResources(0, 0)
    )
    descriptor = receipt_descriptor(
        1, effect; domain_kind = 2, destination_kind = 2,
        parent_kind = 2, daughter_kind = 2,
        placement = effect === C.CreateCellLifecycleEffect ? C.SeedAtLifecyclePlacement : C.NoLifecyclePlacement,
        placement_evaluator = effect === C.CreateCellLifecycleEffect ? 2 : 0,
        partition = effect === C.DivideCellLifecycleEffect ? C.SpecifiedNormalLifecyclePartition : C.NoLifecyclePartition,
        point_from_centroid = effect === C.DivideCellLifecycleEffect, normal = (1.0f0, 0.0f0),
        relation_slot = effect === C.DivideCellLifecycleEffect ? 1 : 0,
        compiler_synthesized = retire,
        on_inadmissible = retire ? C.FilterLifecycleInadmissible : C.ErrorLifecycleInadmissible,
        cadence = retire ? C.EveryMCSCadence : C.PeriodicMCSCadence, cadence_value = retire ? 1 : 2,
        state_rule_count = late_failure ? 1 : 0, scalar_type = Float32
    )
    evaluators = C.LifecycleEvaluatorStorage(
        Any[
            C.StaticEvaluator(C.LiteralExpression(trigger)), C.StaticEvaluator(C.LiteralExpression(Int32(36))),
            C.StaticEvaluator(C.LiteralExpression(Inf32)),
        ],
        [:lifecycle_trigger, :lifecycle_placement, :lifecycle_state_transform]
    )
    state_rules = if late_failure
        marker = only(entry.handle for entry in layout.entries if entry.schema.identity.name === :marker)
        [
            C.LifecycleStateRule(
                marker, UInt64(1), C.RetireToLifecycleState,
                Int32(3), Int32(0), Int32(0), Int32(0), 0.5f0, C.ExactLifecycleRounding,
                UInt8(0), UInt8(0), C.RNGOperationKey(), C.RNGOperationKey()
            ),
        ]
    else
        Any[]
    end
    relation = Int8[1 -1 0 0; 0 0 1 -1]
    lifecycle_plan = C.LifecycleExecutionPlan(
        [descriptor], evaluators, C.LifecycleStateRuleStorage(state_rules),
        C.LifecycleRelationshipRule[], clear_source ? (C.LifecycleOwnershipRule(parent, C.ClearLifecycleOwnershipState),) : (),
        NTuple{2, Int16}[], C.LifecycleRelationStorage((relation,), Val(2)),
        C.StablePriorityLifecycleConflicts, 2,
        descriptor.domain === C.ModelLifecycleDomain ? 1 : 2, 1, 36, falses(2)
    )
    gain = source_overflow ? 2.0f0 : 1.0f0
    program = test_program(
        engine; descriptor_plan, stage_plan, tracker_plan = trackers, lifecycle_plan,
        scalar_type = Float32, parameter_defaults = Float32[gain], backend
    )
    ownership = fill(Int32(-1), 6, 6)
    ownership[3:4, 3:4] .= 1
    signal = fill(30.0f0, 6, 6)
    signal[3, 3], signal[4, 3], signal[3, 4], signal[4, 4] = -4.0f0, tied ? -4.0f0 : 5.0f0, 6.0f0, 7.0f0
    if retire
        ownership .= -1
        ownership[3, 3] = 1
    end
    source_overflow && (signal[6, 6] = floatmax(Float32))
    initial_ownership === nothing || (ownership = copy(initial_ownership))
    initial_signal === nothing || (signal = copy(initial_signal))
    values = map(layout.entries) do entry
        if entry.schema.domain === :history
            return cat(signal, signal .+ 100.0f0; dims = 3)
        elseif entry.schema.domain === :site
            return retained_history ? fill(77.0f0, 6, 6) : signal
        end
        return zeros(Float32, 2)
    end
    initial = C.ProgramInitialState(
        ownership, initial_kinds; scalar_type = Float32,
        descriptor_state = C.allocate_auxiliary_state(layout, values)
    )
    return C.initialize_program(program, initial, Float32[gain], UInt64(0x9274), UInt32(1)), handle, minimum_key, sum_key
end

function test_site_tracker_lifecycle_history(engine, effect; clear_source = false, adapt_to = identity, backend = CorePotts.CPUProgramBackend())
    C = CorePotts
    host, handle, minimum_key, sum_key = site_tracker_lifecycle_runtime(engine, effect; retained_history = true, clear_source, backend)
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    layout = runtime.program.descriptor_plan.state_layout
    source = only(entry.handle for entry in layout.entries if entry.schema.identity.name === :signal)
    parent = only(entry.handle for entry in layout.entries if entry.schema.identity.name === :retained_signal)
    C.advance_mcs!(runtime)
    before = site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key)
    @test C.program_tracker_values(runtime, minimum_key) == Float32[-4, 19]
    @test all(==(77.0f0), C.state_block(before.descriptor_state, source).values)
    @test C.state_block(before.descriptor_state, parent).values[:, :, 2] == C.state_block(before.descriptor_state, handle).values .+ 100.0f0
    state = C.copy_auxiliary_state(before.descriptor_state)
    C.state_block(state, handle).values .+= 10.0f0
    C.update_program_inputs!(runtime; descriptor_state = state, parameters = Float32[2])
    entry = site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key)
    C.advance_mcs!(runtime)
    after = site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key)
    changed = entry.ownership .!= after.ownership
    @test any(changed)
    expected_parent = copy(C.state_block(entry.descriptor_state, parent).values)
    if clear_source
        for sample in axes(expected_parent, 3)
            view(expected_parent, :, :, sample)[changed] .= 0.0f0
        end
    end
    @test C.state_block(after.descriptor_state, parent).values == expected_parent
    @test C.state_block(after.descriptor_state, source).values == C.state_block(entry.descriptor_state, source).values
    if effect === C.RemoveCellLifecycleEffect
        @test C.program_tracker_values(runtime, minimum_key) == Float32[19, 19]
    elseif effect === C.CreateCellLifecycleEffect
        @test C.program_tracker_values(runtime, minimum_key) == Float32[12, clear_source ? 0 : 80]
    end
    restored = C.restore_program_checkpoint(runtime.program, C.program_checkpoint(runtime))
    restored = adapt_to === identity ? restored : C.adapt_program_runtime(adapt_to, restored)
    for continued in (runtime, restored)
        C.advance_mcs!(continued)
        site_tracker_lifecycle_snapshot(continued, handle, minimum_key, sum_key)
    end
    actual, expected = C.program_snapshot(runtime), C.program_snapshot(restored)
    @test actual.ownership == expected.ownership
    @test actual.trackers.values == expected.trackers.values
    @test C.state_block(actual.descriptor_state, parent).values == C.state_block(expected.descriptor_state, parent).values
    @test C._program_counter_snapshot(runtime) == C._program_counter_snapshot(restored)
    return
end

function test_site_tracker_no_lifecycle_effect(engine; adapt_to = identity, backend = CorePotts.CPUProgramBackend())
    C = CorePotts
    small = 2.0f0^-25
    signal = zeros(Float32, 6, 6)
    signal[1], signal[2] = 1.0f0, small
    ownership = fill(Int32(-1), 6, 6)
    ownership[1:2] .= 1
    ownership[1, 2] = 2
    constraint = handle -> C.OperationExpression(
        &,
        C.OperationExpression(
            &,
            C.OperationExpression(==, C.ContextExpression(C.operation_callable(Val(:source_cell), v"1.0.0")), C.LiteralExpression(Int32(2))),
            C.OperationExpression(==, C.ContextExpression(C.operation_callable(Val(:target_cell), v"1.0.0")), C.LiteralExpression(Int32(1)))
        ),
        C.OperationExpression(
            ==,
            C.OperationExpression(C.operation_callable(Val(:proposal_bound_state_value), v"1.0.0"), C.StateExpression(handle)),
            C.LiteralExpression(1.0f0)
        )
    )
    host, handle, minimum_key, sum_key = site_tracker_lifecycle_runtime(
        engine, C.RemoveCellLifecycleEffect;
        trigger = false, constraint_expression = constraint, absolute_tolerance = small,
        initial_ownership = ownership, initial_signal = signal, initial_kinds = Int16[2, 2], backend
    )
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    for _ in 1:32
        C.advance_mcs!(runtime)
        count(==(Int32(1)), C.program_snapshot(runtime).ownership) == 1 && break
    end
    before = C.program_snapshot(runtime)
    @test count(==(Int32(1)), before.ownership) == 1
    @test C.program_tracker_value(runtime, sum_key, 1) === 0.0f0
    @test site_sum_oracle(before.ownership, signal, 1.0f0, 2)[1] === small
    expected = copy(reinterpret(UInt32, C.program_tracker_values(runtime, sum_key)))
    restored = C.restore_program_checkpoint(runtime.program, C.program_checkpoint(runtime))
    restored = adapt_to === identity ? restored : C.adapt_program_runtime(adapt_to, restored)
    for continued in (runtime, restored), _ in 1:3
        C.advance_mcs!(continued)
        @test !C.program_failed(continued)
        @test reinterpret(UInt32, C.program_tracker_values(continued, sum_key)) == expected
        @test C.program_snapshot(continued).ownership == before.ownership
    end
    return
end

function site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key)
    C = CorePotts
    snapshot = C.program_snapshot(runtime)
    signal = C.state_block(snapshot.descriptor_state, handle).values
    gain = only(Array(runtime.parameters))
    @test C.program_tracker_values(runtime.program, snapshot, minimum_key) == site_minimum_oracle(snapshot.ownership, signal, gain, 2, 19.0f0)
    @test C.program_tracker_values(runtime.program, snapshot, sum_key) == site_sum_oracle(snapshot.ownership, signal, gain, 2)
    return snapshot
end

function test_site_tracker_lifecycle(
        engine, effect; tied = false, clear_source = false, adapt_to = identity,
        backend = CorePotts.CPUProgramBackend()
    )
    C = CorePotts
    host, handle, minimum_key, sum_key = site_tracker_lifecycle_runtime(engine, effect; tied, clear_source, backend)
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    C.advance_mcs!(runtime)
    before = site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key)
    state = C.copy_auxiliary_state(before.descriptor_state)
    C.state_block(state, handle).values .+= 10.0f0
    C.update_program_inputs!(runtime; descriptor_state = state, parameters = Float32[2])
    site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key)
    C.advance_mcs!(runtime)
    after = site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key)
    @test after.ownership != before.ownership
    minima = C.program_tracker_values(runtime.program, after, minimum_key)
    if effect === C.RemoveCellLifecycleEffect
        @test minima == Float32[19, 19]
        @test all(iszero, after.cell_kinds)
    elseif effect === C.CreateCellLifecycleEffect
        @test minima == Float32[12, clear_source ? 0 : 80]
        @test after.ownership[6, 6] == 2
    elseif !clear_source
        @test sort(minima) == (tied ? Float32[12, 12] : Float32[12, 30])
    else
        @test any(iszero, C.state_block(after.descriptor_state, handle).values)
    end
    restored = C.restore_program_checkpoint(runtime.program, C.program_checkpoint(runtime))
    restored = adapt_to === identity ? restored : C.adapt_program_runtime(adapt_to, restored)
    for continued in (runtime, restored)
        C.advance_mcs!(continued)
        site_tracker_lifecycle_snapshot(continued, handle, minimum_key, sum_key)
    end
    @test C.program_snapshot(runtime).ownership == C.program_snapshot(restored).ownership
    @test C.program_snapshot(runtime).trackers.values == C.program_snapshot(restored).trackers.values
    return
end

function test_site_tracker_creation_ignores_cleared_entry_source(
        engine; group_sum = true, adapt_to = identity,
        backend = CorePotts.CPUProgramBackend(),
    )
    C = CorePotts
    signal = fill(30.0f0, 6, 6)
    signal[3, 3], signal[4, 3], signal[3, 4], signal[4, 4] = -4.0f0, 5.0f0, 6.0f0, 7.0f0
    signal[6, 6] = floatmax(Float32)
    host, handle, minimum_key, sum_key = site_tracker_lifecycle_runtime(
        engine, C.CreateCellLifecycleEffect;
        clear_source = true, source_overflow = true,
        initial_signal = signal, group_sum, backend,
    )
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    C.advance_mcs!(runtime)
    before = site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key)
    @test before.ownership[6, 6] == -1
    C.advance_mcs!(runtime)
    after = site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key)
    @test after.ownership[6, 6] == 2
    @test C.state_block(after.descriptor_state, handle).values[6, 6] == 0.0f0
    @test !C.program_failed(runtime)
    return
end

function test_site_tracker_retirement(engine; adapt_to = identity, backend = CorePotts.CPUProgramBackend())
    C = CorePotts
    host, handle, minimum_key, sum_key = site_tracker_lifecycle_runtime(engine, C.RetireCellLifecycleEffect; backend)
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    for _ in 1:16
        C.advance_mcs!(runtime)
        site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key)
        runtime.retired_cells == 1 && break
    end
    @test runtime.retired_cells == 1
    @test C.program_tracker_values(runtime, minimum_key) == Float32[19, 19]
    @test C.program_tracker_values(runtime, sum_key) == Float32[0, 0]
    restored = C.restore_program_checkpoint(runtime.program, C.program_checkpoint(runtime))
    restored = adapt_to === identity ? restored : C.adapt_program_runtime(adapt_to, restored)
    C.advance_mcs!(runtime)
    C.advance_mcs!(restored)
    @test C.program_snapshot(runtime).trackers.values == C.program_snapshot(restored).trackers.values
    return
end

function test_site_tracker_lifecycle_failure(
        engine; source_overflow = false, include_sum = true,
        group_sum = true, adapt_to = identity,
        backend = CorePotts.CPUProgramBackend(),
    )
    C = CorePotts
    effect = source_overflow ? C.CreateCellLifecycleEffect : C.RemoveCellLifecycleEffect
    host, handle, minimum_key, sum_key = site_tracker_lifecycle_runtime(
        engine, effect;
        source_overflow, include_sum, group_sum,
        late_failure = !source_overflow, clear_source = !source_overflow, backend
    )
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    C.advance_mcs!(runtime)
    before = include_sum ? site_tracker_lifecycle_snapshot(runtime, handle, minimum_key, sum_key) : C.program_snapshot(runtime)
    if !include_sum
        @test C.program_tracker_values(runtime, minimum_key) ==
            site_minimum_oracle(before.ownership, C.state_block(before.descriptor_state, handle).values, 2.0f0, 2, 19.0f0)
    end
    failure = try
        C.advance_mcs!(runtime)
        nothing
    catch error
        error
    end
    if source_overflow
        if include_sum
            @test failure isa C.LifecycleInvariantFailure
            diagnostic = r"tracker_commit_invalid"
        else
            @test failure isa Union{C.LifecycleInvariantFailure, C.LifecycleBackendFailure}
            diagnostic = r"tracker_commit_invalid|runtime_stage_validation"
        end
        @test occursin(diagnostic, sprint(showerror, failure))
    else
        @test failure === nothing
        @test C.program_failed(runtime)
        report = C.program_failure_report(runtime)
        @test report.code === C.ProgramStatusEvaluator
        @test report.detail === C.LifecycleDetailNonfiniteResult
    end
    after = C.program_snapshot(runtime)
    @test after.mcs == before.mcs
    @test after.ownership == before.ownership
    @test after.cell_kinds == before.cell_kinds
    @test after.cell_generations == before.cell_generations
    @test after.trackers.values == before.trackers.values
    for entry in runtime.program.descriptor_plan.state_layout.entries
        @test C.state_block(after.descriptor_state, entry.handle).values ==
            C.state_block(before.descriptor_state, entry.handle).values
    end
    if source_overflow
        @test runtime.settled
        @test !C.program_failed(runtime)
        restored = C.restore_program_checkpoint(runtime.program, C.program_checkpoint(runtime))
        restored = adapt_to === identity ? restored : C.adapt_program_runtime(adapt_to, restored)
        for continued in (runtime, restored)
            C.update_program_inputs!(continued; parameters = Float32[1])
            C.advance_mcs!(continued)
            snapshot = C.program_snapshot(continued)
            @test snapshot.mcs == before.mcs + 1
            @test snapshot.ownership[6, 6] == 2
            @test C.program_tracker_values(continued, minimum_key) == site_minimum_oracle(
                snapshot.ownership, C.state_block(snapshot.descriptor_state, handle).values, 1.0f0, 2, 19.0f0
            )
        end
        @test C.program_snapshot(runtime).trackers.values == C.program_snapshot(restored).trackers.values
        if engine isa C.CheckerboardProgramEngine
            report = C._inspect_checkerboard_execution(runtime.engine_workspace)
            @test all(bank -> bank.pending == 0, report.completion_receipts.lifecycle.site_trackers)
        end
    end
    return
end
