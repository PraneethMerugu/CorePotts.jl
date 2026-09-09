function site_sum_runtime(
        engine; gain = 2.0f0, signal = fill(1.0f0, 6, 6),
        tracker_descriptors = descriptor -> (descriptor,),
        stage_builder = handle -> CorePotts.StageExecutionPlan(), lifecycle = :preserve,
        absolute_tolerance = 0.0f0, relative_tolerance = 0.0f0, attempts_per_site = 1,
        constraint = nothing,
        backend = CorePotts.CPUProgramBackend(),
    )
    C = CorePotts
    schema = C.StateBlockSchema(
        C.QualifiedResourceIdentity((), :signal), v"1.0.0", :site,
        eltype(signal), (6, 6), 36, :structure_of_arrays, :provided_or_zero,
        :shape_and_finite, :logical, lifecycle, :declared, :bounded_write,
        :adapt_storage, :copy, :logical_copy, :qualified, true,
    )
    layout = C.StateLayout([schema])
    handle = only(layout.entries).handle
    expression = C.OperationExpression(
        *, C.ParameterExpression(1.0f0, 1),
        C.OperationExpression(
            C.operation_callable(Val(:iteration_bound_state_value), v"1.0.0"),
            C.StateExpression(handle)
        )
    )
    key = C.QualifiedTrackerKey(Val(:site_sum), 1)
    descriptor = C.SiteSumTracker(eltype(signal), key, expression; absolute_tolerance, relative_tolerance)
    tracker_plan = C.TrackerExecutionPlan((C.OwnershipCountTracker(), tracker_descriptors(descriptor)...), "source-aware-site-sum")
    descriptor_plan = empty_descriptor_plan(; state_layout = layout, source_table = Any[:signal])
    if constraint !== nothing
        proposal = C.ProposalDescriptor(
            C.StaticEvaluator(constraint),
            C.ResourceAccess((), (), C.EmptyFootprint(), C.EmptyFootprint(), C.NoWriteAccess()),
            C.DescriptorSupport(true, true, true, true), (), (), C.ProposalConstraintRole(), 1
        )
        descriptor_plan = C.DescriptorExecutionPlan(
            (C.ProposalDescriptorGroup([proposal], (), (), :unsplit),), layout,
            C.WorkspaceLayout(C.WorkspaceSchema[]), (), Any[:signal], 0,
            "site-sum-constraint", C.HamiltonianDomainResources(0, 0)
        )
    end
    program = test_program(
        engine; descriptor_plan, tracker_plan,
        stage_plan = stage_builder(handle), scalar_type = Float32,
        parameter_defaults = Float32[gain], attempts_per_site, backend,
    )
    ownership = fill(Int32(-1), 6, 6)
    ownership[1:2] .= 1
    ownership[3] = 2
    initial = C.ProgramInitialState(
        ownership, Int16[2, 2, 0]; scalar_type = Float32,
        descriptor_state = C.allocate_auxiliary_state(layout, (signal,))
    )
    runtime = C.initialize_program(program, initial, Float32[gain], UInt64(0x3826), UInt32(1))
    return runtime, handle, key
end

function site_sum_accepted_increment(handle; increment = 7.0f0)
    C = CorePotts
    target = C.OperationExpression(C.operation_callable(Val(:proposal_bound_state_value), v"1.0.0"), C.StateExpression(handle))
    footprint = C.FiniteSpatialFootprint(C.ProposalTargetFootprintAnchor(), ((0, 0),))
    descriptor = C.CompiledStageDescriptor(
        C.StaticEvaluator(C.LiteralExpression(true)),
        C.StaticEvaluator(C.OperationExpression(+, target, C.LiteralExpression(increment))),
        C.SiteAssignmentEffect(handle), C.AcceptedCopyStage(),
        C.ResourceAccess((handle,), (handle,), footprint, footprint, C.ExclusiveWriteAccess()),
        C.DescriptorSupport(true, true, true, true), 1, 1
    )
    return C.StageExecutionPlan((C.StageDescriptorGroup([descriptor]),), (), (), 1, 0, "site-signal-increment")
end

