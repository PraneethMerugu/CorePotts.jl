using Test
import CorePotts
include("fixtures/lifecycle_descriptor_support.jl")

function _history_sample_schema(name, domain, shape)
    return CorePotts.StateBlockSchema(
        CorePotts.QualifiedResourceIdentity((:history_samples,), name), v"1.0.0",
        domain, Float32, shape, prod(shape), :structure_of_arrays,
        :provided_or_zero, :shape_and_finite, :logical, :preserve, :declared,
        :bounded_write, :adapt_storage, :copy, :logical_copy, :qualified, true,
    )
end


function _initial_history_program(engine)
    C = CorePotts
    layout = C.StateLayout(
        [
            _history_sample_schema(:source, :model, ()),
            _history_sample_schema(:initial_history, :history, (1, 3)),
            _history_sample_schema(:periodic_history, :history, (1, 3)),
        ]
    )
    handle(name) = only(entry.handle for entry in layout.entries if entry.schema.identity.name === name)
    source = handle(:source)
    initial_history, periodic_history = handle(:initial_history), handle(:periodic_history)
    function capture(target, cadence, value)
        return C.CompiledStageDescriptor(
            C.StaticEvaluator(C.LiteralExpression(true)), C.StaticEvaluator(C.LiteralExpression(0.0f0)),
            C.ShiftAppendEffect(target, source, 2; cadence, cadence_value = value), C.AfterMCSStage(),
            C.ResourceAccess((target, source), (target,), C.ModelFootprint(), C.ModelFootprint(), C.ExclusiveWriteAccess()),
            C.DescriptorSupport(true, true, true, true), 1, 0,
        )
    end
    # One provenance handle deliberately describes both cadences and the
    # ordinary update. Initialization selection must use the actual effect.
    histories = [capture(initial_history, C.AtMCSCadence, 0), capture(periodic_history, C.EveryMCSCadence, 1)]
    read = C.OperationExpression(C.operation_callable(Val(:model_bound_state_value), v"1.0.0"), C.StateExpression(source))
    assignment = C.CompiledStageDescriptor(
        C.StaticEvaluator(C.LiteralExpression(true)), C.StaticEvaluator(C.OperationExpression(+, read, C.LiteralExpression(1.0f0))),
        C.ModelAssignmentEffect(source), C.AfterMCSStage(),
        C.ResourceAccess((source,), (source,), C.ModelFootprint(), C.ModelFootprint(), C.ExclusiveWriteAccess()),
        C.DescriptorSupport(true, true, true, true), 1, 1,
    )
    stage_plan = C.StageExecutionPlan((), (C.StageDescriptorGroup([assignment]), C.StageDescriptorGroup(histories)), (), 0, 0, "initial-history")
    descriptor_plan = C.DescriptorExecutionPlan((), layout, C.WorkspaceLayout(C.WorkspaceSchema[]), (), Any[:history_owner], 0, "initial-history", C.HamiltonianDomainResources(0, 0))
    program = test_program(engine; descriptor_plan, stage_plan, scalar_type = Float32)
    base = test_initial(Float32)
    state = C.allocate_auxiliary_state(
        layout, map(layout.entries) do entry
            name = entry.schema.identity.name
            name === :source ? fill(7.0f0) : reshape(name === :initial_history ? Float32[1, 2, 3] : Float32[4, 5, 6], 1, 3)
        end
    )
    initial = C.ProgramInitialState(base.ownership, base.cell_kinds; scalar_type = Float32, descriptor_state = state)
    return (; program, initial, source, initial_history, periodic_history)
end

