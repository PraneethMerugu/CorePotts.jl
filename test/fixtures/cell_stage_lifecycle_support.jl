include("lifecycle_descriptor_support.jl")

function cell_stage_lifecycle_runtime(
        engine;
        birth_action = CorePotts.InitializeLifecycleState,
        second_effect = CorePotts.CreateCellLifecycleEffect,
        cell_capacity = 2,
        initial_kinds = Int16[2, 3],
        initial_generations = ones(UInt32, length(initial_kinds)),
        ownership = nothing,
        descriptor_factory = cell_stage_descriptor,
    )
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
    before = descriptor_factory(handle, handle, 1; increment = 1.0f0, source_handle = 3)
    after = descriptor_factory(handle, handle, 2; increment = 1.0f0, source_handle = 4)
    stages = CorePotts.StageExecutionPlan((), (CorePotts.StageDescriptorGroup([before]),), (CorePotts.StageDescriptorGroup([after]),), 0, 0, "cell-lifecycle-boundaries")
    lifecycle = cell_stage_lifecycle_plan(handle; action = birth_action, effect = second_effect, cell_capacity)
    offsets = Int8[1 -1 0 0; 0 0 1 -1]
    checkerboard = engine isa CorePotts.CheckerboardProgramEngine ? CorePotts.CheckerboardPlan((6, 6), (true, true), offsets) : CorePotts.NoCheckerboardPlan()
    program = CorePotts.CompiledPottsProgram(
        (6, 6), (true, true), offsets, 3, 1, CorePotts.CompiledScalar(3.0f0), 1,
        Float32[], (), CorePotts.TrackerExecutionPlan((CorePotts.OwnershipCountTracker(),), "cell-lifecycle-count"),
        descriptor_plan, stages, engine, CorePotts.CPUProgramBackend(), "cell-stage-lifecycle";
        lifecycle_plan = lifecycle, checkerboard_plan = checkerboard,
    )
    if ownership === nothing
        ownership = ones(Int32, 6, 6)
        ownership[36] = 2
    end
    initial = CorePotts.ProgramInitialState(
        ownership, initial_kinds; scalar_type = Float32, cell_generations = initial_generations,
        descriptor_state = CorePotts.allocate_auxiliary_state(layout, (ones(Float32, 6),))
    )
    return CorePotts.initialize_program(program, initial, Float32[], UInt64(0xc318), UInt32(1)), handle
end

function cell_stage_lifecycle_plan(handle; action, effect, cell_capacity = 2)
    lifecycle_descriptors = [
        receipt_descriptor(1, CorePotts.RemoveCellLifecycleEffect; domain_kind = 3, scalar_type = Float32),
        receipt_descriptor(
            2, effect; destination_kind = effect === CorePotts.TransitionCellLifecycleEffect ? 3 : 2, domain_kind = 2,
            placement = CorePotts.SeedAtLifecyclePlacement, placement_evaluator = 2,
            cadence = CorePotts.PeriodicMCSCadence, cadence_value = 2, state_rule_count = 1, scalar_type = Float32
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
    maximum_requests = sum(lifecycle_descriptors) do descriptor
        descriptor.domain === CorePotts.ModelLifecycleDomain ? 1 : cell_capacity
    end
    return CorePotts.LifecycleExecutionPlan(
        lifecycle_descriptors, evaluators, CorePotts.LifecycleStateRuleStorage([rule]),
        CorePotts.LifecycleRelationshipRule[], (), NTuple{2, Int16}[],
        CorePotts.LifecycleRelationStorage((), Val(2)), CorePotts.StablePriorityLifecycleConflicts,
        cell_capacity, maximum_requests, 1, 0, falses(3),
    )
end

function test_lifecycle_identity_preparation()
    for cell_capacity in (2, 6), (action, effect) in (
                (CorePotts.InitializeLifecycleState, CorePotts.CreateCellLifecycleEffect),
                (CorePotts.ResetLifecycleState, CorePotts.TransitionCellLifecycleEffect),
            )
        plan = cell_stage_lifecycle_plan(CorePotts.StateHandle(1); action, effect, cell_capacity)
        @test_nowarn CorePotts.allocate_lifecycle_backend_control(plan, Float32[], 36)
    end
    return
end

function test_lifecycle_identity_capacity(engine; adapt_to = identity)
    cases = (
        (name = "recycled identity", kinds = Int16[2, 0, 2, 0, 0, 0], generations = UInt32[1, 7, 1, 0, 0, 0], other = 3, created = 2),
        (name = "virgin identity", kinds = Int16[2, 2, 0, 0, 0, 0], generations = UInt32[1, 1, 0, 0, 0, 0], other = 2, created = 3),
        (name = "unavailable identity holes", kinds = Int16[2, 0, 0, 0, 0, 2], generations = UInt32[1, 0, 0, 0, 0, 1], other = 6, created = 0),
    )
    for case in cases
        @testset "$(case.name)" begin
            ownership = ones(Int32, 6, 6)
            ownership[35] = case.other
            ownership[36] = -1
            host, handle = cell_stage_lifecycle_runtime(
                engine;
                cell_capacity = 6, initial_kinds = case.kinds,
                initial_generations = case.generations, ownership,
            )
            runtime = adapt_to === identity ? host : CorePotts.adapt_program_runtime(adapt_to, host)
            CorePotts.advance_mcs!(runtime)
            @test !CorePotts.program_failed(runtime)
            before = CorePotts.program_snapshot(runtime)
            before_receipt = CorePotts.program_lifecycle_receipt(runtime)
            @test before.cell_kinds == case.kinds
            @test before.cell_generations == case.generations
            CorePotts.advance_mcs!(runtime)
            after = CorePotts.program_snapshot(runtime)
            if iszero(case.created)
                @test CorePotts.program_failed(runtime)
                failure = CorePotts.program_failure_report(runtime)
                @test failure.code === CorePotts.ProgramStatusCellCapacity
                @test failure.maximum == 6
                @test failure.available == 0
                @test after.mcs == before.mcs
                @test after.ownership == before.ownership
                @test after.cell_kinds == before.cell_kinds
                @test after.cell_generations == before.cell_generations
                @test after.trackers.values == before.trackers.values
                @test CorePotts.state_block(after.descriptor_state, handle).values ==
                    CorePotts.state_block(before.descriptor_state, handle).values
                after_receipt = CorePotts.program_lifecycle_receipt(runtime)
                @test after_receipt.completed_mcs == before_receipt.completed_mcs
                @test collect(after_receipt) == collect(before_receipt)
            else
                @test !CorePotts.program_failed(runtime)
                expected_kinds = copy(case.kinds)
                expected_kinds[case.created] = 2
                expected_generations = copy(case.generations)
                expected_generations[case.created] += UInt32(1)
                expected_values = [kind == 2 ? 5.0f0 : 1.0f0 for kind in case.kinds]
                expected_values[case.created] = 11.0f0
                @test after.mcs == 2
                @test after.cell_kinds == expected_kinds
                @test after.cell_generations == expected_generations
                @test after.ownership[36] == case.created
                @test CorePotts.state_block(after.descriptor_state, handle).values == expected_values
                @test count(
                    event -> event isa CorePotts.CreateLifecycleEvent,
                    CorePotts.program_lifecycle_receipt(runtime)
                ) == 1
            end
        end
    end
    return
end
