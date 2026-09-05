# Cold CorePotts lowering from scientific descriptor expressions to bounded
# LocalMath requirements. The ordinary records built here are construction
# scratch and never enter a Plan, PreparedPlan, or kernel argument.

_contextual_operation_identity(::ContextOperation{Identity}) where {Identity} =
    Identity
_contextual_operation_identity(::ResourceOperation{Identity}) where {Identity} =
    Identity
_contextual_operation_identity(
    operation::QualifiedTrackerOperation,
) = (
    operation = _contextual_operation_identity(operation.operation),
    quantity = operation.quantity,
    source_handle = operation.source_handle,
)
_contextual_operation_identity(operation::AbstractContextualOperation) =
    typeof(operation)

function _proposal_descriptor_source(plan::DescriptorExecutionPlan, handle::Int32)
    1 <= handle <= length(plan.source_table) || throw(ArgumentError(
        "proposal descriptor source handle $(handle) is outside the source table"
    ))
    return plan.source_table[Int(handle)]
end
function _proposal_descriptors_in_source_order(plan::DescriptorExecutionPlan)
    descriptors = ProposalDescriptor[]
    for group in plan.groups, descriptor in group.instances
        descriptor isa ProposalDescriptor || throw(ArgumentError(
            "checkerboard compilation requires proposal descriptors"
        ))
        push!(descriptors, descriptor)
    end
    sort!(descriptors; by = descriptor -> descriptor.source_handle)
    for (left, right) in zip(descriptors, Iterators.drop(descriptors, 1))
        left.source_handle != right.source_handle || throw(ArgumentError(
            "proposal source $(left.source_handle) has more than one descriptor occurrence"
        ))
    end
    return descriptors
end

function _validate_proposal_footprint(footprint, source)
    footprint isa Union{
        EmptyFootprint,
        ModelFootprint,
        ProposalContextFootprint,
        OwnerFootprint,
        ContactFootprint,
        FiniteSpatialFootprint,
        IncidentRelationshipFootprint,
    } && return nothing
    if footprint isa FootprintUnion
        foreach(part -> _validate_proposal_footprint(part, source),
            footprint.footprints)
        return nothing
    end
    if footprint isa FootprintMinkowski
        _validate_proposal_footprint(footprint.left, source)
        _validate_proposal_footprint(footprint.right, source)
        return nothing
    end
    throw(ArgumentError(
        "proposal source $(repr(source)) has unsupported or unbounded footprint " *
        string(typeof(footprint))
    ))
end

function _record_proposal_expression!(
        records,
        expression::LiteralExpression,
        descriptor,
        source,
        path::Tuple,
    )
    return records
end

function _record_proposal_expression!(
        records,
        expression::ParameterExpression,
        descriptor,
        source,
        path::Tuple,
    )
    expression.index == 0 || push!(records, (
        kind = :parameter,
        identity = expression.index,
        source_handle = descriptor.source_handle,
        source,
        role = descriptor.role,
        access = descriptor.access,
        path,
        expression,
    ))
    return records
end

function _record_proposal_expression!(
        records,
        expression::StateExpression,
        descriptor,
        source,
        path::Tuple,
    )
    push!(records, (
        kind = :state_handle,
        identity = expression.handle,
        source_handle = descriptor.source_handle,
        source,
        role = descriptor.role,
        access = descriptor.access,
        path,
        expression,
    ))
    return records
end

function _record_proposal_expression!(
        records,
        expression::ContextExpression,
        descriptor,
        source,
        path::Tuple,
    )
    operation = expression.operation
    push!(records, (
        kind = :context,
        identity = _contextual_operation_identity(operation),
        source_handle = descriptor.source_handle,
        source,
        role = descriptor.role,
        access = descriptor.access,
        path,
        operation,
    ))
    return records
end

function _record_proposal_expression!(
        records,
        expression::OperationExpression,
        descriptor,
        source,
        path::Tuple,
    )
    operation = expression.operation
    if operation isa AbstractContextualOperation
        push!(records, (
            kind = :operation,
            identity = _contextual_operation_identity(operation),
            source_handle = descriptor.source_handle,
            source,
            role = descriptor.role,
            access = descriptor.access,
            path,
            operation,
        ))
    end
    for (index, argument) in pairs(expression.arguments)
        _record_proposal_expression!(
            records, argument, descriptor, source, (path..., Int32(index)))
    end
    return records
end

function _record_proposal_expression!(
        records,
        expression::AbstractStaticExpression,
        descriptor,
        source,
        path::Tuple,
    )
    throw(ArgumentError(
        "proposal source $(repr(source)) contains unsupported expression " *
        string(typeof(expression)) * " at path " * repr(path)
    ))
end

function _proposal_gather_inventory(plan::DescriptorExecutionPlan)
    records = Any[]
    descriptors = _proposal_descriptors_in_source_order(plan)
    for descriptor in descriptors
        source = _proposal_descriptor_source(plan, descriptor.source_handle)
        _validate_proposal_footprint(descriptor.access.footprint, source)
        _record_proposal_expression!(
            records,
            descriptor.evaluator.expression,
            descriptor,
            source,
            (),
        )
    end
    return (
        descriptors = Tuple(descriptors),
        records = Tuple(records),
        source_count = Int32(length(plan.source_table)),
    )
end

function _proposal_parameter_count(inventory)
    maximum((Int(record.identity) for record in inventory.records
        if record.kind === :parameter); init = 0)
end

function _proposal_state_handles(inventory)
    handles = StateHandle[]
    for record in inventory.records
        record.kind === :state_handle || continue
        handle = record.identity
        any(==(handle), handles) || push!(handles, handle)
    end
    return Tuple(handles)
end

_state_handle_element_type(
    ::StateHandle{StateStorageRepresentation{
        ElementType,Dimensions,Layout,Adaptation}},
) where {ElementType,Dimensions,Layout,Adaptation} = ElementType

# Executable scalar terms produced by the cold proposal compiler. These are
# ordinary concrete callable values, not StaticEvaluator syntax, and are the
# only form admitted to a LocalMath evaluator.
struct _ExecutableLiteral{T}
    value::T
end

struct _ExecutableDefaultParameter{T}
    value::T
end

struct _ExecutableParameter{Index,T}
    default::T
end

struct _ExecutableStateReference{Index,H}
    handle::H
end
@inline _executable_state_slot(::_ExecutableStateReference{Index}) where {Index} =
    Index

struct _ExecutableProposalContext{Identity} end

struct _ExecutableScalarCall{F,A<:Tuple}
    operation::F
    arguments::A
end

struct _ExecutableIntegerPower{N,A}
    argument::A
end

function _static_integer_power_expression(value, exponent::Int)
    iszero(exponent) && return :(one($value))
    exponent == 1 && return value
    if exponent < 0
        exponent == typemin(Int) && throw(ArgumentError(
            "the minimum machine integer is not a supported static exponent"))
        return :(inv($(_static_integer_power_expression(value, -exponent))))
    end
    half = gensym(:half)
    half_expression = _static_integer_power_expression(value, exponent >>> 1)
    product = iseven(exponent) ? :($half * $half) : :($half * $half * $value)
    return :(let $half = $half_expression
        $product
    end)
end

@generated function _static_integer_power(value, ::Val{N}) where {N}
    N isa Int || return :(throw(ArgumentError("static exponent must be Int")))
    return Expr(:block, Expr(:meta, :inline),
        _static_integer_power_expression(:value, N))
end

struct _ExecutableContextualCall{F,A<:Tuple}
    operation::F
    arguments::A
end

struct _GatheredQualifiedTrackerCall{Q,F,A<:Tuple}
    operation::F
    arguments::A
    source_handle::Int32
end

struct _ExecutableProposalTerm{E,R}
    evaluator::E
    role::R
    source_handle::Int32
end

struct _ExecutableAcceptedSiteTerm{C,V,H}
    condition::C
    value::V
    target::H
    source_handle::Int32
    buffer_slot::Int32
    descriptor_ordinal::Int32
end

struct _ExecutableAcceptedRelationshipTerm{C,A,B,P,Z}
    condition::C
    endpoint_a::A
    endpoint_b::B
    payload::P
    payload_zero::Z
    relationship_slot::Int32
    bank_index::Int32
    bank_slot::Int32
    priority::Int32
    source_handle::Int32
    descriptor_ordinal::Int32
    relationship_ordinal::Int32
    evaluation_offset::Int32
end

function _accepted_site_descriptors(stage_plan::StageExecutionPlan)
    records = NamedTuple[]
    ordinal = Int32(0)
    for group in stage_plan.accepted_copy, descriptor in group.instances
        ordinal += Int32(1)
        descriptor.effect isa SiteAssignmentEffect || continue
        push!(records, (; descriptor, ordinal))
    end
    return Tuple(records)
end

function _accepted_relationship_descriptors(stage_plan::StageExecutionPlan)
    records = NamedTuple[]
    ordinal = Int32(0)
    for group in stage_plan.accepted_copy, descriptor in group.instances
        ordinal += Int32(1)
        descriptor.effect isa RelationshipCreateEffect || continue
        push!(records, (; descriptor, ordinal))
    end
    return Tuple(records)
end

_record_expression_requirements!(handles, parameter_count, ::LiteralExpression) =
    nothing