@testset "initial history capture preserves prehistory and does not execute a boundary" begin
    C = CorePotts
    for engine in (C.SequentialProgramEngine(), C.CheckerboardProgramEngine())
        (; program, initial, source, initial_history, periodic_history) = _initial_history_program(engine)
        runtime = C.initialize_program(program, initial, Float32[], UInt64(17), UInt32(1))
        values(handle) = vec(C.state_block(C.program_snapshot(runtime).descriptor_state, handle).values)
        @test values(source) == Float32[7]
        @test values(initial_history) == Float32[1, 2, 7]
        @test values(periodic_history) == Float32[4, 5, 6]
        @test runtime.mcs == 0
        @test (runtime.accepted, runtime.rejected, runtime.null_attempts, runtime.retired_cells) == (0, 0, 0, 0)
        changed = C.copy_auxiliary_state(runtime.descriptor_state)
        fill!(C.state_block(changed, source).values, 17.0f0)
        C.update_program_descriptor_state!(runtime, changed)
        restored = C.restore_program_checkpoint(program, C.program_checkpoint(runtime))
        @test vec(C.state_block(restored.descriptor_state, initial_history).values) == Float32[1, 2, 7]
        @test only(C.state_block(restored.descriptor_state, source).values) == 17.0f0
        C.advance_mcs!(runtime)
        @test values(source) == Float32[18]
        @test values(initial_history) == Float32[1, 2, 7]
        @test values(periodic_history) == Float32[5, 6, 18]
        @test_throws r"MCS-zero" C.initialize_history!(runtime)
        deferred = C.initialize_program(program, initial, Float32[], UInt64(17), UInt32(1); capture_initial_history = false)
        @test vec(C.state_block(deferred.descriptor_state, initial_history).values) == Float32[1, 2, 3]
        changed = C.copy_auxiliary_state(deferred.descriptor_state)
        fill!(C.state_block(changed, source).values, 11.0f0)
        copyto!(C.state_block(changed, initial_history).values, reshape(Float32[20, 30, 40], 1, 3))
        C.update_program_descriptor_state!(deferred, changed)
        C.initialize_history!(deferred)
        @test vec(C.state_block(deferred.descriptor_state, initial_history).values) == Float32[20, 30, 11]
        @test vec(C.state_block(deferred.descriptor_state, periodic_history).values) == Float32[4, 5, 6]
        nonzero = C.initialize_program(program, initial, Float32[], UInt64(17), UInt32(1); initial_mcs = 3)
        @test vec(C.state_block(nonzero.descriptor_state, initial_history).values) == Float32[1, 2, 3]
    end
end

@testset "failed initialization abandons a sampled candidate without publishing MCS zero" begin
    C = CorePotts
    (; program, initial, initial_history) = _initial_history_program(C.CheckerboardProgramEngine())
    runtime = C.initialize_program(program, initial, Float32[], UInt64(17), UInt32(1); capture_initial_history = false)
    before = C.program_snapshot(runtime)
    execution = runtime.engine_workspace
    workspace = execution.core
    _, candidate, _ = C._checkerboard_transaction_banks(workspace, 0)
    initial_entry = only(entry for entry in execution.stage_boundaries.before if entry.effect isa C.ShiftAppendEffect && entry.effect.cadence === C.AtMCSCadence)
    C._clear_checkerboard_bulk!(execution, candidate; completed_mcs = 0)
    C._execute_compiled_stage_boundary!(execution, (initial_entry,), candidate; completed_mcs = 0)
    candidate_receipt = C.settle_program!(execution, C.ProgramSettlementRequest(C.InitializationSettlement; full_snapshot = true))
    @test vec(C.state_block(candidate_receipt.snapshot.descriptor_state, initial_history).values) == Float32[1, 2, 7]
    @test vec(C.state_block(runtime.descriptor_state, initial_history).values) == Float32[1, 2, 3]
    # Inject an expected device status after actual candidate work. This uses
    # the owning status protocol, without poisoning a LocalMath provider scope.
    workspace.state.program_status[1] = C.ProgramStatus(
        C.ProgramStatusEvaluator, Int32(0), C.ProgramStageState, Int32(1), UInt64(0), Int32(0), Int32(0),
        C.LifecycleDetailNonfiniteResult, Int32(0), Int32(0), Int32(0),
    )
    @test_throws C.AbstractLifecycleFailure C.initialize_history!(runtime)
    @test C.program_failure_report(runtime).mcs == 0
    @test runtime.settled
    after = C.program_snapshot(runtime)
    @test after.mcs == before.mcs == 0
    @test after.ownership == before.ownership
    @test after.cell_kinds == before.cell_kinds
    @test vec(C.state_block(after.descriptor_state, initial_history).values) == Float32[1, 2, 3]
    @test (runtime.accepted, runtime.rejected, runtime.null_attempts, runtime.retired_cells) == (0, 0, 0, 0)
    @test_throws C.LifecycleInvariantFailure C.settle_program!(execution, C.ProgramSettlementRequest(C.PublicStepSettlement; full_snapshot = true))
end

