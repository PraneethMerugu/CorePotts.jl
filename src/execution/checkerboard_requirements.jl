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
        source = _descriptor_source(
            plan,
            descriptor;
            operation = descriptor.evaluator.expression,
            context = :proposal_requirement_lowering,
        )
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

struct _ExecutableTrackerKey{Quantity,SourceHandle} end
@inline _executable_tracker_key(
    ::_ExecutableTrackerKey{Quantity,0}
) where {Quantity} = Val(Quantity)
@inline _executable_tracker_key(
    ::_ExecutableTrackerKey{Quantity,SourceHandle}
) where {Quantity,SourceHandle} =
    QualifiedTrackerKey(Val(Quantity), SourceHandle)

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

_record_tracker_requirements!(
    keys, ::AbstractStaticExpression, bounded_keys = nothing
) = nothing
function _record_tracker_requirements!(
        keys, expression::OperationExpression, bounded_keys = nothing)
    operation = expression.operation
    if operation isa QualifiedTrackerOperation
        key = QualifiedTrackerKey(
            operation.quantity, operation.source_handle)
        any(isequal(key), keys) || push!(keys, key)
    elseif operation isa ResourceOperation{:bounded_fold} &&
            length(expression.arguments) == 4
        source = expression.arguments[2]
        if source isa LiteralExpression &&
                source.value isa Union{Val,QualifiedTrackerKey}
            key = source.value
            any(isequal(key), keys) || push!(keys, key)
            bounded_keys === nothing ||
                any(isequal(key), bounded_keys) || push!(bounded_keys, key)
        end
    end
    foreach(expression.arguments) do argument
        _record_tracker_requirements!(keys, argument, bounded_keys)
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
    tracker_keys = Any[]
    bounded_tracker_keys = Any[]
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
            tracker_keys, descriptor.evaluator.expression,
            bounded_tracker_keys)
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
        _record_tracker_requirements!(tracker_keys,
            descriptor.condition.expression, bounded_tracker_keys)
        _record_tracker_requirements!(tracker_keys,
            descriptor.value.expression, bounded_tracker_keys)
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
        _record_tracker_requirements!(tracker_keys,
            descriptor.condition.expression, bounded_tracker_keys)
        _record_tracker_requirements!(tracker_keys,
            effect.endpoint_a.expression, bounded_tracker_keys)
        _record_tracker_requirements!(tracker_keys,
            effect.endpoint_b.expression, bounded_tracker_keys)
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
            _record_tracker_requirements!(tracker_keys, evaluator.expression,
                bounded_tracker_keys)
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
        bounded_tracker_descriptors = _tracker_requirement_descriptors(
            bounded_tracker_keys, tracker_plan),
        moment_descriptor = _moment_requirement_descriptor(
            moment_required[], tracker_plan),
        relationship_handles = Tuple(relationship_handles))
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
        source = _descriptor_source(
            descriptor_plan,
            descriptor;
            operation = descriptor.effect,
            role = descriptor.stage,
            context = :accepted_relationship_lowering,
        )
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
        source = _descriptor_source(
            descriptor_plan,
            descriptor;
            operation = descriptor.effect,
            role = descriptor.stage,
            context = :accepted_site_lowering,
        )
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
    (arguments[2] isa StateExpression ||
        (arguments[2] isa LiteralExpression &&
         arguments[2].value isa Union{Val,QualifiedTrackerKey})) &&
    arguments[3] isa LiteralExpression &&
    arguments[3].value isa Integer || throw(ArgumentError(
        "proposal source $(repr(source)) requires bounded_fold with a " *
        "literal LocalMath.BoundedFold, a bound state or tracker, and a declared " *
        "bounded relation handle"))
    fold_source = arguments[2]
    if fold_source isa LiteralExpression &&
            fold_source.value isa Union{Val,QualifiedTrackerKey}
        anchor = arguments[4]
        anchor isa ContextExpression &&
            anchor.operation isa ContextOperation{:target_site} || throw(
                ArgumentError(
                    "proposal source $(repr(source)) requires bounded tracker " *
                    "gathers to use the proposal target anchor"))
    end
    return nothing
end

_validate_gathered_operation_arguments(
    ::AbstractContextualOperation, arguments, source) = nothing

function _validate_gathered_operation_arguments(
        ::QualifiedTrackerOperation, arguments, source)
    length(arguments) == 1 || throw(ArgumentError(
        "proposal source $(repr(source)) requires a unary qualified tracker operation"))
    owner = only(arguments)
    supported = owner isa LiteralExpression && owner.value isa Integer &&
        owner.value <= 0
    supported |= owner isa ContextExpression && owner.operation isa Union{
        ContextOperation{:source_cell},
        ContextOperation{:target_cell},
        ContextOperation{:energy_anchor_cell},
    }
    supported || throw(ArgumentError(
        "proposal source $(repr(source)) requests a tracker value for an owner " *
        "that is not one of the bounded source, target, or cell-anchor owners"
    ))
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
    arguments = ntuple(length(expression.arguments)) do index
        argument = getfield(expression.arguments, index)
        if operation isa ResourceOperation{:bounded_fold} && index == 2 &&
                argument isa LiteralExpression
            key = argument.value
            if key isa Val
                return _ExecutableTrackerKey{typeof(key).parameters[1],0}()
            elseif key isa QualifiedTrackerKey
                return _ExecutableTrackerKey{
                    typeof(key.quantity).parameters[1],Int(key.source_handle)}()
            end
        end
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
        source = _descriptor_source(
            plan,
            descriptor;
            operation = descriptor.evaluator.expression,
            context = :proposal_term_lowering,
        )
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
