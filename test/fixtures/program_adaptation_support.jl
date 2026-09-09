isdefined(@__MODULE__, :test_program) || include("compiled_program_support.jl")
isdefined(@__MODULE__, :_structured_stage_runtime) || include("structured_stage_support.jl")
isdefined(@__MODULE__, :receipt_descriptor) || include("lifecycle_descriptor_support.jl")

function _test_adaptation_publication(runtime, expected, parameters, handles)
    C = CorePotts
    actual = C.program_snapshot(runtime)
    @test actual.mcs == expected.mcs
    @test actual.ownership == expected.ownership
    @test actual.cell_kinds == expected.cell_kinds
    @test actual.cell_generations == expected.cell_generations
    @test actual.trackers.values == expected.trackers.values
    @test _structured_stage_values(actual, handles) == _structured_stage_values(expected, handles)
    return @test runtime.parameters == parameters
end

function _test_program_adaptation_independence(to)
    C = CorePotts
    source, handles = _structured_stage_runtime(
        C.CheckerboardProgramEngine(), 1.0f0, 2.0f0; parameter_defaults = Float32[2],
    )
    C.advance_mcs!(source)
    original = C.program_snapshot(source)
    adapted = C.adapt_program_runtime(to, source)
    sibling = C.adapt_program_runtime(to, adapted)
    for runtime in (source, adapted, sibling)
        _test_adaptation_publication(runtime, original, Float32[2], handles)
        @test C._program_counter_snapshot(runtime) == C._program_counter_snapshot(source)
        @test (runtime.seed, runtime.replica, runtime.repeat) == (source.seed, source.replica, source.repeat)
        @test C.program_lifecycle_receipt(runtime).transaction_identity == C.program_lifecycle_receipt(source).transaction_identity
    end
    for gain in (3.0f0, 4.0f0)
        before = C.program_snapshot(adapted)
        parameters_before = copy(adapted.parameters)
        aborted = C.stage_program_mcs!(adapted)
        state = C.copy_auxiliary_state(C.program_step_snapshot(aborted).descriptor_state)
        fill!(C.state_block(state, handles[1]).values, gain)
        fill!(C.state_block(state, handles[2]).values, 2gain)
        C.stage_program_descriptor_state!(aborted, state)
        C.stage_program_parameters!(aborted, Float32[gain])
        C.prevalidate_program_step_transaction(aborted)
        _test_adaptation_publication(source, original, Float32[2], handles)
        _test_adaptation_publication(sibling, original, Float32[2], handles)
        C.abort_program_step!(aborted)
        _test_adaptation_publication(adapted, before, parameters_before, handles)
        committed = C.stage_program_mcs!(adapted)
        C.stage_program_descriptor_state!(committed, state)
        C.stage_program_parameters!(committed, Float32[gain])
        C.commit_program_step!(committed)
        @test adapted.mcs == before.mcs + 1
        @test adapted.parameters == Float32[gain]
        @test _structured_stage_values(C.program_snapshot(adapted), handles) == Float32[gain, 2gain]
        _test_adaptation_publication(source, original, Float32[2], handles)
        _test_adaptation_publication(sibling, original, Float32[2], handles)
    end
    published = C.program_snapshot(adapted)
    C.advance_mcs!(source)
    @test _structured_stage_values(C.program_snapshot(source), handles) == Float32[1, 2]
    _test_adaptation_publication(adapted, published, Float32[4], handles)
    _test_adaptation_publication(sibling, original, Float32[2], handles)
    source_after = C.program_snapshot(source)
    C.advance_mcs!(sibling)
    _test_adaptation_publication(sibling, source_after, Float32[2], handles)
    _test_adaptation_publication(source, source_after, Float32[2], handles)
    _test_adaptation_publication(adapted, published, Float32[4], handles)

    returned = C.adapt_program_runtime(Array, adapted)
    report = returned.capability_report
    @test report.key.backend === C.CPUBackend
    @test C.capability_authorizes_execution(report)
    _test_adaptation_publication(returned, published, Float32[4], handles)
    transaction = C.stage_program_mcs!(returned)
    state = C.copy_auxiliary_state(C.program_step_snapshot(transaction).descriptor_state)
    fill!(C.state_block(state, handles[1]).values, 6.0f0)
    fill!(C.state_block(state, handles[2]).values, 12.0f0)
    C.stage_program_descriptor_state!(transaction, state)
    C.stage_program_parameters!(transaction, Float32[6])
    C.commit_program_step!(transaction)
    @test returned.mcs == published.mcs + 1
    @test returned.parameters == Float32[6]
    @test _structured_stage_values(C.program_snapshot(returned), handles) == Float32[6, 12]
    C.advance_mcs!(returned)
    @test returned.mcs == published.mcs + 2
    @test _structured_stage_values(C.program_snapshot(returned), handles) == Float32[12, 6]
    _test_adaptation_publication(adapted, published, Float32[4], handles)
    _test_adaptation_publication(source, source_after, Float32[2], handles)
    _test_adaptation_publication(sibling, source_after, Float32[2], handles)

    failed, failed_handles = _structured_stage_runtime(
        C.CheckerboardProgramEngine(), 1.0f0, 2.0f0;
        after_transform = NonfiniteStructuredStageValue(),
    )
    C.advance_mcs!(failed)
    @test C.program_failed(failed)
    failed_snapshot = C.program_snapshot(failed)
    failed_copy = C.adapt_program_runtime(to, failed)
    @test C.program_failed(failed_copy)
    @test C.program_failure_report(failed_copy).code === C.program_failure_report(failed).code
    @test C._program_counter_snapshot(failed_copy) == C._program_counter_snapshot(failed)
    @test C.program_lifecycle_receipt(failed_copy) === nothing
    _test_adaptation_publication(failed_copy, failed_snapshot, Float32[], failed_handles)
    return _test_adaptation_publication(failed, failed_snapshot, Float32[], failed_handles)