function _record_expression_requirements!(
        handles, parameter_count, expression::ParameterExpression)
    parameter_count[] = max(parameter_count[], Int(expression.index))
    return nothing
end
function _record_expression_requirements!(
        handles, parameter_count, expression::StateExpression)
    any(==(expression.handle), handles) || push!(handles, expression.handle)
    return nothing
end
_record_expression_requirements!(
    handles, parameter_count, ::ContextExpression) = nothing
function _record_expression_requirements!(
        handles, parameter_count, expression::OperationExpression)
    foreach(expression.arguments) do argument
        _record_expression_requirements!(handles, parameter_count, argument)
    end
    return nothing
end
function _record_expression_requirements!(
        handles, parameter_count, expression::AbstractStaticExpression)
    throw(ArgumentError(
        "checkerboard compilation encountered unsupported stage expression " *
        string(typeof(expression))))
end

_record_tracker_requirements!(keys, ::AbstractStaticExpression) = nothing
function _record_tracker_requirements!(
        keys, expression::OperationExpression)
    operation = expression.operation
    if operation isa QualifiedTrackerOperation
        key = QualifiedTrackerKey(
            operation.quantity, operation.source_handle)
        any(isequal(key), keys) || push!(keys, key)
    end
    foreach(expression.arguments) do argument
        _record_tracker_requirements!(keys, argument)
    end
    return nothing
end

_record_moment_requirement!(required, ::AbstractStaticExpression) = nothing
function _record_moment_requirement!(required, expression::OperationExpression)
    operation = expression.operation
    if operation isa Union{
            ResourceOperation{:cell_center},
            ResourceOperation{:unwrapped_center},
            ResourceOperation{:cell_elongation},
        }
        required[] = true
    end
    foreach(expression.arguments) do argument
        _record_moment_requirement!(required, argument)
    end
    return nothing
end

_record_relationship_requirements!(handles, ::AbstractStaticExpression) = nothing
function _record_relationship_requirements!(
        handles, expression::OperationExpression)
    operation = expression.operation
    if operation isa Union{
            ResourceOperation{:degree},
            ResourceOperation{:linked},
        }
        first_argument = first(expression.arguments)
        first_argument isa LiteralExpression || throw(ArgumentError(
            "checkerboard relationship operations require a compiled " *
            "literal relationship handle"))
        handle = Int32(first_argument.value)
        any(==(handle), handles) || push!(handles, handle)
    end
    foreach(expression.arguments) do argument
        _record_relationship_requirements!(handles, argument)
    end
    return nothing
end

function _tracker_requirement_descriptors(keys, tracker_plan)
    instances = tracker_instances(tracker_plan)
    return Tuple(map(keys) do key
        index = findfirst(
            descriptor -> isequal(tracker_quantity(descriptor), key),
            instances)
        index === nothing && throw(ArgumentError(
            "checkerboard compilation requires unavailable tracker " *
            repr(key)))
        descriptor = instances[index]
        tracker_storage(descriptor) isa DenseOwnerScalarStorage || throw(
            ArgumentError(
                "checkerboard gathered tracker reads require dense scalar storage for " *
                repr(key)))
        descriptor
    end)
end


function _moment_requirement_descriptor(required::Bool, tracker_plan)
    required || return nothing
    instances = tracker_instances(tracker_plan)
    index = findfirst(descriptor -> descriptor isa CellMomentsTracker, instances)
    index === nothing && throw(ArgumentError(
        "checkerboard compilation requires the cell-moment tracker for " *
        "cell_center, unwrapped_center, or cell_elongation"))
    return instances[index]
end

function _checkerboard_scientific_requirements(
        inventory, stage_plan, ownership_change_handles, tracker_plan)
    handles = StateHandle[_proposal_state_handles(inventory)...]
    parameter_count = Ref(_proposal_parameter_count(inventory))
    affected_handles = StateHandle[]
    tracker_keys = QualifiedTrackerKey[]
    relationship_handles = Int32[]
    moment_required = Ref(false)
    for descriptor in inventory.descriptors
        role = descriptor.role
        if role isa HamiltonianRole{
                <:RelationshipEnergyDomainPlan,
                <:IncidentRelationshipsAffectedPlan}
            handle = role.domain.relationship_handle
            any(==(handle), relationship_handles) ||
                push!(relationship_handles, handle)
        end
        _record_tracker_requirements!(
            tracker_keys, descriptor.evaluator.expression)
        _record_moment_requirement!(
            moment_required, descriptor.evaluator.expression)
        _record_relationship_requirements!(
            relationship_handles, descriptor.evaluator.expression)
    end
    for record in _accepted_site_descriptors(stage_plan)
        descriptor = record.descriptor
        _record_expression_requirements!(
            handles, parameter_count, descriptor.condition.expression)
        _record_expression_requirements!(
            handles, parameter_count, descriptor.value.expression)
        _record_tracker_requirements!(
            tracker_keys, descriptor.condition.expression)
        _record_tracker_requirements!(
            tracker_keys, descriptor.value.expression)
        _record_moment_requirement!(
            moment_required, descriptor.condition.expression)
        _record_moment_requirement!(
            moment_required, descriptor.value.expression)
        _record_relationship_requirements!(
            relationship_handles, descriptor.condition.expression)
        _record_relationship_requirements!(
            relationship_handles, descriptor.value.expression)
        any(==(descriptor.effect.target), handles) ||
            push!(handles, descriptor.effect.target)
        any(==(descriptor.effect.target), affected_handles) ||
            push!(affected_handles, descriptor.effect.target)
    end
    for record in _accepted_relationship_descriptors(stage_plan)
        descriptor = record.descriptor
        effect = descriptor.effect
        _record_expression_requirements!(
            handles, parameter_count, descriptor.condition.expression)
        _record_expression_requirements!(
            handles, parameter_count, effect.endpoint_a.expression)
        _record_expression_requirements!(
            handles, parameter_count, effect.endpoint_b.expression)
        _record_tracker_requirements!(
            tracker_keys, descriptor.condition.expression)
        _record_tracker_requirements!(
            tracker_keys, effect.endpoint_a.expression)
        _record_tracker_requirements!(
            tracker_keys, effect.endpoint_b.expression)
        _record_moment_requirement!(
            moment_required, descriptor.condition.expression)
        _record_moment_requirement!(
            moment_required, effect.endpoint_a.expression)
        _record_moment_requirement!(
            moment_required, effect.endpoint_b.expression)
        _record_relationship_requirements!(
            relationship_handles, descriptor.condition.expression)
        _record_relationship_requirements!(
            relationship_handles, effect.endpoint_a.expression)
        _record_relationship_requirements!(
            relationship_handles, effect.endpoint_b.expression)
        for evaluator in effect.payload
            _record_expression_requirements!(
                handles, parameter_count, evaluator.expression)
            _record_tracker_requirements!(tracker_keys, evaluator.expression)
            _record_moment_requirement!(moment_required, evaluator.expression)
            _record_relationship_requirements!(
                relationship_handles, evaluator.expression)
        end
    end
    for handle in ownership_change_handles
        any(==(handle), handles) || push!(handles, handle)
        any(==(handle), affected_handles) || push!(affected_handles, handle)
    end
    return (; state_handles = Tuple(handles),
        accepted_state_handles = Tuple(affected_handles),
        parameter_count = parameter_count[],
        tracker_keys = Tuple(tracker_keys),
        tracker_descriptors = _tracker_requirement_descriptors(
            tracker_keys, tracker_plan),
        moment_descriptor = _moment_requirement_descriptor(
            moment_required[], tracker_plan),
        relationship_handles = Tuple(relationship_handles))
end


function _accepted_descriptor_source(
        descriptor_plan::DescriptorExecutionPlan, source_handle::Int32)
    return 1 <= source_handle <= length(descriptor_plan.source_table) ?
        _proposal_descriptor_source(descriptor_plan, source_handle) :
        source_handle
end


function _compile_accepted_relationship_terms(
        stage_plan::StageExecutionPlan,
        descriptor_plan::DescriptorExecutionPlan,
        state_handles::Tuple,
        relationship_schemas::RelationshipStorage,
        relationship_state::RelationshipStorage,
    )
    length(relationship_schemas) == length(relationship_state) || throw(
        ArgumentError("relationship schemas and packed state are misaligned"))
    records = _accepted_relationship_descriptors(stage_plan)
    offset = Int32(1)
    terms = map(enumerate(records)) do indexed
        relationship_ordinal, record = indexed
        descriptor = record.descriptor
        effect = descriptor.effect
        source = _accepted_descriptor_source(
            descriptor_plan, descriptor.source_handle)
        _validate_proposal_footprint(descriptor.access.footprint, source)
        location = _relationship_location(
            relationship_schemas, Int(effect.relationship_slot))
        bank = relationship_state.banks[Int(location.bank)]
        bank isa PackedRelationshipBank || throw(ArgumentError(
            "checkerboard relationship compilation requires packed banks"))
        payload_zero = map(values -> zero(eltype(values)), bank.payload)
        length(payload_zero) == length(effect.payload) || throw(ArgumentError(
            "relationship payload evaluator count disagrees with packed storage"))
        term = _ExecutableAcceptedRelationshipTerm(
            _compile_proposal_expression(
                descriptor.condition.expression, source, state_handles),
            _compile_proposal_expression(
                effect.endpoint_a.expression, source, state_handles),
            _compile_proposal_expression(
                effect.endpoint_b.expression, source, state_handles),
            map(effect.payload) do evaluator
                _compile_proposal_expression(
                    evaluator.expression, source, state_handles)
            end,
            payload_zero,
            effect.relationship_slot,
            location.bank,
            location.slot,
            effect.priority,
            descriptor.source_handle,
            record.ordinal,
            Int32(relationship_ordinal),
            offset,
        )
        offset += Int32(3 + length(payload_zero))
        return term
    end
    return Tuple(terms)
