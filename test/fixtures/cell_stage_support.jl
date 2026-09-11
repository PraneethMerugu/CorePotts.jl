import StaticArrays

struct NonfiniteCellStageValue end
@inline (::NonfiniteCellStageValue)(value::Float32) = Inf32
@inline (::NonfiniteCellStageValue)(value::StaticArrays.SVector) = value .* Inf32
@inline (::NonfiniteCellStageValue)(value::NamedTuple) = (; count = value.count, signal = value.signal .* Inf32)
struct OverflowingCellStageValue end
@inline (::OverflowingCellStageValue)(value) = Float64(floatmax(Float32)) * 2.0

struct CellStageIncrement end
@inline (::CellStageIncrement)(value::Float32) = value > 0 ? value + 1.0f0 : Inf32
@inline (::CellStageIncrement)(value::StaticArrays.SVector) = value .+ 1.0f0
@inline (::CellStageIncrement)(value::NamedTuple) = (; count = value.count + Int32(1), signal = value.signal .+ 1.0f0)

function cell_stage_descriptor(target, source, slot; transform = CellStageIncrement(), increment = nothing, enabled = true, source_handle = slot, declare_read = true, read_condition = false)
    read = CorePotts.OperationExpression(CorePotts.operation_callable(Val(:cell_bound_state_value), v"1.0.0"), CorePotts.StateExpression(source))
    value = increment === nothing ?
        (transform === nothing ? read : CorePotts.OperationExpression(transform, read)) :
        CorePotts.OperationExpression(+, read, CorePotts.LiteralExpression(increment))
    condition = read_condition ? CorePotts.OperationExpression(>, read, CorePotts.LiteralExpression(0.0f0)) : CorePotts.LiteralExpression(enabled)
    return CorePotts.CompiledStageDescriptor(
        CorePotts.StaticEvaluator(condition),
        CorePotts.StaticEvaluator(read_condition ? CorePotts.LiteralExpression(1.0f0) : value), CorePotts.CellAssignmentEffect(target, 2),
        CorePotts.AfterMCSStage(),
        CorePotts.ResourceAccess(declare_read ? (source,) : (), (target,), CorePotts.EmptyFootprint(), CorePotts.OwnerFootprint(), CorePotts.ExclusiveWriteAccess()),
        CorePotts.DescriptorSupport(true, true, true, true), source_handle, slot,
    )
end

function cell_stage_runtime(engine; initial_value = 1.0f0, bank_capacity = 6, empty = false, inactive = false, swap = false, same_target = false, conditions = (true, true), transform = CellStageIncrement(), after_transform = nothing, schema_domain = :cell, source_domain = schema_domain, foreign_source = false, declare_read = true, read_condition = false)
    schemas = map((:cell_signal, :cell_partner)) do name
        CorePotts.StateBlockSchema(
            CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", name === :cell_partner ? source_domain : schema_domain,
            typeof(initial_value), (bank_capacity,), 1, :structure_of_arrays,
            :provided_or_zero, :shape_and_finite, :logical, :preserve, :declared,
            :bounded_write, :adapt_storage, :copy, :logical_copy, :qualified, true,
        )
    end
    layout = CorePotts.StateLayout(collect(schemas))
    handles = map(entry -> entry.handle, layout.entries)
    reject = CorePotts.ProposalDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(false)),
        CorePotts.ResourceAccess((), (), CorePotts.EmptyFootprint(), CorePotts.EmptyFootprint(), CorePotts.NoWriteAccess()),
        CorePotts.DescriptorSupport(true, true, true, true), (), (), CorePotts.ProposalConstraintRole(), 1,
    )
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (CorePotts.ProposalDescriptorGroup([reject], (), (), :unsplit),), layout,
        CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (), Any[:cell_signal, :cell_partner],
        1, "cell-stage-descriptors", CorePotts.HamiltonianDomainResources(0, 0),
    )
    source = foreign_source ? CorePotts.StateHandle(CorePotts.handle_representation(handles[1]), 99, 1, 1, (bank_capacity,)) : handles[source_domain === schema_domain ? 1 : 2]
    descriptors = swap || same_target ? (
            cell_stage_descriptor(handles[1], handles[2], 1; transform = nothing, enabled = conditions[1]),
            cell_stage_descriptor(same_target ? handles[1] : handles[2], same_target ? handles[2] : handles[1], 2; transform = nothing, enabled = conditions[2]),
        ) : (cell_stage_descriptor(handles[1], source, 1; transform, declare_read, read_condition, enabled = conditions[1], increment = empty ? 1.0f0 : nothing),)
    after = after_transform === nothing ? () : (
            CorePotts.StageDescriptorGroup(
                [
                    cell_stage_descriptor(handles[1], handles[1], length(descriptors) + 1; transform = after_transform, source_handle = 2),
                ]
            ),
        )
    stage_plan = CorePotts.StageExecutionPlan((), (CorePotts.StageDescriptorGroup(collect(descriptors)),), after, 0, 0, "cell-stage-boundary")
    program = test_program(engine; descriptor_plan, stage_plan, scalar_type = Float32)
    ownership = empty || inactive ? zeros(Int32, 6, 6) : ones(Int32, 6, 6)
    empty || inactive || (ownership[1] = 2)
    kinds = empty ? Int16[] : inactive ? zeros(Int16, 3) : Int16[2, 2, 0]
    values = fill(initial_value, bank_capacity)
    if !empty && bank_capacity >= 3 && initial_value isa Float32
        values[3] = 0.0f0
    end
    partner = map(CellStageIncrement(), fill(initial_value, bank_capacity))
    initial = CorePotts.ProgramInitialState(
        ownership, kinds; scalar_type = Float32,
        descriptor_state = CorePotts.allocate_auxiliary_state(layout, (values, partner)),
    )
    return CorePotts.initialize_program(program, initial, Float32[], UInt64(0xc311), UInt32(1)), handles
end
