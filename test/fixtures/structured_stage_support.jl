import StaticArrays: SVector

struct NonfiniteStructuredStageValue end
@inline (::NonfiniteStructuredStageValue)(::Float32) = NaN32
@inline (::NonfiniteStructuredStageValue)(value::SVector{2, Float32}) =
    SVector(value[1], NaN32)
@inline (::NonfiniteStructuredStageValue)(value::NamedTuple) =
    (
    active = value.active, count = value.count,
    polarity = NonfiniteStructuredStageValue()(value.polarity),
)

struct OverflowingModelStageValue end
@inline (::OverflowingModelStageValue)(::Float32) = 1.0e300

function _structured_model_assignment(target, source, slot; transform = nothing, enabled = true)
    read = CorePotts.OperationExpression(
        CorePotts.operation_callable(Val(:model_bound_state_value), v"1.0.0"),
        CorePotts.StateExpression(source),
    )
    value = transform === nothing ? read : CorePotts.OperationExpression(transform, read)
    return CorePotts.CompiledStageDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(enabled)),
        CorePotts.StaticEvaluator(value), CorePotts.ModelAssignmentEffect(target),
        CorePotts.AfterMCSStage(),
        CorePotts.ResourceAccess(
            (source,), (target,), CorePotts.EmptyFootprint(),
            CorePotts.ModelFootprint(), CorePotts.ExclusiveWriteAccess(),
        ),
        CorePotts.DescriptorSupport(true, true, true, true), slot, slot,
    )
end

function _structured_stage_runtime(
        engine, left, right; ordered = false, after_transform = nothing,
        same_target = false, conditions = (true, true), model_shape = (1,),
        parameter_defaults = Float32[],
    )
    schemas = map((:left_signal, :right_signal)) do name
        CorePotts.StateBlockSchema(
            CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", :model,
            typeof(left), model_shape, 1, :structure_of_arrays,
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
    assign_left = _structured_model_assignment(handles[1], handles[2], 1; enabled = conditions[1])
    assign_right = _structured_model_assignment(
        same_target ? handles[1] : handles[2],
        same_target ? handles[2] : handles[1], 2; enabled = conditions[2],
    )
    before = ordered ? (CorePotts.StageDescriptorGroup([assign_left]),) :
        (CorePotts.StageDescriptorGroup([assign_left, assign_right]),)
    after = if after_transform !== nothing
        (
            CorePotts.StageDescriptorGroup(
                [
                    _structured_model_assignment(handles[1], handles[1], 3; transform = after_transform),
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
    program = test_program(engine; descriptor_plan, stage_plan, scalar_type = Float32, parameter_defaults)
    initial = CorePotts.ProgramInitialState(
        ones(Int32, 6, 6), Int16[2]; scalar_type = Float32,
        descriptor_state = CorePotts.allocate_auxiliary_state(
            layout, (fill(left, model_shape), fill(right, model_shape)),
        ),
    )
    runtime = CorePotts.initialize_program(program, initial, parameter_defaults, UInt64(0x7151), UInt32(1))
    return runtime, handles
end

_structured_stage_values(snapshot, handles) =
    map(handle -> only(CorePotts.state_block(snapshot.descriptor_state, handle).values), handles)