end

function _accepted_relationship_fields(source::LocalMath.Space, terms::Tuple)
    names = Symbol[]
    fields = Any[]
    for (term_index, term) in enumerate(terms)
        push!(names, Symbol(:accepted_relationship_, term_index, :_code))
        push!(fields, LocalMath.Field(source, UInt8))
        push!(names, Symbol(:accepted_relationship_, term_index, :_endpoints))
        push!(fields, LocalMath.Field(source, Tuple{Int32,Int32}))
        for (payload_index, prototype) in enumerate(term.payload_zero)
            push!(names, Symbol(:accepted_relationship_, term_index,
                :_payload_, payload_index))
            push!(fields, LocalMath.Field(source, typeof(prototype)))
        end
    end
    return NamedTuple{Tuple(names)}(Tuple(fields))
end

function _accepted_site_fields(
        source::LocalMath.Space, terms::Tuple, ::Type{T}) where {T}
    names = Symbol[]
    fields = Any[]
    for index in eachindex(terms)
        push!(names, Symbol(:accepted_site_, index, :_code))
        push!(fields, LocalMath.Field(source, UInt8))
        push!(names, Symbol(:accepted_site_, index, :_value))
        push!(fields, LocalMath.Field(source, T))
    end
    return NamedTuple{Tuple(names)}(Tuple(fields))
end

function _accepted_site_field_groups(fields::NamedTuple, terms::Tuple)
    storage = values(fields)
    return ntuple(length(terms)) do index
        (code = getfield(storage, 2index - 1),
            value = getfield(storage, 2index))
    end
end

function _accepted_relationship_field_groups(fields::NamedTuple, terms::Tuple)
    storage = values(fields)
    offset = 1
    groups = map(terms) do term
        payload_count = length(term.payload_zero)
        group = (
            code = getfield(storage, offset),
            endpoints = getfield(storage, offset + 1),
            payload = ntuple(payload_count) do payload
                getfield(storage, offset + 1 + payload)
            end,
        )
        offset += 2 + payload_count
        return group
    end
    return Tuple(groups)
end

function _compile_accepted_site_terms(
        stage_plan::StageExecutionPlan,
        descriptor_plan::DescriptorExecutionPlan,
        state_handles::Tuple,
    )
    records = _accepted_site_descriptors(stage_plan)
    return Tuple(map(records) do record
        descriptor = record.descriptor
        source = _accepted_descriptor_source(
            descriptor_plan, descriptor.source_handle)
        _validate_proposal_footprint(descriptor.access.footprint, source)
        _ExecutableAcceptedSiteTerm(
            _compile_proposal_expression(
                descriptor.condition.expression, source, state_handles),
            _compile_proposal_expression(
                descriptor.value.expression, source, state_handles),
            descriptor.effect.target,
            descriptor.source_handle,
            descriptor.buffer_slot,
            record.ordinal,
        )
    end)
end

_gathered_contextual_operation_supported(
    ::ResourceOperation{:occupancy}) = true
_gathered_contextual_operation_supported(
    ::ResourceOperation{:cell_volume}) = true
_gathered_contextual_operation_supported(
    ::ResourceOperation{:field_value}) = true
_gathered_contextual_operation_supported(
    ::ResourceOperation{:draw}) = true
_gathered_contextual_operation_supported(
    ::ResourceOperation{:bounded_fold}) = true
_gathered_contextual_operation_supported(
    ::ResourceOperation{:distance}) = true
_gathered_contextual_operation_supported(::Union{
    ResourceOperation{:cell_center},
    ResourceOperation{:unwrapped_center},
    ResourceOperation{:cell_elongation},
}) = true
_gathered_contextual_operation_supported(
    ::Union{
        ResourceOperation{:contact_owner_a},
        ResourceOperation{:contact_owner_b},
        ResourceOperation{:contact_kind_a},
        ResourceOperation{:contact_kind_b},
        ResourceOperation{:endpoint_a},
        ResourceOperation{:endpoint_b},
        ResourceOperation{:edge_payload},
        ResourceOperation{:degree},
        ResourceOperation{:linked},
        ResourceOperation{:new_contact},
        ResourceOperation{:lost_contact},
    }) = true
_gathered_contextual_operation_supported(::Union{
    ContextOperation{:source_site},
    ContextOperation{:target_site},
    ContextOperation{:source_cell},
    ContextOperation{:target_cell},
    ContextOperation{:source_kind},
    ContextOperation{:target_kind},
    ContextOperation{:is_extension},
    ContextOperation{:is_retraction},
    ContextOperation{:energy_anchor_site},
    ContextOperation{:energy_anchor_cell},
    ContextOperation{:energy_anchor_contact},
    ContextOperation{:energy_anchor_relationship},
}) = true
_gathered_contextual_operation_supported(::ContextOperation) = false
_gathered_contextual_operation_supported(::QualifiedTrackerOperation) = true
_gathered_contextual_operation_supported(
    ::Union{ResourceOperation,QualifiedTrackerOperation}) = false
_gathered_contextual_operation_supported(
    operation::AbstractContextualOperation,
) = operation_context_supported(
    operation, AbstractProposalEvaluationContext)

function _validate_gathered_operation_arguments(
    ::ResourceOperation{:field_value}, arguments, source)
    length(arguments) == 2 && arguments[1] isa StateExpression &&
        arguments[2] isa ContextExpression &&
        _contextual_operation_identity(arguments[2].operation) in
            (:source_site, :target_site) || throw(ArgumentError(
        "proposal source $(repr(source)) requires field_value at the " *
        "bounded source or target proposal site"
    ))
    return nothing
end


function _validate_gathered_operation_arguments(
        ::ResourceOperation{:bounded_fold}, arguments, source)
    length(arguments) == 4 &&
    arguments[1] isa LiteralExpression &&
    arguments[1].value isa LocalMath.BoundedFold &&
    arguments[2] isa StateExpression &&
    arguments[3] isa LiteralExpression &&
    arguments[3].value isa Integer || throw(ArgumentError(
        "proposal source $(repr(source)) requires bounded_fold with a " *
        "literal LocalMath.BoundedFold, a bound state, and a declared " *
        "bounded relation handle"))
    return nothing
end

_validate_gathered_operation_arguments(
    ::AbstractContextualOperation, arguments, source) = nothing

function _validate_gathered_operation_arguments(
        ::QualifiedTrackerOperation, arguments, source)
    length(arguments) == 1 || throw(ArgumentError(
        "proposal source $(repr(source)) requires a unary qualified tracker operation"))
    return nothing
end

function _compile_proposal_expression(
        expression::LiteralExpression, source, state_handles)
    return _ExecutableLiteral(expression.value)
end

function _compile_proposal_expression(
        expression::ParameterExpression, source, state_handles)
    iszero(expression.index) && return _ExecutableDefaultParameter(
        expression.default)
    return _ExecutableParameter{
        Int(expression.index), typeof(expression.default)}(expression.default)
end

function _compile_proposal_expression(
        expression::ContextExpression, source, state_handles)
    operation = expression.operation
    operation isa ContextOperation &&
        _gathered_contextual_operation_supported(operation) || throw(ArgumentError(
        "proposal source $(repr(source)) requires contextual operation " *
        "$(repr(_contextual_operation_identity(operation))) without a " *
        "bounded gathered lowering"
    ))
    return _ExecutableProposalContext{
        _contextual_operation_identity(operation)}()
end

function _compile_proposal_expression(
        expression::StateExpression, source, state_handles)
    slot = findfirst(==(expression.handle), state_handles)
    slot === nothing && throw(ArgumentError(
        "proposal source $(repr(source)) references an uninventoried state handle"
    ))
    return _ExecutableStateReference{
        Int(slot), typeof(expression.handle)}(expression.handle)
end

function _compile_proposal_expression(
        expression::OperationExpression, source, state_handles)
    operation = expression.operation
    arguments = map(expression.arguments) do argument
        _compile_proposal_expression(argument, source, state_handles)
    end
    if operation isa AbstractContextualOperation
        _gathered_contextual_operation_supported(operation) || throw(
            ArgumentError(
                "proposal source $(repr(source)) requires contextual operation " *
                "$(repr(_contextual_operation_identity(operation))) without a " *
                "bounded gathered lowering"
            ))
        _validate_gathered_operation_arguments(
            operation, expression.arguments, source)
        if operation isa QualifiedTrackerOperation
            quantity = only(typeof(operation.quantity).parameters)
            return _GatheredQualifiedTrackerCall{
                quantity,typeof(operation.operation),typeof(arguments)}(
                operation.operation, arguments, operation.source_handle)
        end
        return _ExecutableContextualCall(operation, arguments)
    end
    if operation === (^) && length(expression.arguments) == 2 &&
            expression.arguments[2] isa LiteralExpression &&
            expression.arguments[2].value isa Integer
        exponent = Int(expression.arguments[2].value)
        argument = first(arguments)
        return _ExecutableIntegerPower{exponent,typeof(argument)}(argument)
    end
    return _ExecutableScalarCall(operation, arguments)
