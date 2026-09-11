function mixed_cell_stage_runtime(engine; fail = false)
    schemas = map(((:cell_left, :cell, (6,)), (:cell_right, :cell, (6,)), (:model_signal, :model, ()), (:site_signal, :site, (6, 6)))) do (name, domain, shape)
        CorePotts.StateBlockSchema(
            CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", domain,
            Float32, shape, prod(shape), :structure_of_arrays, :provided_or_zero,
            :shape_and_finite, :logical, :preserve, :declared, :bounded_write,
            :adapt_storage, :copy, :logical_copy, :qualified, true,
        )
    end
    layout = CorePotts.StateLayout(collect(schemas))
    handles = map(schemas) do schema
        only(entry for entry in layout.entries if entry.schema.identity == schema.identity).handle
    end
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (), layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (),
        Any[:cell_left, :cell_right, :model_signal, :site_signal, :cell_failure], 0,
        "mixed-cell-stage-descriptors", CorePotts.HamiltonianDomainResources(0, 0),
    )
    descriptors = (
        cell_stage_descriptor(handles[1], handles[2], 1; transform = nothing),
        cell_stage_descriptor(handles[2], handles[1], 2; transform = nothing),
    )
    other_descriptors = map((3, 4)) do index
        model = index == 3
        handle = handles[index]
        operation = CorePotts.operation_callable(Val(model ? :model_bound_state_value : :iteration_bound_state_value), v"1.0.0")
        read = CorePotts.OperationExpression(operation, CorePotts.StateExpression(handle))
        value = CorePotts.OperationExpression(+, read, CorePotts.LiteralExpression(1.0f0))
        footprint = model ? CorePotts.ModelFootprint() : CorePotts.FiniteSpatialFootprint(CorePotts.IterationSiteFootprintAnchor(), ((0, 0),))
        CorePotts.CompiledStageDescriptor(
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
            CorePotts.StaticEvaluator(value), model ? CorePotts.ModelAssignmentEffect(handle) : CorePotts.SiteAssignmentEffect(handle),
            CorePotts.AfterMCSStage(),
            CorePotts.ResourceAccess((handle,), (handle,), model ? CorePotts.EmptyFootprint() : footprint, footprint, CorePotts.ExclusiveWriteAccess()),
            CorePotts.DescriptorSupport(true, true, true, true), index, 1,
        )
    end
    before = map(descriptor -> CorePotts.StageDescriptorGroup([descriptor]), (descriptors[1], other_descriptors..., descriptors[2]))
    after = fail ? (
            CorePotts.StageDescriptorGroup(
                [
                    cell_stage_descriptor(handles[1], handles[1], 3; transform = NonfiniteCellStageValue(), source_handle = 5),
                ]
            ),
        ) : ()
    stage_plan = CorePotts.StageExecutionPlan((), before, after, 0, 1, "mixed-cell-stage-boundary")
    program = test_program(engine; descriptor_plan, stage_plan, scalar_type = Float32)
    values = (ones(Float32, 6), fill(3.0f0, 6), fill(5.0f0), fill(7.0f0, 6, 6))
    values_by_identity = Dict(schema.identity => value for (schema, value) in zip(schemas, values))
    initial_values = map(entry -> values_by_identity[entry.schema.identity], layout.entries)
    initial = CorePotts.ProgramInitialState(
        ones(Int32, 6, 6), Int16[2]; scalar_type = Float32,
        descriptor_state = CorePotts.allocate_auxiliary_state(layout, initial_values),
    )
    return CorePotts.initialize_program(program, initial, Float32[], UInt64(0xc321), UInt32(1)), handles
end

function retiring_cell_stage_runtime(engine, seed)
    schema = CorePotts.StateBlockSchema(
        CorePotts.QualifiedResourceIdentity((), :retiring_signal), v"1.0.0", :cell,
        Float32, (1,), 1, :structure_of_arrays, :provided_or_zero, :shape_and_finite,
        :logical, :preserve, :declared, :bounded_write, :adapt_storage, :copy,
        :logical_copy, :qualified, true,
    )
    layout = CorePotts.StateLayout([schema])
    handle = only(layout.entries).handle
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (), layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (),
        Any[:retire_cell, :before_cell, :after_cell], 0,
        "retiring-cell-descriptors", CorePotts.HamiltonianDomainResources(0, 0),
    )
    descriptor = receipt_descriptor(
        1, CorePotts.RetireCellLifecycleEffect;
        domain_kind = 2, on_inadmissible = CorePotts.FilterLifecycleInadmissible,
        compiler_synthesized = true, scalar_type = Float32
    )
    lifecycle = CorePotts.LifecycleExecutionPlan(
        [descriptor], CorePotts.LifecycleEvaluatorStorage(
            Any[CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true))], [:lifecycle_trigger]
        ),
        CorePotts.LifecycleStateRuleStorage(Any[]), CorePotts.LifecycleRelationshipRule[], (), NTuple{2, Int16}[],
        CorePotts.LifecycleRelationStorage((), Val(2)), CorePotts.StablePriorityLifecycleConflicts,
        1, 1, 1, 0, falses(2),
    )
    before = cell_stage_descriptor(handle, handle, 1; increment = 1.0f0, source_handle = 2)
    after = cell_stage_descriptor(handle, handle, 2; increment = 1.0f0, source_handle = 3)
    stage_plan = CorePotts.StageExecutionPlan((), (CorePotts.StageDescriptorGroup([before]),), (CorePotts.StageDescriptorGroup([after]),), 0, 0, "retiring-cell-boundaries")
    program = test_program(engine; descriptor_plan, stage_plan, lifecycle_plan = lifecycle, scalar_type = Float32, temperature = 0)
    ownership = zeros(Int32, 6, 6)
    ownership[3, 3] = 1
    initial = CorePotts.ProgramInitialState(
        ownership, Int16[2]; scalar_type = Float32,
        descriptor_state = CorePotts.allocate_auxiliary_state(layout, (Float32[1],))
    )
    return CorePotts.initialize_program(program, initial, Float32[], seed, UInt32(1)), handle
end
