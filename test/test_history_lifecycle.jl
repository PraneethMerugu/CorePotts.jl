using Test
import CorePotts
include("fixtures/lifecycle_descriptor_support.jl")

struct HistorySampleIncrement <: CorePotts.AbstractContextualOperation end
CorePotts.operation_context_supported(::HistorySampleIncrement, ::Type{CorePotts.AbstractLifecycleStateTransformEvaluationContext}) = true
@inline function (::HistorySampleIncrement)(arguments, context)
    before = CorePotts.lifecycle_before_state_value(context)
    planned = CorePotts.lifecycle_planned_state_value(context)
    before == planned || return NaN32
    CorePotts.lifecycle_occurrence(context) == 3 - before || return NaN32
    CorePotts.lifecycle_source_cell(context) == 1 || return NaN32
    CorePotts.lifecycle_source_generation(context) == 1 || return NaN32
    return before == only(arguments) ? NaN32 : before + 1.0f0
end

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
                    C.OperationExpression(HistorySampleIncrement(), C.LiteralExpression(invalid_sample)) : expression
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

@testset "stochastic retained-state policies require a declared sample correlation" begin
    C = CorePotts
    key = only(C.rng_operation_keys(((namespace = C.RNGNamespace((UInt64(1), UInt64(2))), identity = "history-test-draw"),)))
    expression = C.OperationExpression(
        C.operation_callable(Val(:draw), v"1.0.0"),
        C.LiteralExpression(UInt8(2)), C.LiteralExpression(0.0f0),
        C.LiteralExpression(1.0f0), C.LiteralExpression(key)
    )
    @test_throws r"retained-sample correlation" history_lifecycle_program(C.SequentialProgramEngine(), -1.0f0; expression)
end

@testset "history lifecycle transforms retain cell identity and roll back late samples" begin
    C = CorePotts
    for engine in (C.SequentialProgramEngine(), C.CheckerboardProgramEngine())
        runtime, memory = history_lifecycle_program(engine, -1.0f0)
        C.advance_mcs!(runtime)
        @test !C.program_failed(runtime)
        after = C.program_snapshot(runtime)
        @test C.state_block(after.descriptor_state, memory).values == Float32[2 3 4; 10 20 30]
        @test after.cell_kinds == Int16[3]
        @test after.cell_generations == UInt32[1]
        failed, failed_memory = history_lifecycle_program(engine, 3.0f0)
        before = C.program_snapshot(failed)
        C.advance_mcs!(failed)
        @test C.program_failed(failed)
        after_failure = C.program_snapshot(failed)
        @test C.state_block(after_failure.descriptor_state, failed_memory).values ==
            C.state_block(before.descriptor_state, failed_memory).values
        @test after_failure.mcs == before.mcs == 0
        @test after_failure.ownership == before.ownership
        @test after_failure.cell_kinds == before.cell_kinds
        @test after_failure.cell_generations == before.cell_generations
        @test C.program_failure_report(failed).detail === C.LifecycleDetailNonfiniteResult
    end
end

@testset "planned lifecycle state reads the candidate for ordinary and retained state" begin
    C = CorePotts
    runtime, memory = history_lifecycle_program(C.SequentialProgramEngine(), -1.0f0)
    source = only(entry.handle for entry in runtime.program.descriptor_plan.state_layout.entries if entry.schema.identity.name === :source)
    workspace = runtime.lifecycle_workspace
    C.state_block(workspace.staged_descriptor_state, source).values .= Float32[81, 0]
    C.state_block(workspace.staged_descriptor_state, memory).values .= Float32[11 12 13; 10 20 30]
    planned = C._LifecycleRequestView(runtime, workspace, only(runtime.program.lifecycle_plan.descriptors), Int32(1))
    function context(handle, lag)
        C._LifecycleStateContext(
            runtime, planned, UInt64(101), UInt64(201),
            Int32(0), Int32(0), Int32(1), Int32(1), UInt32(1),
            Int32(1), UInt32(1), Int32(0), UInt32(0), C.SourceLifecycleStateRole,
            UInt64(1), handle, CartesianIndex(3, 3), Int32(lag)
        )
    end
    @test C.lifecycle_before_state_value(context(source, 0)) === 8.0f0
    @test C.lifecycle_planned_state_value(context(source, 0)) === 81.0f0
    for lag in 0:2
        @test C.lifecycle_before_state_value(context(memory, lag)) === Float32(3 - lag)
        @test C.lifecycle_planned_state_value(context(memory, lag)) === Float32(13 - lag)
    end
    @test C.state_block(runtime.descriptor_state, memory).values == Float32[1 2 3; 10 20 30]
end