end

function _compile_proposal_terms(
        plan::DescriptorExecutionPlan,
        state_handles::Tuple = _proposal_state_handles(
            _proposal_gather_inventory(plan)),
    )
    inventory = _proposal_gather_inventory(plan)
    return Tuple(map(inventory.descriptors) do descriptor
        source = _proposal_descriptor_source(plan, descriptor.source_handle)
        role = descriptor.role
        role isa Union{
            ProposalDriveRole,
            ProposalEnergyDriveRole,
            ProposalModifierRole,
            ProposalConstraintRole,
        HamiltonianRole{<:SiteEnergyDomainPlan,<:TargetSiteAffectedPlan},
        HamiltonianRole{<:SiteEnergyDomainPlan,<:NeighborhoodSitesAffectedPlan},
            HamiltonianRole{<:CellEnergyDomainPlan,<:SourceTargetCellsAffectedPlan},
            HamiltonianRole{<:ContactEnergyDomainPlan,<:IncidentContactsAffectedPlan},
            HamiltonianRole{<:RelationshipEnergyDomainPlan,<:IncidentRelationshipsAffectedPlan},
        } || throw(ArgumentError(
            "proposal source $(repr(source)) requires unsupported Hamiltonian " *
            "domain or affected-anchor lowering $(typeof(role))"
        ))
        _ExecutableProposalTerm(
            _compile_proposal_expression(
                descriptor.evaluator.expression, source, state_handles),
            role,
            descriptor.source_handle,
        )
    end)
end

_proposal_constraint_terms(terms::Tuple) = Tuple(
    term for term in terms if term.role isa ProposalConstraintRole)

_proposal_numeric_terms(terms::Tuple) = Tuple(
    term for term in terms if !(term.role isa ProposalConstraintRole))

function _proposal_literal_constraint(terms::Tuple)
    allowed = true
    for term in terms
        evaluator = term.evaluator
        evaluator isa _ExecutableLiteral || return nothing
        value = evaluator.value
        value isa Bool || throw(ArgumentError(
            "proposal constraint source $(term.source_handle) does not return Bool"))
        allowed &= value
    end
    return Some(allowed)
end

@inline _execute_proposal_scalar(value::_ExecutableLiteral, context) =
    value.value
@inline _execute_proposal_scalar(value::_ExecutableDefaultParameter, context) =
    value.value
@inline _execute_proposal_scalar(
    ::_ExecutableParameter{Index}, context) where {Index} =
    getfield(_proposal_parameters(context), Index)
@inline _execute_proposal_scalar(
    value::_ExecutableStateReference, context) = value
@inline _gathered_proposal(context) = context
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:source_site}, context) =
    _gathered_proposal(context).source
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:target_site}, context) =
    _gathered_proposal(context).target
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:source_cell}, context) =
    _gathered_proposal(context).new_owner
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:target_cell}, context) =
    _gathered_proposal(context).old_owner
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:source_kind}, context) =
    _gathered_proposal(context).new_kind
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:target_kind}, context) =
    _gathered_proposal(context).old_kind
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:is_extension}, context) =
    _gathered_proposal(context).old_owner <= 0 &&
        _gathered_proposal(context).new_owner > 0
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:is_retraction}, context) =
    _gathered_proposal(context).old_owner > 0 &&
        _gathered_proposal(context).new_owner <= 0
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:energy_anchor_site}, context) = context.anchor
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:energy_anchor_cell}, context) = context.anchor
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:energy_anchor_contact}, context) = context.anchor
@inline _execute_proposal_scalar(
    ::_ExecutableProposalContext{:energy_anchor_relationship}, context) =
    context.anchor

@inline _execute_proposal_arguments(::Tuple{}, context) = ()
@inline function _execute_proposal_arguments(arguments::Tuple, context)
    return (
        _execute_proposal_scalar(first(arguments), context),
        _execute_proposal_arguments(Base.tail(arguments), context)...,
    )
end

@inline function _execute_proposal_ordered_tail(
        operation, ::Tuple{}, context, accumulator)
    return accumulator
end
@inline function _execute_proposal_ordered_tail(
        operation, arguments::Tuple, context, accumulator)
    value = _execute_proposal_scalar(first(arguments), context)
    return _execute_proposal_ordered_tail(
        operation, Base.tail(arguments), context,
        operation(accumulator, value))
end

@inline function _execute_proposal_ordered(
        operation, arguments::Tuple{A}, context) where {A}
    return operation(_execute_proposal_scalar(first(arguments), context))
end
@inline function _execute_proposal_ordered(
        operation, arguments::Tuple{A,B}, context) where {A,B}
    first_value = _execute_proposal_scalar(getfield(arguments, 1), context)
    second_value = _execute_proposal_scalar(getfield(arguments, 2), context)
    return operation(first_value, second_value)
end
@inline function _execute_proposal_ordered(
        operation, arguments::Tuple{A,B,C,Vararg}, context) where {A,B,C}
    accumulator = _execute_proposal_scalar(first(arguments), context)
    return _execute_proposal_ordered_tail(
        operation, Base.tail(arguments), context, accumulator)
end

@inline function _execute_proposal_scalar(
        call::_ExecutableScalarCall{<:OrderedFold}, context)
    operation = getfield(getfield(call, :operation), :operation)
    return _execute_proposal_ordered(
        operation, getfield(call, :arguments), context)
end

@inline function _execute_proposal_scalar(
        call::_ExecutableScalarCall, context)
    arguments = _execute_proposal_arguments(call.arguments, context)
    return call.operation(arguments...)
end


@inline function _execute_proposal_scalar(
    call::_ExecutableIntegerPower{N}, context) where {N}
    value = _execute_proposal_scalar(call.argument, context)
    return _static_integer_power(value, Val(N))
end

@inline function _execute_proposal_scalar(
        call::_ExecutableContextualCall{
            ResourceOperation{:bounded_fold},Tuple{A,B,C,D}}, context,
    ) where {A,B,C,D}
    arguments = getfield(call, :arguments)
    fold = _execute_proposal_scalar(getfield(arguments, 1), context)
    reference = _execute_proposal_scalar(getfield(arguments, 2), context)
    relation_handle = _execute_proposal_scalar(getfield(arguments, 3), context)
    _execute_proposal_scalar(getfield(arguments, 4), context)
    return _gathered_bounded_fold(
        fold, reference, relation_handle, context)
end

@inline function _execute_proposal_scalar(
        call::_ExecutableContextualCall, context)
    arguments = _execute_proposal_arguments(call.arguments, context)
    return call.operation(arguments, context)
end


@inline function _execute_proposal_scalar(
        call::_GatheredQualifiedTrackerCall{Quantity}, context) where {Quantity}
    arguments = _execute_proposal_arguments(call.arguments, context)
    return qualified_tracker_operation_call(
        call.operation, arguments, context, Val(Quantity), call.source_handle)
end

struct _GatheredProposalContext{
        I,T,P,V,S,O,K,RS,RO,RK,R,TV,TD,MF,MS,MD,RR,
    }
    source::I
    target::I
    target_linear::Int32
    old_owner::Int32
    new_owner::Int32
    old_kind::Int16
    new_kind::Int16
    volumes::NTuple{2,Int32}
    semantic::Int32
    mcs::Int64
    color::Int32
    trajectory_seed::UInt64
    scalar_zero::T
    parameters::P
    state_values::V
    contact_sites::S
    contact_owners::O
    contact_kinds::K
    reverse_contact_sites::RS
    reverse_contact_owners::RO
    reverse_contact_kinds::RK
    contact_ranges::R
    tracker_values::TV
    tracker_descriptors::TD
    moment_first::MF
    moment_second::MS
    moment_descriptor::MD
    relationship_resources::RR
end

@generated function _gathered_proposal_context(arguments...)
    length(arguments) == 28 || error(
        "gathered proposal context construction schema changed")
    context_type = _GatheredProposalContext{
        arguments[1],arguments[13:28]...}
    values = (:(getfield(arguments, $index)) for index in 1:28)
    return :($context_type($(values...)))
end

struct _GatheredAnchorEnergyContext{C,I}
    proposal::C
    after::Bool
    anchor::I
    relationship_handle::Int32
end
_GatheredAnchorEnergyContext(proposal, after::Bool, anchor) =
    _GatheredAnchorEnergyContext(proposal, after, anchor, Int32(0))

struct _GatheredContactAnchor
    first::Int32
    second::Int32
end

@inline _gathered_contact_lookup(
    site::Int32, ::Tuple{}, ::Tuple{}, fallback,
) = fallback
@inline function _gathered_contact_lookup(
        site::Int32, sites::Tuple, values::Tuple, fallback)
    site == first(sites) && return first(values)
    return _gathered_contact_lookup(
        site, Base.tail(sites), Base.tail(values), fallback)
end

