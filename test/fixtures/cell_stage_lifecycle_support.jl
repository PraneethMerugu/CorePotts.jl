include("lifecycle_descriptor_support.jl")

function cell_stage_lifecycle_runtime(engine; birth_action = CorePotts.InitializeLifecycleState, second_effect = CorePotts.CreateCellLifecycleEffect)
    schema = CorePotts.StateBlockSchema(
        CorePotts.QualifiedResourceIdentity((), :cell_lifecycle_signal), v"1.0.0", :cell,
        Float32, (6,), 1, :structure_of_arrays, :provided_or_zero, :shape_and_finite,
        :logical, :declared, :declared, :bounded_write, :adapt_storage, :copy,
        :logical_copy, :qualified, true,
    )
    layout = CorePotts.StateLayout([schema])
    handle = only(layout.entries).handle
    reject = CorePotts.ProposalDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(false)),
        CorePotts.ResourceAccess((), (), CorePotts.EmptyFootprint(), CorePotts.EmptyFootprint(), CorePotts.NoWriteAccess()),
        CorePotts.DescriptorSupport(true, true, true, true), (), (), CorePotts.ProposalConstraintRole(), 1,
    )
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (CorePotts.ProposalDescriptorGroup([reject], (), (), :unsplit),), layout,
        CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (), Any[:remove_cell, :create_cell, :before_cell, :after_cell],
        1, "cell-lifecycle-descriptors", CorePotts.HamiltonianDomainResources(0, 0),
    )
    before = cell_stage_descriptor(handle, handle, 1; increment = 1.0f0, source_handle = 3)
    after = cell_stage_descriptor(handle, handle, 2; increment = 1.0f0, source_handle = 4)
    stages = CorePotts.StageExecutionPlan((), (CorePotts.StageDescriptorGroup([before]),), (CorePotts.StageDescriptorGroup([after]),), 0, 0, "cell-lifecycle-boundaries")
    lifecycle = cell_stage_lifecycle_plan(handle; action = birth_action, effect = second_effect)
    offsets = Int8[1 -1 0 0; 0 0 1 -1]
    checkerboard = engine isa CorePotts.CheckerboardProgramEngine ? CorePotts.CheckerboardPlan((6, 6), (true, true), offsets) : CorePotts.NoCheckerboardPlan()
    program = CorePotts.CompiledPottsProgram(
        (6, 6), (true, true), offsets, 3, 1, CorePotts.CompiledScalar(3.0f0), 1,
        Float32[], (), CorePotts.TrackerExecutionPlan((CorePotts.OwnershipCountTracker(),), "cell-lifecycle-count"),
        descriptor_plan, stages, engine, CorePotts.CPUProgramBackend(), "cell-stage-lifecycle";
        lifecycle_plan = lifecycle, checkerboard_plan = checkerboard,
    )
    ownership = ones(Int32, 6, 6)
    ownership[36] = 2
    initial = CorePotts.ProgramInitialState(
        ownership, Int16[2, 3]; scalar_type = Float32,
        descriptor_state = CorePotts.allocate_auxiliary_state(layout, (ones(Float32, 6),))
    )
    return CorePotts.initialize_program(program, initial, Float32[], UInt64(0xc318), UInt32(1)), handle
end

function cell_stage_lifecycle_plan(handle; action, effect)
    lifecycle_descriptors = [
        receipt_descriptor(1, CorePotts.RemoveCellLifecycleEffect; domain_kind = 3, scalar_type = Float32),
        receipt_descriptor(
            2, effect; destination_kind = effect === CorePotts.TransitionCellLifecycleEffect ? 3 : 2, domain_kind = 2,
            placement = CorePotts.SeedAtLifecyclePlacement, placement_evaluator = 2,
            cadence = CorePotts.PeriodicLifecycleCadence, cadence_value = 2, state_rule_count = 1, scalar_type = Float32
        ),
    ]
    evaluators = CorePotts.LifecycleEvaluatorStorage(
        Any[
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(36)),
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(10.0f0)),
        ],
        [:lifecycle_trigger, :lifecycle_placement, :lifecycle_state_transform],
    )
    rule = CorePotts.LifecycleStateRule(
        handle, UInt64(1), action,
        Int32(3), Int32(0), Int32(0), Int32(0), 0.5f0, CorePotts.ExactLifecycleRounding,
        UInt8(0), UInt8(0), CorePotts.RNGOperationKey(), CorePotts.RNGOperationKey()
    )
    return CorePotts.LifecycleExecutionPlan(
        lifecycle_descriptors, evaluators, CorePotts.LifecycleStateRuleStorage([rule]),
        CorePotts.LifecycleRelationshipRule[], (), NTuple{2, Int16}[],
        CorePotts.LifecycleRelationStorage((), Val(2)), CorePotts.StablePriorityLifecycleConflicts,
        2, effect === CorePotts.CreateCellLifecycleEffect ? 3 : 4, 1, 0, falses(3),
    )
end