function _history_sample_fixture(domain, source_shape, depth)
    physical_shape = isempty(source_shape) ? (1,) : source_shape
    history_shape = (physical_shape..., depth)
    layout = CorePotts.StateLayout(
        [
            _history_sample_schema(:source, domain, source_shape), _history_sample_schema(:history, :history, history_shape),
        ]
    )
    source = only(entry.handle for entry in layout.entries if entry.schema.domain === domain)
    history = only(entry.handle for entry in layout.entries if entry.schema.domain === :history)
    footprint = domain === :model ? CorePotts.ModelFootprint() : domain === :cell ? CorePotts.OwnerFootprint() :
        CorePotts.FiniteSpatialFootprint(CorePotts.IterationSiteFootprintAnchor(), (ntuple(_ -> 0, length(source_shape)),))
    descriptor = CorePotts.CompiledStageDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(0.0f0)),
        CorePotts.ShiftAppendEffect(history, source, length(history_shape)), CorePotts.AfterMCSStage(),
        CorePotts.ResourceAccess((history, source), (history,), footprint, footprint, CorePotts.ExclusiveWriteAccess()),
        CorePotts.DescriptorSupport(true, true, true, true), 1, 0,
    )
    return (; layout, source, history, descriptor)
end

@testset "history reads select bounded whole samples without copying" begin
    @test_throws r"history.*dimensions.*Int32" _history_sample_fixture(:cell, (0,), Int64(typemax(Int32)) + 1)
    for (domain, shape) in ((:model, ()), (:cell, (3,)), (:site, (2, 3)), (:cell, (0,)))
        fixture = _history_sample_fixture(domain, shape, 257)
        (; layout, source, history, descriptor) = fixture
        descriptors = (descriptor,)
        source_entry = CorePotts.CompilerSPI.history_source(descriptors, layout, history)
        @test source_entry.handle == source
        state = CorePotts.allocate_auxiliary_state(
            layout, map(layout.entries) do entry
                values = zeros(Float32, entry.schema.shape)
                if entry.schema.domain === :history
                    for sample in 1:257
                        fill!(selectdim(values, ndims(values), sample), sample)
                    end
                end
                values
            end
        )
        for lag in (0, 1, 256)
            projected = CorePotts.CompilerSPI.history_sample_handle(descriptors, layout, history, lag)
            @test CorePotts.CompilerSPI.state_read_source(descriptors, layout, projected).handle == source
            values = CorePotts.state_block(state, projected).values
            @test size(values) == shape
            @test all(==(Float32(257 - lag)), values)
            if !isempty(values)
                @test values.storage === CorePotts.state_block(state, history).values.storage
            end
        end
        for lag in (true, -1, 257)
            @test_throws ArgumentError CorePotts.CompilerSPI.history_sample_handle(descriptors, layout, history, lag)
        end
        @test_throws ArgumentError CorePotts.CompilerSPI.history_source((), layout, history)
        @test_throws ArgumentError CorePotts.CompilerSPI.history_source((:not_a_descriptor,), layout, history)
        @test_throws ArgumentError CorePotts.CompilerSPI.history_source((descriptor, descriptor), layout, history)
        projected = CorePotts.CompilerSPI.history_sample_handle(descriptors, layout, history, 0)
        invalid = CorePotts.StateHandle(CorePotts.handle_representation(history), history.bank, history.slot, Int(history.location.offset) + prod(CorePotts.handle_shape(history)) + 1, shape)
        @test_throws ArgumentError CorePotts._history_read_source(descriptors, layout, invalid)
        invalid_slot = CorePotts.StateHandle(CorePotts.handle_representation(history), history.bank, history.slot + 1, Int(projected.location.offset), shape)
        @test_throws ArgumentError CorePotts._history_read_source(descriptors, layout, invalid_slot)
    end
end