@inline function _gathered_site_owner(
        context::_GatheredAnchorEnergyContext, site::Int32)
    proposal = context.proposal
    site == proposal.target_linear &&
        return context.after ? proposal.new_owner : proposal.old_owner
    forward = _gathered_contact_lookup(
        site, proposal.contact_sites, proposal.contact_owners, Int32(0))
    forward != 0 && return forward
    return _gathered_contact_lookup(
        site, proposal.reverse_contact_sites,
        proposal.reverse_contact_owners, Int32(0))
end

@inline function _gathered_site_kind(
        context::_GatheredAnchorEnergyContext, site::Int32)
    proposal = context.proposal
    site == proposal.target_linear &&
        return context.after ? proposal.new_kind : proposal.old_kind
    forward = _gathered_contact_lookup(
        site, proposal.contact_sites, proposal.contact_kinds, Int16(0))
    forward != 0 && return forward
    return _gathered_contact_lookup(
        site, proposal.reverse_contact_sites,
        proposal.reverse_contact_kinds, Int16(0))
end

@inline _gathered_proposal(context::_GatheredAnchorEnergyContext) =
    context.proposal

@inline function owner_kind(
        context::_GatheredProposalContext, owner::Integer)
    value = Int32(owner)
    value == context.old_owner && return context.old_kind
    value == context.new_owner && return context.new_kind
    value < 0 && return Int16(-value)
    return Int16(0)
end
@inline owner_kind(
    context::_GatheredAnchorEnergyContext, owner::Integer,
) = owner_kind(context.proposal, owner)

@inline _proposal_parameters(context::_GatheredProposalContext) =
    context.parameters
@inline _proposal_parameters(context::_GatheredAnchorEnergyContext) =
    context.proposal.parameters

@inline function state_value(
        context::_GatheredAnchorEnergyContext,
        reference::_ExecutableStateReference, site,
    )
    return _gathered_state_value(context.proposal, reference, site)
end

@inline function _gathered_state_value(
        context::_GatheredProposalContext,
        ::_ExecutableStateReference{Index}, site,
    ) where {Index}
    values = getfield(context.state_values, Index)
    site == context.target && return values.sites[1]
    site == context.source && return values.sites[2]
    for sample in values.contacts
        sample.present && sample.endpoint == site && return something(sample.value)
    end
    for sample in values.reverse_contacts
        sample.present && sample.endpoint == site && return something(sample.value)
    end
    return values.sites[1]
end

@inline _gathered_fold_anchor(context::_GatheredProposalContext) =
    context.target_linear
@inline function _gathered_fold_anchor(context::_GatheredAnchorEnergyContext)
    anchor = context.anchor
    return anchor isa Int32 ? anchor : context.proposal.target_linear
end

@inline _gathered_tuple_position(
    value::Int32, ::Tuple{}, index::Int32 = Int32(1),
) = Int32(0)
@inline function _gathered_tuple_position(
        value::Int32, values::Tuple, index::Int32 = Int32(1))
    value == first(values) && return index
    return _gathered_tuple_position(
        value, Base.tail(values), index + Int32(1))
end

@inline state_value(
    context::_GatheredProposalContext,
    reference::_ExecutableStateReference,
    site,
) = _gathered_state_value(context, reference, site)

@inline function apply_resource_operation(
        ::ResourceOperation{:field_value}, arguments,
        context::_GatheredProposalContext)
    return state_value(context, first(arguments), last(arguments))
end

@inline function apply_resource_operation(
        ::ResourceOperation{:field_value}, arguments,
        context::_GatheredAnchorEnergyContext)
    return state_value(context, first(arguments), last(arguments))
end

@inline function _gathered_bounded_fold(
        fold, reference, relation_handle, context)
    relation_handle = Int32(relation_handle)
    proposal = _gathered_proposal(context)
    start, count = _gathered_contact_range(
        relation_handle, proposal.contact_ranges...)
    values = getfield(proposal.state_values, _executable_state_slot(reference))
    anchor = _gathered_fold_anchor(context)
    center_lane = anchor == proposal.target_linear ? Int32(0) :
        _gathered_tuple_position(anchor, proposal.reverse_contact_sites)
    first_lane = iszero(center_lane) ? start :
        (center_lane - Int32(1)) * Int32(length(proposal.contact_sites)) + start
    samples = iszero(center_lane) ? values.contacts : values.affected_contacts
    outcome = LocalMath.evaluate_bounded(fold, samples, first_lane, count)
    outcome.valid && return outcome.value
    value = outcome.value
    return value isa AbstractFloat ? oftype(value, NaN) : value
end

@inline _gathered_bounded_fold(arguments, context) =
    _gathered_bounded_fold(
        getfield(arguments, 1), getfield(arguments, 2),
        getfield(arguments, 3), context)

@inline apply_resource_operation(
    ::ResourceOperation{:bounded_fold}, arguments,
    context::_GatheredProposalContext) = _gathered_bounded_fold(arguments, context)
@inline apply_resource_operation(
    ::ResourceOperation{:bounded_fold}, arguments,
    context::_GatheredAnchorEnergyContext) = _gathered_bounded_fold(arguments, context)

@inline apply_resource_operation(
    ::ResourceOperation{:distance}, arguments::Tuple{A,B},
    ::Union{_GatheredProposalContext,_GatheredAnchorEnergyContext},
) where {A,B} = _center_distance(
    getfield(arguments, 1), getfield(arguments, 2))

@inline function apply_resource_operation(
        ::ResourceOperation{:draw}, arguments,
        context::_GatheredProposalContext)
    T = typeof(context.scalar_zero)
    family = Int(first(arguments))
    first_parameter = T(arguments[2])
    second_parameter = T(arguments[3])
    operation = UInt16(arguments[4])
    first_address = _program_address(
        ExplicitProposalDrawStream, context.mcs, operation,
        context.semantic; subround = context.color, draw = 0)
    first_uniform = uniform_open01(
        T, Philox4x32x10V2(), context.trajectory_seed, first_address)
    family == 1 && return first_uniform < first_parameter
    family == 2 && return muladd(
        first_uniform, second_parameter - first_parameter, first_parameter)
    if family == 3
        iszero(second_parameter) && return first_parameter
        second_address = _program_address(
            ExplicitProposalDrawStream, context.mcs, operation,
            context.semantic; subround = context.color, draw = 1)
        second_uniform = uniform_open01(
            T, Philox4x32x10V2(), context.trajectory_seed, second_address)
        normal = sqrt(-T(2) * log(first_uniform)) *
            cos(T(2pi) * second_uniform)
        return muladd(second_parameter, normal, first_parameter)
    end
    return T(NaN)
end

@inline function apply_resource_operation(
        ::ResourceOperation{:occupancy}, arguments,
        context::_GatheredAnchorEnergyContext)
    kind = Int16(first(arguments))
    proposal = context.proposal
    site = last(arguments)
    linear = site == proposal.target ? proposal.target_linear : Int32(site)
    owner_kind = _gathered_site_kind(context, linear)
    return owner_kind == kind
end

@inline apply_resource_operation(
    ::ResourceOperation{:contact_owner_a}, arguments,
    context::_GatheredAnchorEnergyContext,
) = _gathered_site_owner(context, only(arguments).first)
@inline apply_resource_operation(
    ::ResourceOperation{:contact_owner_b}, arguments,
    context::_GatheredAnchorEnergyContext,
) = _gathered_site_owner(context, only(arguments).second)
@inline apply_resource_operation(
    ::ResourceOperation{:contact_kind_a}, arguments,
    context::_GatheredAnchorEnergyContext,
) = _gathered_site_kind(context, only(arguments).first)
@inline apply_resource_operation(
    ::ResourceOperation{:contact_kind_b}, arguments,
    context::_GatheredAnchorEnergyContext,
) = _gathered_site_kind(context, only(arguments).second)

@inline function _gathered_relationship_resource(
        handle::Int32, resources::Tuple)
    resource = first(resources)
    resource.handle == handle && return resource
    return _gathered_relationship_resource(handle, Base.tail(resources))
end
@inline _gathered_relationship_resource(handle::Int32, ::Tuple{}) = throw(
    ArgumentError("compiled gathered relationship resource is unavailable"))

@inline function _gathered_relationship_sample(
        read, edge::Int32, edge_offset::Int32)
    global_edge = edge_offset + edge - Int32(1)
    lane = Int32(1)
    while lane <= length(read)
        sample = @inbounds read[Int(lane)]
        sample.present && sample.endpoint == global_edge && return sample
        lane += Int32(1)
    end
    return nothing
end

@inline function _gathered_relationship_lane(
        read, edge::Int32, edge_offset::Int32)
    global_edge = edge_offset + edge - Int32(1)
    lane = Int32(1)
    while lane <= length(read)
        sample = @inbounds read[Int(lane)]
        sample.present && sample.endpoint == global_edge && return lane
        lane += Int32(1)
    end
    return Int32(0)
end

@inline function _gathered_relationship_owner_lane(
        resource, anchor, owner::Int32)
    lane = _gathered_relationship_lane(
        resource.active, Int32(anchor), resource.edge_offset)
    lane > 0 || return Int32(0)
    endpoint_a = @inbounds resource.endpoint_a[Int(lane)]
    endpoint_b = @inbounds resource.endpoint_b[Int(lane)]
    endpoint_a.present && something(endpoint_a.value) == owner &&
        return Int32(2) * lane - Int32(1)
    endpoint_b.present && something(endpoint_b.value) == owner &&
        return Int32(2) * lane
    return Int32(0)