end

function _test_lifecycle_adaptation_independence(to)
    C = CorePotts
    descriptor = receipt_descriptor(
        1, C.RemoveCellLifecycleEffect;
        domain_kind = 2, scalar_type = Float32
    )
    plan = C.LifecycleExecutionPlan(
        [descriptor],
        C.LifecycleEvaluatorStorage(
            Any[C.StaticEvaluator(C.LiteralExpression(true))], [:lifecycle_trigger]
        ),
        C.LifecycleStateRuleStorage(Any[]), C.LifecycleRelationshipRule[], (),
        NTuple{2, Int16}[], C.LifecycleRelationStorage((), Val(2)),
        C.StablePriorityLifecycleConflicts, 1, 1, 1, 0, falses(2),
    )
    program = test_program(
        C.CheckerboardProgramEngine();
        scalar_type = Float32, lifecycle_plan = plan,
        descriptor_plan = empty_descriptor_plan(; source_table = Any[:remove_cell])
    )
    initial = C.ProgramInitialState(ones(Int32, 6, 6), Int16[2]; scalar_type = Float32)
    source = C.initialize_program(program, initial, Float32[], UInt64(0x8137), UInt32(1))
    before = C.program_snapshot(source)
    adapted = C.adapt_program_runtime(to, source)
    sibling = C.adapt_program_runtime(to, adapted)
    C.advance_mcs!(source)
    settled = C.program_snapshot(source)
    @test all(==(Int32(-1)), settled.ownership) # removal replaces the cell with medium kind 1
    @test all(iszero, settled.cell_kinds)
    @test length(C.lifecycle_events(C.program_lifecycle_receipt(source))) == 1
    _test_adaptation_publication(adapted, before, Float32[], ())
    _test_adaptation_publication(sibling, before, Float32[], ())
    aborted = C.stage_program_mcs!(adapted)
    C.prevalidate_program_step_transaction(aborted)
    C.abort_program_step!(aborted)
    _test_adaptation_publication(adapted, before, Float32[], ())
    _test_adaptation_publication(sibling, before, Float32[], ())
    _test_adaptation_publication(source, settled, Float32[], ())
    C.commit_program_step!(C.stage_program_mcs!(adapted))
    _test_adaptation_publication(adapted, settled, Float32[], ())
    @test C._program_counter_snapshot(adapted) == C._program_counter_snapshot(source)
    @test C.lifecycle_events(C.program_lifecycle_receipt(adapted)) == C.lifecycle_events(C.program_lifecycle_receipt(source))
    _test_adaptation_publication(sibling, before, Float32[], ())
    C.advance_mcs!(sibling)
    _test_adaptation_publication(sibling, settled, Float32[], ())
    return _test_adaptation_publication(source, settled, Float32[], ())
end