function _history_feedback_program(engine; extra_write = false, projected_target = false, ownership_write = false, constraint_read = nothing, lifecycle_write = false)
    C = CorePotts
    fixture = _history_sample_fixture(:model, (), 3)
    (; layout, source, history, descriptor) = fixture
    samples = ntuple(lag -> C.CompilerSPI.history_sample_handle((descriptor,), layout, history, lag - 1), 2)
    read(handle) = C.OperationExpression(C.operation_callable(Val(:model_bound_state_value), v"1.0.0"), C.StateExpression(handle))
    expression = C.OperationExpression(+, read(samples[1]), C.OperationExpression(*, C.LiteralExpression(10.0f0), read(samples[2])))
    target = projected_target ? samples[1] : source
    writes = extra_write ? (target, samples[1]) : (target,)
    assignment = C.CompiledStageDescriptor(
        C.StaticEvaluator(C.LiteralExpression(true)), C.StaticEvaluator(expression),
        C.ModelAssignmentEffect(target), C.AfterMCSStage(),
        C.ResourceAccess(samples, writes, C.ModelFootprint(), C.ModelFootprint(), C.ExclusiveWriteAccess()),
        C.DescriptorSupport(true, true, true, true), 2, 1,
    )
    stage_plan = C.StageExecutionPlan(
        (), (C.StageDescriptorGroup([assignment]), C.StageDescriptorGroup([descriptor])), (), 0, 0, "history-feedback",
    )
    constraints = constraint_read === nothing ? () : (
            C.ConstraintGroup([C.ParameterDomainConstraint(C.StaticEvaluator(read(constraint_read)), UInt8(1), Int32(2))]),
        )
    descriptor_plan = C.DescriptorExecutionPlan(
        (), layout, C.WorkspaceLayout(C.WorkspaceSchema[]), constraints, Any[:history, :feedback], 0,
        "history-feedback", C.HamiltonianDomainResources(0, 0),
    )
    lifecycle_plan = if lifecycle_write
        rule = C.LifecycleStateRule(
            samples[1], UInt64(1), C.RetireToLifecycleState, Int32(1), Int32(0), Int32(0), Int32(0),
            0.5f0, C.ExactLifecycleRounding, UInt8(0), UInt8(0), C.RNGOperationKey(), C.RNGOperationKey(),
        )
        C.LifecycleExecutionPlan(
            [receipt_descriptor(1, C.RemoveCellLifecycleEffect; domain_kind = 2, state_rule_count = 1, scalar_type = Float32)],
            C.LifecycleEvaluatorStorage([C.StaticEvaluator(C.LiteralExpression(true))], [:lifecycle_trigger]),
            C.LifecycleStateRuleStorage([rule]), C.LifecycleRelationshipRule[], (), NTuple{2, Int16}[],
            C.LifecycleRelationStorage((), Val(2)), C.RejectLifecycleConflicts, 1, 1, 1, 0, falses(2),
        )
    else
        C.NoLifecycleExecutionPlan()
    end
    program = test_program(
        engine; descriptor_plan, stage_plan, lifecycle_plan, scalar_type = Float32,
        ownership_change_handles = ownership_write ? (samples[1],) : ()
    )
    return (; program, fixture, samples)
end

@testset "history projections are read-only at complete program admission" begin
    C = CorePotts
    for engine in (C.SequentialProgramEngine(), C.CheckerboardProgramEngine())
        @test _history_feedback_program(engine).program isa C.CompiledPottsProgram
        @test_throws r"canonical layout handle" _history_feedback_program(engine; extra_write = true)
        @test_throws r"canonical layout handle" _history_feedback_program(engine; projected_target = true)
        @test_throws r"canonical layout handle" _history_feedback_program(engine; ownership_write = true)
        @test_throws r"canonical layout handle" _history_feedback_program(engine; lifecycle_write = true)
        fixture = _history_sample_fixture(:model, (), 3)
        forged = C.StateHandle(C.handle_representation(fixture.history), fixture.history.bank, fixture.history.slot + 1, 1, ())
        @test_throws r"declared history sample" _history_feedback_program(engine; constraint_read = forged)
    end
end

@testset "two retained model samples drive the same ordinary boundary evaluator" begin
    C = CorePotts
    for engine in (C.SequentialProgramEngine(), C.CheckerboardProgramEngine())
        (; program, fixture) = _history_feedback_program(engine)
        (; layout, source, history) = fixture
        base = test_initial(Float32)
        state = C.allocate_auxiliary_state(
            layout, map(layout.entries) do entry
                entry.schema.domain === :history ? reshape(Float32[2, 3, 4], 1, 3) : fill(1.0f0)
            end
        )
        initial = C.ProgramInitialState(base.ownership, base.cell_kinds; scalar_type = Float32, descriptor_state = state)
        runtime = C.initialize_program(program, initial, Float32[], UInt64(17), UInt32(1))
        C.advance_mcs!(runtime)
        snapshot = C.program_snapshot(runtime)
        @test !C.program_failed(runtime)
        @test only(C.state_block(snapshot.descriptor_state, source).values) == 34.0f0
        @test vec(C.state_block(snapshot.descriptor_state, history).values) == Float32[3, 4, 34]
        restored = C.restore_program_checkpoint(program, C.program_checkpoint(runtime))
        for current in (runtime, restored)
            C.advance_mcs!(current)
            snapshot = C.program_snapshot(current)
            @test !C.program_failed(current)
            @test only(C.state_block(snapshot.descriptor_state, source).values) == 74.0f0
            @test vec(C.state_block(snapshot.descriptor_state, history).values) == Float32[4, 34, 74]
        end
    end
end