end

@generated function _gathered_relationship_components(
        components::Tuple, slot::Int32)
    values = Expr(:tuple)
    for component in 1:fieldcount(components)
        push!(values.args, quote
            local sample = @inbounds getfield(components, $component)[Int(slot)]
            something(sample.value)
        end)
    end
    return values
end

@inline _gathered_relationship_owner_volume(
    handle::Int32, anchor, owner::Int32, ::Tuple{},
) = nothing
@inline function _gathered_relationship_owner_volume(
        handle::Int32, anchor, owner::Int32, resources::Tuple)
    resource = first(resources)
    if resource.handle == handle
        slot = _gathered_relationship_owner_lane(resource, anchor, owner)
        slot > 0 || return nothing
        sample = @inbounds resource.endpoint_volumes[Int(slot)]
        return sample.present ? Int32(something(sample.value)) : nothing
    end
    return _gathered_relationship_owner_volume(
        handle, anchor, owner, Base.tail(resources))
end

@inline _gathered_relationship_owner_moments(
    handle::Int32, anchor, owner::Int32, ::Tuple{},
) = nothing
@inline function _gathered_relationship_owner_moments(
        handle::Int32, anchor, owner::Int32, resources::Tuple)
    resource = first(resources)
    if resource.handle == handle
        slot = _gathered_relationship_owner_lane(resource, anchor, owner)
        slot > 0 || return nothing
        return (
            _gathered_relationship_components(resource.moment_first, slot),
            _gathered_relationship_components(resource.moment_second, slot),
        )
    end
    return _gathered_relationship_owner_moments(
        handle, anchor, owner, Base.tail(resources))
end

@inline function _gathered_relationship_endpoint(
        context::_GatheredAnchorEnergyContext, ::Val{Endpoint}) where {Endpoint}
    edge = Int32(context.anchor)
    resource = _gathered_relationship_resource(
        context.relationship_handle,
        context.proposal.relationship_resources)
    read = Endpoint === :a ? resource.endpoint_a : resource.endpoint_b
    sample = _gathered_relationship_sample(
        read, edge, resource.edge_offset)
    sample === nothing && throw(ArgumentError(
        "compiled gathered relationship endpoint is unavailable"))
    return something(sample.value)
end

@inline apply_resource_operation(
    ::ResourceOperation{:endpoint_a}, arguments,
    context::_GatheredAnchorEnergyContext,
) = _gathered_relationship_endpoint(context, Val(:a))
@inline apply_resource_operation(
    ::ResourceOperation{:endpoint_b}, arguments,
    context::_GatheredAnchorEnergyContext,
) = _gathered_relationship_endpoint(context, Val(:b))

@inline function apply_resource_operation(
        ::ResourceOperation{:edge_payload}, arguments,
        context::_GatheredAnchorEnergyContext)
    edge = Int32(first(arguments))
    payload_slot = Int(last(arguments))
    resource = _gathered_relationship_resource(
        context.relationship_handle,
        context.proposal.relationship_resources)
    1 <= payload_slot <= length(resource.payload) || throw(ArgumentError(
        "compiled gathered relationship payload slot is unavailable"))
    sample = _gathered_relationship_sample(
        getfield(resource.payload, payload_slot), edge,
        resource.edge_offset)
    sample === nothing && throw(ArgumentError(
        "compiled gathered relationship payload is unavailable"))
    return something(sample.value)
end

@inline function _gathered_relationship_edge_seen(
        read, edge::Int32, lane::Int32)
    prior = Int32(1)
    while prior < lane
        sample = @inbounds read[Int(prior)]
        sample.present && sample.endpoint == edge && return true
        prior += Int32(1)
    end
    return false
end

@inline function apply_resource_operation(
        ::ResourceOperation{:degree}, arguments,
        context::_GatheredProposalContext)
    handle = Int32(first(arguments))
    owner = Int32(last(arguments))
    owner > 0 || return Int32(0)
    resource = _gathered_relationship_resource(
        handle, context.relationship_resources)
    count = Int32(0)
    lane = Int32(1)
    while lane <= length(resource.active)
        active = @inbounds resource.active[Int(lane)]
        if active.present && something(active.value) &&
                !_gathered_relationship_edge_seen(
                    resource.active, active.endpoint, lane)
            a = something(@inbounds resource.endpoint_a[Int(lane)].value)
            b = something(@inbounds resource.endpoint_b[Int(lane)].value)
            count += (a == owner || b == owner)
        end
        lane += Int32(1)
    end
    return count
end

@inline function apply_resource_operation(
        ::ResourceOperation{:linked}, arguments,
        context::_GatheredProposalContext)
    handle = Int32(arguments[1])
    endpoint_a = Int32(arguments[2])
    endpoint_b = Int32(arguments[3])
    (endpoint_a > 0 && endpoint_b > 0) || return false
    expected_a, expected_b = _canonical_endpoints(endpoint_a, endpoint_b)
    resource = _gathered_relationship_resource(
        handle, context.relationship_resources)
    lane = Int32(1)
    while lane <= length(resource.active)
        active = @inbounds resource.active[Int(lane)]
        if active.present && something(active.value)
            a = something(@inbounds resource.endpoint_a[Int(lane)].value)
            b = something(@inbounds resource.endpoint_b[Int(lane)].value)
            a == expected_a && b == expected_b && return true
        end
        lane += Int32(1)
    end
    return false
end

@inline apply_resource_operation(
    ::Union{ResourceOperation{:new_contact},ResourceOperation{:lost_contact}},
    arguments,
    context::Union{_GatheredProposalContext,_GatheredAnchorEnergyContext},
) = _proposal_endpoint_pair(arguments, _gathered_proposal(context))

@inline _gathered_contact_range(
    handle::Int32, ::Tuple{}, ::Tuple{}, index::Int32 = Int32(1),
) = (Int32(0), Int32(0))
@inline function _gathered_contact_range(
        handle::Int32, starts::Tuple, counts::Tuple,
        index::Int32 = Int32(1))
    handle == index && return (first(starts), first(counts))
    return _gathered_contact_range(
        handle, Base.tail(starts), Base.tail(counts), index + Int32(1))
end

@inline function _gathered_owner_volume(proposal::_GatheredProposalContext,
        owner::Int32)
    owner <= 0 && return Int32(0)
    return owner == proposal.old_owner ? proposal.volumes[1] :
        owner == proposal.new_owner ? proposal.volumes[2] : Int32(0)
end

@inline function _gathered_owner_volume(context::_GatheredAnchorEnergyContext,
        owner::Int32)
    proposal = context.proposal
    volume = _gathered_owner_volume(proposal, owner)
    if owner != proposal.old_owner && owner != proposal.new_owner
        relationship_volume = _gathered_relationship_owner_volume(
            context.relationship_handle, context.anchor, owner,
            proposal.relationship_resources)
        relationship_volume === nothing || (volume = relationship_volume)
    end
    if context.after && proposal.old_owner != proposal.new_owner
        owner == proposal.old_owner && (volume -= Int32(1))
        owner == proposal.new_owner && (volume += Int32(1))
    end
    return volume
end

@inline _gathered_owner_moment(::Tuple{}, owner_lane::Int) = ()
@inline function _gathered_owner_moment(values::Tuple, owner_lane::Int)
    return (
        getfield(first(values), owner_lane),
        _gathered_owner_moment(Base.tail(values), owner_lane)...,
    )
end

@inline _gathered_target_coordinates(target, ::Tuple{}, ::Type{T}, dimension::Int) where {T} = ()
@inline function _gathered_target_coordinates(
        target, components::Tuple, ::Type{T}, dimension::Int = 1,
    ) where {T}
    return (
        T(target[dimension]) - T(0.5),
        _gathered_target_coordinates(
            target, Base.tail(components), T, dimension + 1)...,
    )
end

@inline _gathered_update_first(
    ::Tuple{}, ::Tuple{}, remove::Bool, add::Bool,
) = ()
@inline function _gathered_update_first(
        values::Tuple, coordinates::Tuple, remove::Bool, add::Bool)
    value = first(values)
    remove && (value -= first(coordinates))
    add && (value += first(coordinates))
    return (
        value,
        _gathered_update_first(
            Base.tail(values), Base.tail(coordinates), remove, add)...,
    )
end

@inline _gathered_update_second(
    ::Tuple{}, coordinates::Tuple, remove::Bool, add::Bool, slot::Int,
) = ()
@inline function _gathered_update_second(
        values::Tuple, coordinates::Tuple,
        remove::Bool, add::Bool, slot::Int = 1)
    dimensions = length(coordinates)
    row = rem(slot - 1, dimensions) + 1
    column = div(slot - 1, dimensions) + 1
    value = first(values)
    product = coordinates[row] * coordinates[column]
    remove && (value -= product)
    add && (value += product)
    return (
        value,
        _gathered_update_second(
            Base.tail(values), coordinates, remove, add, slot + 1)...,
    )
end

@inline _gathered_scale_tuple(::Tuple{}, inverse) = ()
@inline function _gathered_scale_tuple(values::Tuple, inverse)
    return (
        first(values) * inverse,
        _gathered_scale_tuple(Base.tail(values), inverse)...,
    )
