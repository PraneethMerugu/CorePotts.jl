function scheduled_draw_runtime(engine; reverse_order = false, generations = UInt32[7, 11, 0], failure = false)
    names = (:model_sample, :cell_sample, :site_sample, :iterated_sample)
    domains = (:model, :cell, :site, :site)
    shapes = ((1,), (4,), (6, 6), (6, 6))
    schemas = map(names, domains, shapes) do name, domain, shape
        CorePotts.StateBlockSchema(
            CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", domain,
            Float32, shape, 1, :structure_of_arrays, :provided_or_zero,
            :shape_and_finite, :logical, :preserve, :declared, :bounded_write,
            :adapt_storage, :copy, :logical_copy, :qualified, true,
        )
    end
    layout = CorePotts.StateLayout(collect(schemas))
    handles = map(names) do name
        only(entry.handle for entry in layout.entries if entry.schema.identity.name === name)
    end
    namespace = CorePotts.RNGNamespace((UInt64(0x0931), UInt64(0x0715)))
    keys = CorePotts.rng_operation_keys(
        Tuple(
            (; namespace, identity = String(name)) for name in (names..., :cell_condition)
        )
    )
    draw(key, family = 2, first = 0.0f0, second = 1.0f0) = CorePotts.OperationExpression(
        CorePotts.operation_callable(Val(:draw), v"1.0.0"),
        CorePotts.LiteralExpression(family), CorePotts.LiteralExpression(first),
        CorePotts.LiteralExpression(second), CorePotts.LiteralExpression(key),
    )
    descriptors = map(eachindex(names)) do index
        target = handles[index]
        effect = index == 1 ? CorePotts.ModelAssignmentEffect(target) :
            index == 2 ? CorePotts.CellAssignmentEffect(target, 2) :
            index == 3 ? CorePotts.SiteAssignmentEffect(target) :
            CorePotts.IteratedSiteAssignmentEffect(target, 3)
        read_footprint = index >= 3 ? CorePotts.FiniteSpatialFootprint(
                CorePotts.IterationSiteFootprintAnchor(), ((0, 0),)
            ) : CorePotts.EmptyFootprint()
        write_footprint = index == 1 ? CorePotts.ModelFootprint() :
            index == 2 ? CorePotts.OwnerFootprint() : read_footprint
        value = draw(keys[index])
        if index == 4
            previous = CorePotts.OperationExpression(
                CorePotts.operation_callable(Val(:iteration_bound_state_value), v"1.0.0"),
                CorePotts.StateExpression(target),
            )
            value = CorePotts.OperationExpression(
                /, CorePotts.OperationExpression(+, previous, value),
                CorePotts.ParameterExpression(1.0f0, 1),
            )
        end
        condition = index == 2 ? draw(keys[5], 1, 1.0f0, 0.0f0) : CorePotts.LiteralExpression(true)
        CorePotts.CompiledStageDescriptor(
            CorePotts.StaticEvaluator(condition), CorePotts.StaticEvaluator(value),
            effect, CorePotts.AfterMCSStage(),
            CorePotts.ResourceAccess(
                index == 4 ? (target,) : (), (target,), read_footprint,
                write_footprint, CorePotts.ExclusiveWriteAccess(),
            ),
            CorePotts.DescriptorSupport(true, true, true, true), index,
            index == 4 ? 2 : 1,
        )
    end
    before = Tuple(descriptors[index] for index in (reverse_order ? (3, 2, 1) : (1, 2, 3)))
    before_groups = Tuple(CorePotts.StageDescriptorGroup([descriptor]) for descriptor in before)
    after_groups = (CorePotts.StageDescriptorGroup([descriptors[4]]),)
    stage_plan = CorePotts.StageExecutionPlan((), before_groups, after_groups, 0, 2, "addressed-scheduled-draws")
    reject = CorePotts.ProposalDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(false)),
        CorePotts.ResourceAccess((), (), CorePotts.EmptyFootprint(), CorePotts.EmptyFootprint(), CorePotts.NoWriteAccess()),
        CorePotts.DescriptorSupport(true, true, true, true), (), (), CorePotts.ProposalConstraintRole(), 5,
    )
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (CorePotts.ProposalDescriptorGroup([reject], (), (), :unsplit),), layout,
        CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (),
        Any[names..., :fixed_ownership], 1, "scheduled-draw-resources", CorePotts.HamiltonianDomainResources(0, 0),
    )
    program = test_program(engine; descriptor_plan, stage_plan, scalar_type = Float32, parameter_defaults = Float32[1])
    ownership = ones(Int32, 6, 6)
    ownership[1] = 2
    initial_values = map(layout.entries) do entry
        fill(entry.schema.identity.name === :iterated_sample ? 0.0f0 : -1.0f0, entry.schema.shape)
    end
    initial = CorePotts.ProgramInitialState(
        ownership, Int16[2, 2, 0]; scalar_type = Float32, cell_generations = generations,
        descriptor_state = CorePotts.allocate_auxiliary_state(layout, Tuple(initial_values)),
    )
    runtime = CorePotts.initialize_program(program, initial, Float32[failure ? 0 : 1], UInt64(0x00173819), UInt32(7); repeat = UInt32(9))
    return runtime, handles, keys
end

function scheduled_uniform(key, mcs, kind, entity; generation = 0, invocation = 0, after_lifecycle = false)
    address = CorePotts.RNGAddress(
        stream = CorePotts.ScheduledProcessDrawStream, operation = key,
        mcs = mcs, subround = after_lifecycle ? 1 : 0, entity_kind = kind,
        entity = entity, generation = generation, invocation = invocation,
    )
    return CorePotts.uniform_open01(
        Float32, CorePotts.Philox4x64x10V3(),
        (UInt64(0x00173819), UInt64(7) | (UInt64(9) << 32)), address,
    )
end
