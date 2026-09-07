# Warm gathered proposal evaluation over the bounded values selected by the
# cold checkerboard compiler. No requirement inventory or lowering authority
# is stored here.

@inline _execute_proposal_scalar(value::_ExecutableLiteral, context) =
    value.value
@inline _execute_proposal_scalar(value::_ExecutableDefaultParameter, context) =
    value.value
@inline _execute_proposal_scalar(
    ::_ExecutableParameter{Index}, context) where {Index} =
    getfield(_proposal_parameters(context), Index)
@inline _execute_proposal_scalar(
    value::_ExecutableStateReference, context) = value
@inline _execute_proposal_scalar(
    value::_ExecutableTrackerKey, context) = value
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
        I,T,P,V,S,O,K,RS,RO,RK,R,TV,TC,TD,TCD,MF,MS,MD,RR,
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
    bounded_tracker_samples::TC
    tracker_descriptors::TD
    bounded_tracker_descriptors::TCD
    moment_first::MF
    moment_second::MS
    moment_descriptor::MD
    relationship_resources::RR
end

@generated function _gathered_proposal_context(arguments...)
    length(arguments) == 30 || error(
        "gathered proposal context construction schema changed")
    context_type = _GatheredProposalContext{
        arguments[1],arguments[13:30]...}
    values = (:(getfield(arguments, $index)) for index in 1:30)
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
    anchor = _gathered_fold_anchor(context)
    center_lane = anchor == proposal.target_linear ? Int32(0) :
        _gathered_tuple_position(anchor, proposal.reverse_contact_sites)
    first_lane = iszero(center_lane) ? start :
        (center_lane - Int32(1)) * Int32(length(proposal.contact_sites)) + start
    outcome = if reference isa _ExecutableStateReference
        values = getfield(
            proposal.state_values, _executable_state_slot(reference))
        samples = iszero(center_lane) ? values.contacts : values.affected_contacts
        LocalMath.evaluate_bounded(fold, samples, first_lane, count)
    else
        key = _executable_tracker_key(reference)
        samples = _gathered_bounded_tracker_samples(
            key, proposal.bounded_tracker_descriptors,
            proposal.bounded_tracker_samples)
        LocalMath.evaluate_bounded(fold, samples, start, count)
    end
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

@inline function _gathered_bounded_tracker_samples(
        key,
        descriptors::Tuple{Any,Vararg{Any}},
        values::Tuple{Any,Vararg{Any}},
    )
    isequal(tracker_quantity(first(descriptors)), key) && return first(values)
    return _gathered_bounded_tracker_samples(
        key, Base.tail(descriptors), Base.tail(values))
end
@inline _gathered_bounded_tracker_samples(
    key, descriptors::Tuple{Any}, values::Tuple{Any},
) = isequal(tracker_quantity(first(descriptors)), key) ? first(values) :
    _gathered_bounded_tracker_samples(key, (), ())
@inline _gathered_bounded_tracker_samples(key, ::Tuple{}, ::Tuple{}) =
    throw(ArgumentError("compiled bounded tracker source is unavailable"))

@inline function _gathered_tracker_value(
        context::_GatheredAnchorEnergyContext,
        quantity::Val, source_handle::Int32, owner::Int32)
    proposal = context.proposal
    descriptor, pair = _gathered_tracker_slot(
        quantity, source_handle, proposal.tracker_descriptors,
        proposal.tracker_values)
    owner <= 0 && return zero(first(pair))
    lane = owner == proposal.old_owner ? 1 : owner == proposal.new_owner ? 2 : 0
    # Cold compiler validation admits only the source, target, or energy-anchor
    # owner here. Keep the device body total; an unrelated owner is therefore
    # an unreachable zero lane, not a second runtime validation authority.
    iszero(lane) && return zero(first(pair))
    value = pair[lane]
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
    # Tuple order is the descriptor source-table order and is scientifically
    # observable for non-associative floating-point terms.
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