end

@inline _gathered_covariance_tuple(
    ::Tuple{}, center::Tuple, inverse, slot::Int,
) = ()
@inline function _gathered_covariance_tuple(
        second::Tuple, center::Tuple, inverse, slot::Int = 1)
    dimensions = length(center)
    row = rem(slot - 1, dimensions) + 1
    column = div(slot - 1, dimensions) + 1
    return (
        first(second) * inverse - center[row] * center[column],
        _gathered_covariance_tuple(
            Base.tail(second), center, inverse, slot + 1)...,
    )
end

@inline function _gathered_moment_totals(
        context::_GatheredAnchorEnergyContext,
        owner::Int32,
        ::CellMomentsTracker{N,T},
    ) where {N,T}
    proposal = context.proposal
    lane = owner == proposal.old_owner ? 1 :
        owner == proposal.new_owner ? 2 : 0
    if lane == 0
        moments = _gathered_relationship_owner_moments(
            context.relationship_handle, context.anchor, owner,
            proposal.relationship_resources)
        moments === nothing && return nothing
        first, second = moments
    else
        first = _gathered_owner_moment(proposal.moment_first, lane)
        second = _gathered_owner_moment(proposal.moment_second, lane)
    end
    count = _gathered_owner_volume(context, owner)
    if context.after && proposal.old_owner != proposal.new_owner
        coordinates = _gathered_target_coordinates(
            proposal.target, first, T)
        remove = owner == proposal.old_owner
        add = owner == proposal.new_owner
        first = _gathered_update_first(first, coordinates, remove, add)
        second = _gathered_update_second(second, coordinates, remove, add)
    end
    return count, first, second
end

@inline function _gathered_cell_center(
        context::_GatheredAnchorEnergyContext, owner::Int32)
    owner > 0 || return nothing
    descriptor = context.proposal.moment_descriptor
    descriptor === nothing && throw(ArgumentError(
        "compiled gathered cell-center tracker is unavailable"))
    totals = _gathered_moment_totals(context, owner, descriptor)
    totals === nothing && return nothing
    count, first, _ = totals
    count > 0 || return nothing
    T = eltype(first)
    inverse = inv(T(count))
    return _gathered_scale_tuple(first, inverse)
end

@inline function _gathered_cell_elongation(
        context::_GatheredAnchorEnergyContext, owner::Int32)
    owner > 0 || return context.proposal.scalar_zero
    descriptor = context.proposal.moment_descriptor
    descriptor === nothing && throw(ArgumentError(
        "compiled gathered cell-moment tracker is unavailable"))
    totals = _gathered_moment_totals(context, owner, descriptor)
    totals === nothing && return context.proposal.scalar_zero
    count, first, second = totals
    count > 0 || return context.proposal.scalar_zero
    T = eltype(first)
    N = length(first)
    inverse = inv(T(count))
    center = _gathered_scale_tuple(first, inverse)
    covariance = _gathered_covariance_tuple(second, center, inverse)
    maximum_variance = _maximum_covariance_eigenvalue(Val(N), covariance)
    return T(4) * sqrt(max(zero(T), maximum_variance))
end

@inline function _gathered_tracker_slot(
        quantity::Val, source_handle::Int32,
        descriptors::Tuple{Any,Vararg{Any}},
        values::Tuple{Any,Vararg{Any}})
    key = tracker_quantity(first(descriptors))
    key isa QualifiedTrackerKey && key.quantity === quantity &&
        key.source_handle == source_handle &&
        return (first(descriptors), first(values))
    return _gathered_tracker_slot(
        quantity, source_handle,
        Base.tail(descriptors), Base.tail(values))
end
@inline _gathered_tracker_slot(
    quantity, source_handle, ::Tuple{}, ::Tuple{},
) =
    throw(ArgumentError("compiled gathered tracker key is unavailable"))

@inline function _gathered_tracker_value(
        context::_GatheredAnchorEnergyContext,
        quantity::Val, source_handle::Int32, owner::Int32)
    owner <= 0 && return Int32(0)
    proposal = context.proposal
    descriptor, pair = _gathered_tracker_slot(
        quantity, source_handle, proposal.tracker_descriptors,
        proposal.tracker_values)
    value = owner == proposal.old_owner ? pair[1] :
        owner == proposal.new_owner ? pair[2] : zero(first(pair))
    context.after || return value
    delta = _checkerboard_scalar_tracker_delta(
        descriptor, proposal.contact_sites, proposal.contact_owners,
        proposal.contact_ranges,
        (proposal.target_linear, proposal.target),
        proposal.old_owner, proposal.new_owner)
    return _scalar_value_after(
        value, delta, owner, proposal.old_owner, proposal.new_owner)
end

@inline tracker_operation_value(
    context::_GatheredAnchorEnergyContext,
    quantity::Val,
    source_handle::Int32,
    owner::Int32,
) = _gathered_tracker_value(context, quantity, source_handle, owner)

@inline qualified_tracker_operation_call(
    ::ResourceOperation{:cell_surface},
    arguments::Tuple,
    context::_GatheredAnchorEnergyContext,
    quantity::Val,
    source_handle::Int32,
) = tracker_operation_value(
    context, quantity, source_handle, Int32(only(arguments)))


@inline function apply_resource_operation(
        ::ResourceOperation{:cell_volume}, arguments,
        context::_GatheredProposalContext)
    return _gathered_owner_volume(context, Int32(only(arguments)))
end

@inline function apply_resource_operation(
        ::ResourceOperation{:cell_volume}, arguments,
        context::_GatheredAnchorEnergyContext)
    return _gathered_owner_volume(context, Int32(only(arguments)))
end

@inline apply_resource_operation(
    ::Union{ResourceOperation{:cell_center},ResourceOperation{:unwrapped_center}},
    arguments,
    context::_GatheredAnchorEnergyContext,
) = _gathered_cell_center(context, Int32(only(arguments)))

@inline apply_resource_operation(
    ::ResourceOperation{:cell_elongation},
    arguments,
    context::_GatheredAnchorEnergyContext,
) = _gathered_cell_elongation(context, Int32(only(arguments)))

@inline evaluator_parameters(context::_GatheredAnchorEnergyContext) =
    context.proposal.parameters
@inline _compiled_evaluator_parameters(context::_GatheredAnchorEnergyContext) =
    context.proposal.parameters

@inline function _proposal_term_evaluation(
        term::_ExecutableProposalTerm{E,<:ProposalDriveRole}, context,
        ::Type{T}) where {E,T<:AbstractFloat}
    value = T(_execute_proposal_scalar(term.evaluator, context))
    return ProposalEvaluation(zero(T), zero(T), value, zero(T), true)
end

@inline function _proposal_term_evaluation(
        term::_ExecutableProposalTerm{E,<:ProposalEnergyDriveRole}, context,
        ::Type{T}) where {E,T<:AbstractFloat}
    value = T(_execute_proposal_scalar(term.evaluator, context))
    return ProposalEvaluation(zero(T), value, zero(T), zero(T), true)
end

@inline function _proposal_term_evaluation(
        term::_ExecutableProposalTerm{E,<:ProposalModifierRole}, context,
        ::Type{T}) where {E,T<:AbstractFloat}
    value = T(_execute_proposal_scalar(term.evaluator, context))
    return ProposalEvaluation(zero(T), zero(T), zero(T), value, true)
end

@inline function _proposal_term_evaluation(
        term::_ExecutableProposalTerm{E,<:HamiltonianRole{
            <:SiteEnergyDomainPlan,<:TargetSiteAffectedPlan}}, context,
        ::Type{T}) where {E,T<:AbstractFloat}
    before = _GatheredAnchorEnergyContext(context, false, context.target)
    after = _GatheredAnchorEnergyContext(context, true, context.target)
    value = T(_execute_proposal_scalar(term.evaluator, after)) -
            T(_execute_proposal_scalar(term.evaluator, before))
    return ProposalEvaluation(value, zero(T), zero(T), zero(T), true)
end

@inline function _proposal_term_evaluation(
        term::_ExecutableProposalTerm{E,<:HamiltonianRole{
            <:SiteEnergyDomainPlan,<:NeighborhoodSitesAffectedPlan}}, context,
        ::Type{T}) where {E,T<:AbstractFloat}
    role = term.role
    starts, counts = context.contact_ranges
    start, count = _gathered_contact_range(
        role.affected.relation_handle, starts, counts)
    target = context.target_linear
    before = _gathered_anchor_energy(
        term.evaluator, context, target, false, true, T)
    after = _gathered_anchor_energy(
        term.evaluator, context, target, true, true, T)
    delta = after - before
    accepted = Int32(1)
    lane = Int32(0)
    while lane < count
        center = @inbounds context.reverse_contact_sites[Int(start + lane)]
        if center > 0 && center != target
            duplicate = false
            prior = Int32(0)
            while prior < lane
                duplicate |= @inbounds(
                    context.reverse_contact_sites[Int(start + prior)]) == center
                prior += Int32(1)
            end
            if !duplicate
                accepted += Int32(1)
                accepted <= role.affected.maximum || return
                    ProposalEvaluation(T(NaN), zero(T), zero(T), zero(T), true)
                before = _gathered_anchor_energy(
                    term.evaluator, context, center, false, true, T)
                after = _gathered_anchor_energy(
                    term.evaluator, context, center, true, true, T)
                delta += after - before
            end
        end
        lane += Int32(1)
    end
    return ProposalEvaluation(delta, zero(T), zero(T), zero(T), true)