function site_sum_oracle(ownership, signal, gain, owner_count)
    return [
        sum(
                (gain * signal[site] for site in eachindex(ownership) if ownership[site] == owner);
                init = zero(eltype(signal))
            ) for owner in 1:owner_count
    ]
end

function site_sum_cell_read_runtime(engine; owner_expression = nothing)
    C = CorePotts
    names = (:signal, :first_total, :second_total, :site_count)
    schemas = map(eachindex(names)) do index
        C.StateBlockSchema(
            C.QualifiedResourceIdentity((), names[index]), v"1.0.0",
            index == 1 ? :site : :cell, index == 4 ? Int32 : Float32,
            index == 1 ? (6, 6) : (3,), index == 1 ? 36 : 1,
            :structure_of_arrays, :provided_or_zero, :shape_and_finite, :logical,
            :preserve, :declared, :bounded_write, :adapt_storage, :copy,
            :logical_copy, :qualified, true
        )
    end
    layout = C.StateLayout(schemas)
    handles = map(names) do name
        only(entry.handle for entry in layout.entries if entry.schema.identity.name === name)
    end
    signal = C.OperationExpression(C.operation_callable(Val(:iteration_bound_state_value), v"1.0.0"), C.StateExpression(handles[1]))
    contribution = C.OperationExpression(*, C.ParameterExpression(1.0f0, 1), signal)
    key = C.QualifiedTrackerKey(Val(:site_sum), 1)
    tracker = C.SiteSumTracker(Float32, key, contribution)
    tracker_plan = C.TrackerExecutionPlan((C.OwnershipCountTracker(), C.DenseScalarTrackerGroup([tracker])), "shared-cell-source-sum")
    owner = owner_expression === nothing ? C.ContextExpression(C.operation_callable(Val(:energy_anchor_cell), v"1.0.0")) : owner_expression
    sum_read = C.OperationExpression(C.QualifiedTrackerOperation(C.operation_callable(Val(:cell_site_sum), v"1.0.0"), key.quantity, key.source_handle), owner)
    count_read = C.OperationExpression(C.operation_callable(Val(:cell_volume), v"1.0.0"), owner)
    groups = map(2:4) do index
        descriptor = C.CompiledStageDescriptor(
            C.StaticEvaluator(C.LiteralExpression(true)),
            C.StaticEvaluator(index == 4 ? count_read : sum_read), C.CellAssignmentEffect(handles[index], 2),
            C.AfterMCSStage(), C.ResourceAccess((), (handles[index],), C.EmptyFootprint(), C.OwnerFootprint(), C.ExclusiveWriteAccess()),
            C.DescriptorSupport(true, true, true, true), index, index - 1
        )
        C.StageDescriptorGroup([descriptor])
    end
    stage_plan = C.StageExecutionPlan((), Tuple(groups), (), 0, 0, "shared-cell-source-sum-readers")
    reject = C.ProposalDescriptor(
        C.StaticEvaluator(C.LiteralExpression(false)),
        C.ResourceAccess((), (), C.EmptyFootprint(), C.EmptyFootprint(), C.NoWriteAccess()),
        C.DescriptorSupport(true, true, true, true), (), (), C.ProposalConstraintRole(), 1
    )
    descriptor_plan = C.DescriptorExecutionPlan(
        (C.ProposalDescriptorGroup([reject], (), (), :unsplit),),
        layout, C.WorkspaceLayout(C.WorkspaceSchema[]), (), Any[names...], 0,
        "fixed-owner-cell-sum-readers", C.HamiltonianDomainResources(0, 0)
    )
    program = test_program(
        engine; descriptor_plan, tracker_plan, stage_plan,
        scalar_type = Float32, parameter_defaults = Float32[2]
    )
    ownership = fill(Int32(-1), 6, 6)
    ownership[1:2] .= 1
    ownership[3] = 2
    initial_values = map(layout.entries) do entry
        fill(entry.schema.identity.name === :signal ? one(entry.schema.element_type) : zero(entry.schema.element_type), entry.schema.shape)
    end
    initial = C.ProgramInitialState(
        ownership, Int16[2, 2, 0]; scalar_type = Float32,
        descriptor_state = C.allocate_auxiliary_state(layout, initial_values)
    )
    return C.initialize_program(program, initial, Float32[2], UInt64(0x3826), UInt32(1)), handles, key
end
