isdefined(@__MODULE__, :test_program) || include("compiled_program_support.jl")
isdefined(@__MODULE__, :receipt_descriptor) || include("lifecycle_descriptor_support.jl")

function history_lifecycle_program(engine, invalid_sample; expression = nothing)
    C = CorePotts
    schemas = map(((:source, :cell, (2,)), (:memory, :history, (2, 3)))) do (name, domain, shape)
        C.StateBlockSchema(
            C.QualifiedResourceIdentity((), name), v"1.0.0", domain,
            Float32, shape, prod(shape), :structure_of_arrays, :provided_or_zero,
            :shape_and_finite, :logical, :declared, :declared, :bounded_write,
            :adapt_storage, :copy, :logical_copy, :qualified, true
        )
    end
    layout = C.StateLayout(collect(schemas))
    handle(name) = only(entry.handle for entry in layout.entries if entry.schema.identity.name === name)
    source, memory = handle(:source), handle(:memory)
    history = C.CompiledStageDescriptor(
        C.StaticEvaluator(C.LiteralExpression(true)), C.StaticEvaluator(C.LiteralExpression(0.0f0)),
        C.ShiftAppendEffect(memory, source, 2; cadence = C.PeriodicMCSCadence, cadence_value = 100),
        C.AfterMCSStage(), C.ResourceAccess((source, memory), (memory,), C.OwnerFootprint(), C.OwnerFootprint(), C.ExclusiveWriteAccess()),
        C.DescriptorSupport(true, true, true, true), 1, 0,
    )
    stages = C.StageExecutionPlan((), (), (C.StageDescriptorGroup([history]),), 0, 0, "retained-cell-samples")
    reject = C.ProposalDescriptor(
        C.StaticEvaluator(C.LiteralExpression(false)),
        C.ResourceAccess((), (), C.EmptyFootprint(), C.EmptyFootprint(), C.NoWriteAccess()),
        C.DescriptorSupport(true, true, true, true), (), (), C.ProposalConstraintRole(), 1
    )
    descriptors = C.DescriptorExecutionPlan(
        (C.ProposalDescriptorGroup([reject], (), (), :unsplit),),
        layout, C.WorkspaceLayout(C.WorkspaceSchema[]), (), Any[:retained_cell_state], 0,
        "retained-cell-state", C.HamiltonianDomainResources(0, 0)
    )
    transform = receipt_descriptor(
        1, C.TransitionCellLifecycleEffect; domain_kind = 2,
        destination_kind = 3, state_rule_count = 1, scalar_type = Float32
    )
    evaluators = C.LifecycleEvaluatorStorage(
        Any[
            C.StaticEvaluator(C.LiteralExpression(true)),
            C.StaticEvaluator(
                expression === nothing ?
                    C.LiteralExpression(invalid_sample < 0 ? 4.0f0 : NaN32) : expression
            ),
        ], [:lifecycle_trigger, :lifecycle_state_transform]
    )
    rule = C.LifecycleStateRule(
        memory, UInt64(1), C.TransformLifecycleState,
        Int32(2), Int32(0), Int32(0), Int32(0), 0.0f0, C.ExactLifecycleRounding,
        UInt8(0), UInt8(0), C.RNGOperationKey(), C.RNGOperationKey()
    )
    lifecycle = C.LifecycleExecutionPlan(
        [transform], evaluators, C.LifecycleStateRuleStorage([rule]),
        C.LifecycleRelationshipRule[], (), NTuple{2, Int16}[], C.LifecycleRelationStorage((), Val(2)),
        C.StablePriorityLifecycleConflicts, 1, 1, 1, 0, falses(3)
    )
    offsets = Int8[1 -1 0 0; 0 0 1 -1]
    checkerboard_plan = engine isa C.CheckerboardProgramEngine ?
        C.CheckerboardPlan((6, 6), (true, true), offsets) : C.NoCheckerboardPlan()
    program = C.CompiledPottsProgram(
        (6, 6), (true, true), offsets, 3, 1, C.CompiledScalar(0.0f0), 1,
        Float32[], (), C.TrackerExecutionPlan((C.OwnershipCountTracker(),), "retained-cell-count"),
        descriptors, stages, engine, C.CPUProgramBackend(), "retained-cell-lifecycle";
        lifecycle_plan = lifecycle, checkerboard_plan,
    )
    initial_values = map(layout.entries) do entry
        entry.handle == source ? Float32[8, 0] : Float32[1 2 3; 10 20 30]
    end
    base = test_initial(Float32)
    initial = C.ProgramInitialState(
        base.ownership, base.cell_kinds; scalar_type = Float32,
        descriptor_state = C.allocate_auxiliary_state(layout, initial_values)
    )
    return C.initialize_program(program, initial, Float32[], UInt64(17), UInt32(1)), memory
end

function test_history_lifecycle_transactions(
        engines; adapt_runtime = identity, check_checkpoint = true,
    )
    C = CorePotts
    for engine in engines
        host, memory = history_lifecycle_program(engine, -1.0f0)
        runtime = adapt_runtime(host)
        C.advance_mcs!(runtime)
        @test !C.program_failed(runtime)
        after = C.program_snapshot(runtime)
        expected_history = Float32[4 4 4; 10 20 30]
        @test after.mcs == 1
        @test C.state_block(after.descriptor_state, memory).values == expected_history
        @test after.cell_kinds == Int16[3]
        @test after.cell_generations == UInt32[1]
        events = C.lifecycle_events(C.program_lifecycle_receipt(runtime))
        @test length(events) == 1
        @test only(events) isa C.TransitionLifecycleEvent

        if check_checkpoint
            continued_host = C.restore_program_checkpoint(
                runtime.program, C.program_checkpoint(runtime)
            )
            continued = adapt_runtime(continued_host)
            C.advance_mcs!(continued)
            continued_state = C.program_snapshot(continued)
            @test !C.program_failed(continued)
            @test continued_state.mcs == 2
            @test C.state_block(continued_state.descriptor_state, memory).values == expected_history
            @test continued_state.cell_kinds == after.cell_kinds
            @test continued_state.cell_generations == after.cell_generations
            @test isempty(C.program_lifecycle_receipt(continued))
        end

        failed_host, failed_memory = history_lifecycle_program(engine, 3.0f0)
        failed = adapt_runtime(failed_host)
        before = C.program_snapshot(failed)
        C.advance_mcs!(failed)
        @test C.program_failed(failed)
        @test failed.settled
        after_failure = C.program_snapshot(failed)
        @test C.state_block(after_failure.descriptor_state, failed_memory).values ==
            C.state_block(before.descriptor_state, failed_memory).values
        @test after_failure.mcs == before.mcs == 0
        @test after_failure.ownership == before.ownership
        @test after_failure.cell_kinds == before.cell_kinds
        @test after_failure.cell_generations == before.cell_generations
        @test after_failure.trackers.values == before.trackers.values
        @test C.program_failure_report(failed).detail === C.LifecycleDetailNonfiniteResult
        @test C.program_lifecycle_receipt(failed) === nothing
    end
    return
end