end

@inline function _gathered_anchor_energy(
        evaluator, context, anchor, after::Bool, present::Bool, ::Type{T},
    ) where {T<:AbstractFloat}
    present || return zero(T)
    return T(_execute_proposal_scalar(
        evaluator, _GatheredAnchorEnergyContext(context, after, anchor)))
end

@inline function _proposal_term_evaluation(
        term::_ExecutableProposalTerm{E,<:HamiltonianRole{
            <:CellEnergyDomainPlan,<:SourceTargetCellsAffectedPlan}}, context,
        ::Type{T}) where {E,T<:AbstractFloat}
    role = term.role
    kind = role.domain.kind
    old_owner = context.old_owner
    new_owner = context.new_owner
    delta = zero(T)
    if old_owner > 0 && context.old_kind == kind
        before = _gathered_anchor_energy(
            term.evaluator, context, old_owner, false, true, T)
        after = _gathered_anchor_energy(
            term.evaluator, context, old_owner, true,
            _gathered_owner_volume(context, old_owner) > Int32(1), T)
        delta += after - before
    end
    if new_owner > 0 && new_owner != old_owner && context.new_kind == kind
        before = _gathered_anchor_energy(
            term.evaluator, context, new_owner, false,
            _gathered_owner_volume(context, new_owner) > Int32(0), T)
        after = _gathered_anchor_energy(
            term.evaluator, context, new_owner, true, true, T)
        delta += after - before
    end
    return ProposalEvaluation(delta, zero(T), zero(T), zero(T), true)
end

@inline function _proposal_term_evaluation(
        term::_ExecutableProposalTerm{E,<:HamiltonianRole{
            <:ContactEnergyDomainPlan,<:IncidentContactsAffectedPlan}}, context,
        ::Type{T}) where {E,T<:AbstractFloat}
    starts, counts = context.contact_ranges
    start, count = _gathered_contact_range(
        term.role.domain.relation_handle, starts, counts)
    delta = zero(T)
    lane = Int32(0)
    accepted = Int32(0)
    while lane < count
        slot = start + lane
        neighbor = @inbounds context.contact_sites[Int(slot)]
        if neighbor > 0
            duplicate = false
            prior = Int32(0)
            while prior < lane
                duplicate |= @inbounds(
                    context.contact_sites[Int(start + prior)]) == neighbor
                prior += Int32(1)
            end
            if !duplicate
                accepted += Int32(1)
                accepted <= term.role.affected.maximum || return
                    ProposalEvaluation(T(NaN), zero(T), zero(T), zero(T), true)
                target = context.target_linear
                anchor = target <= neighbor ?
                    _GatheredContactAnchor(target, neighbor) :
                    _GatheredContactAnchor(neighbor, target)
                before = _gathered_anchor_energy(
                    term.evaluator, context, anchor, false, true, T)
                after = _gathered_anchor_energy(
                    term.evaluator, context, anchor, true, true, T)
                delta += after - before
            end
        end
        lane += Int32(1)
    end
    return ProposalEvaluation(delta, zero(T), zero(T), zero(T), true)
end

@inline function _gathered_relationship_owner_present(
        context, owner::Int32, after::Bool)
    owner > 0 || return false
    proposal = context
    if owner == proposal.old_owner || owner == proposal.new_owner
        view = _GatheredAnchorEnergyContext(proposal, after, owner)
        return _gathered_owner_volume(view, owner) > 0
    end
    # Packed relationship integrity proves unaffected endpoints are live at
    # stage entry. Only the proposal's old/new owners can change volume here.
    return true
end

@inline function _proposal_term_evaluation(
        term::_ExecutableProposalTerm{E,<:HamiltonianRole{
            <:RelationshipEnergyDomainPlan,
            <:IncidentRelationshipsAffectedPlan}}, context,
        ::Type{T}) where {E,T<:AbstractFloat}
    role = term.role
    handle = role.domain.relationship_handle
    resource = _gathered_relationship_resource(
        handle, context.relationship_resources)
    delta = zero(T)
    accepted = Int32(0)
    lane = Int32(1)
    while lane <= length(resource.active)
        active_sample = @inbounds resource.active[Int(lane)]
        if active_sample.present && something(active_sample.value)
            global_edge = active_sample.endpoint
            edge = global_edge - resource.edge_offset + Int32(1)
            duplicate = false
            prior = Int32(1)
            while prior < lane
                sample = @inbounds resource.active[Int(prior)]
                duplicate |= sample.present && sample.endpoint == global_edge
                prior += Int32(1)
            end
            if !duplicate
                accepted += Int32(1)
                accepted <= role.affected.maximum || return
                    ProposalEvaluation(T(NaN), zero(T), zero(T), zero(T), true)
                a = something(@inbounds resource.endpoint_a[Int(lane)].value)
                b = something(@inbounds resource.endpoint_b[Int(lane)].value)
                before_present =
                    _gathered_relationship_owner_present(context, a, false) &&
                    _gathered_relationship_owner_present(context, b, false)
                after_present =
                    _gathered_relationship_owner_present(context, a, true) &&
                    _gathered_relationship_owner_present(context, b, true)
                before = before_present ? T(_execute_proposal_scalar(
                    term.evaluator,
                    _GatheredAnchorEnergyContext(
                        context, false, edge, handle))) : zero(T)
                after = after_present ? T(_execute_proposal_scalar(
                    term.evaluator,
                    _GatheredAnchorEnergyContext(
                        context, true, edge, handle))) : zero(T)
                delta += after - before
            end
        end
        lane += Int32(1)
    end
    return ProposalEvaluation(delta, zero(T), zero(T), zero(T), true)
end

@inline function _proposal_term_evaluation(
        term::_ExecutableProposalTerm{E,<:HamiltonianRole}, context,
        ::Type{T}) where {E,T<:AbstractFloat}
    throw(ArgumentError(
        "Hamiltonian source $(term.source_handle) requires affected-anchor lowering"
    ))
end

@inline _proposal_constraint_allowed(
    term::_ExecutableProposalTerm{E,<:ProposalConstraintRole}, context,
) where {E} = begin
    value = _execute_proposal_scalar(term.evaluator, context)
    value isa Bool || throw(ArgumentError(
        "proposal constraint source $(term.source_handle) does not return Bool"))
    value
end

@inline _proposal_constraint_allowed(term::_ExecutableProposalTerm, context) = true

# Constraints are an admission predicate, not a numerical contribution.  Fold
# them independently so the device compiler never has to carry the dynamic
# admission result through the substantially larger Hamiltonian accumulator.
@inline _fold_executable_proposal_constraints(
    ::Tuple{}, context, result::Bool,
) = result

@inline function _fold_executable_proposal_constraints(
        terms::Tuple, context, result::Bool)
    allowed = result & _proposal_constraint_allowed(first(terms), context)
    return _fold_executable_proposal_constraints(
        Base.tail(terms), context, allowed)
end

@inline _fold_executable_proposal_constraints(terms::Tuple, context) =
    _fold_executable_proposal_constraints(terms, context, true)

@inline _proposal_numeric_evaluation(
    term::_ExecutableProposalTerm{E,<:ProposalConstraintRole}, context,
    ::Type{T},
) where {E,T<:AbstractFloat} = _neutral_proposal_evaluation(T)

@inline _proposal_numeric_evaluation(
    term::_ExecutableProposalTerm, context, ::Type{T},
) where {T<:AbstractFloat} = _proposal_term_evaluation(term, context, T)

@inline _fold_executable_proposal_numeric_terms(
    ::Tuple{}, context, ::Type{T}, result::ProposalEvaluation{T},
) where {T<:AbstractFloat} = result

@inline function _fold_executable_proposal_numeric_terms(
        terms::Tuple, context, ::Type{T}, result::ProposalEvaluation{T},
    ) where {T<:AbstractFloat}
    contribution = _proposal_numeric_evaluation(
        first(terms), context, T)::ProposalEvaluation{T}
    combined = ProposalEvaluation(
        getfield(result, :delta_h) + getfield(contribution, :delta_h),
        getfield(result, :drive_energy) +
            getfield(contribution, :drive_energy),
        getfield(result, :drive_log_bias) +
            getfield(contribution, :drive_log_bias),
        getfield(result, :kinetic_modifier) +
            getfield(contribution, :kinetic_modifier),
        true,
    )
    return _fold_executable_proposal_numeric_terms(
        Base.tail(terms), context, T, combined)
end

@inline function _fold_executable_proposal_terms(
        terms::Tuple, context, ::Type{T}) where {T<:AbstractFloat}
    numeric = _fold_executable_proposal_numeric_terms(
        terms, context, T, _neutral_proposal_evaluation(T))
    return ProposalEvaluation(
        getfield(numeric, :delta_h),
        getfield(numeric, :drive_energy),
        getfield(numeric, :drive_log_bias),
        getfield(numeric, :kinetic_modifier),
        _fold_executable_proposal_constraints(terms, context),
    )
end
