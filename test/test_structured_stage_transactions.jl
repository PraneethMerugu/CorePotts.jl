import StaticArrays: SVector

struct NonfiniteStructuredStageValue end
@inline (::NonfiniteStructuredStageValue)(value::SVector{2, Float32}) =
    SVector(value[1], NaN32)
@inline (::NonfiniteStructuredStageValue)(value::NamedTuple) =
    (
    active = value.active, count = value.count,
    polarity = NonfiniteStructuredStageValue()(value.polarity),
)

function _structured_model_assignment(target, source, slot; nonfinite = false)
    read = CorePotts.OperationExpression(
        CorePotts.operation_callable(Val(:model_bound_state_value), v"1.0.0"),
        CorePotts.StateExpression(source),
    )
    value = nonfinite ? CorePotts.OperationExpression(NonfiniteStructuredStageValue(), read) : read
    return CorePotts.CompiledStageDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
        CorePotts.StaticEvaluator(value), CorePotts.ModelAssignmentEffect(target),
        CorePotts.AfterMCSStage(),
        CorePotts.ResourceAccess(
            (source,), (target,), CorePotts.EmptyFootprint(),
            CorePotts.ModelFootprint(), CorePotts.ExclusiveWriteAccess(),
        ),
        CorePotts.DescriptorSupport(true, true, true, true), slot, slot,
    )
end

function _structured_stage_runtime(engine, left, right; ordered = false, nonfinite = false)
    schemas = map((:left_signal, :right_signal)) do name
        CorePotts.StateBlockSchema(
            CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", :model,
            typeof(left), (1,), 1, :structure_of_arrays,
            :provided_or_zero, :shape_and_finite, :logical, :preserve,
            :declared, :bounded_write, :adapt_storage, :copy, :logical_copy,
            :qualified, true,
        )
    end
    layout = CorePotts.StateLayout(collect(schemas))
    handles = map(entry -> entry.handle, layout.entries)
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (), layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (),
        Any[:swap_left, :swap_right, :nonfinite_output], 0,
        "structured-stage-descriptors", CorePotts.HamiltonianDomainResources(0, 0),
    )
    assign_left = _structured_model_assignment(handles[1], handles[2], 1)
    assign_right = _structured_model_assignment(handles[2], handles[1], 2)
    before = ordered ? (CorePotts.StageDescriptorGroup([assign_left]),) :
        (CorePotts.StageDescriptorGroup([assign_left, assign_right]),)
    after = if nonfinite
        (
            CorePotts.StageDescriptorGroup(
                [
                    _structured_model_assignment(handles[1], handles[1], 3; nonfinite = true),
                ]
            ),
        )
    elseif ordered
        (CorePotts.StageDescriptorGroup([assign_right]),)
    else
        ()
    end
    stage_plan = CorePotts.StageExecutionPlan(
        (), before, after, 0, 0, "structured-stage-boundaries",
    )
    program = test_program(engine; descriptor_plan, stage_plan, scalar_type = Float32)
    initial = CorePotts.ProgramInitialState(
        ones(Int32, 6, 6), Int16[2]; scalar_type = Float32,
        descriptor_state = CorePotts.allocate_auxiliary_state(layout, ([left], [right])),
    )
    runtime = CorePotts.initialize_program(program, initial, Float32[], UInt64(0x7151), UInt32(1))
    return runtime, handles
end

_structured_stage_values(snapshot, handles) =
    map(handle -> only(CorePotts.state_block(snapshot.descriptor_state, handle).values), handles)

@testset "logical model-state assignments preserve transaction boundaries" begin
    pairs = (
        (SVector(1.0f0, 2.0f0), SVector(3.0f0, 4.0f0)),
        (
            (active = false, count = Int32(2), polarity = SVector(1.0f0, 2.0f0)),
            (active = true, count = Int32(7), polarity = SVector(3.0f0, 4.0f0)),
        ),
    )
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            for (left, right) in pairs
                @testset "$(typeof(left))" begin
                    @testset "same-boundary assignments swap from one snapshot" begin
                        runtime, handles = _structured_stage_runtime(engine, left, right)
                        CorePotts.advance_mcs!(runtime)
                        @test !CorePotts.program_failed(runtime)
                        snapshot = CorePotts.program_snapshot(runtime)
                        @test snapshot.mcs == 1
                        @test _structured_stage_values(snapshot, handles) == [right, left]
                    end
                    @testset "before and after lifecycle assignments are ordered" begin
                        runtime, handles = _structured_stage_runtime(engine, left, right; ordered = true)
                        CorePotts.advance_mcs!(runtime)
                        @test !CorePotts.program_failed(runtime)
                        snapshot = CorePotts.program_snapshot(runtime)
                        @test snapshot.mcs == 1
                        @test _structured_stage_values(snapshot, handles) == [right, right]
                    end
                    @testset "late nonfinite output restores every published value" begin
                        runtime, handles = _structured_stage_runtime(engine, left, right; nonfinite = true)
                        before = CorePotts.program_snapshot(runtime)
                        # A valid before-lifecycle swap precedes this failure.
                        # The externally published MCS must retain its entry state.
                        if engine isa CorePotts.SequentialProgramEngine
                            @test_throws DomainError CorePotts.advance_mcs!(runtime)
                        else
                            CorePotts.advance_mcs!(runtime)
                            @test CorePotts.program_failed(runtime)
                        end
                        @test runtime.settled
                        after = CorePotts.program_snapshot(runtime)
                        @test after.mcs == before.mcs == 0
                        @test _structured_stage_values(after, handles) == [left, right]
                        @test after.ownership == before.ownership
                        @test after.cell_kinds == before.cell_kinds
                        @test after.cell_generations == before.cell_generations
                        @test after.trackers.values == before.trackers.values
                        @test CorePotts.program_lifecycle_receipt(runtime) === nothing
                    end
                end
            end
        end
    end
end
