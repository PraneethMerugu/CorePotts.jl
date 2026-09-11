# Cold lowering of Core-owned boundary effects into ordinary LocalMath laws.
# StageExecutionPlan remains the scientific authority; every value defined here
# is either construction scratch or an executable isbits evaluator.

struct _CheckerboardStageSiteDomain end
struct _CheckerboardStageModelDomain end
struct _CheckerboardStageCellDomain end
struct _CheckerboardStageStatusDomain end
struct _CheckerboardStageGateDomain end
struct _CheckerboardHistoryDomain end
struct _CheckerboardHistorySourceDomain end
struct _CheckerboardRelationshipRequestDomain end
struct _CheckerboardRelationshipCellDomain end

struct _GatheredSiteStageContext{P, H, V, Z, O, K, S, B, C, R, G}
    parameters::P
    handles::H
    values::V
    zeros::Z
    ownership::O
    kinds::K
    shape::S
    periodic::B
    medium_kind::Int16
    contact_offsets::C
    contact_starts::R
    contact_counts::R
    item::Int32
    rng::G
end

struct _GatheredModelStageContext{P, H, V, Z, G}
    parameters::P
    handles::H
    values::V
    zeros::Z
    rng::G
end

struct _GatheredCellStageContext{P, H, V, Z, G, D, Q}
    parameters::P
    handles::H
    values::V
    zeros::Z
    cell::Int32
    rng::G
    tracker_keys::D
    tracker_values::Q
end

@inline function apply_resource_operation(
        ::ResourceOperation{:draw}, arguments,
        context::Union{_GatheredSiteStageContext, _GatheredModelStageContext, _GatheredCellStageContext}
    )
    return _scheduled_draw(arguments, context.rng)
end

@inline stage_cell(context::_GatheredCellStageContext) = context.cell
@inline _execute_proposal_scalar(::_ExecutableProposalContext{:energy_anchor_cell}, context::_GatheredCellStageContext) = stage_cell(context)
@inline stage_site(::ModelStageSite, ::_GatheredCellStageContext) = Int32(1)
@inline _proposal_parameters(context::_GatheredCellStageContext) = context.parameters
@inline function state_value(context::_GatheredCellStageContext, ::_ExecutableStateReference{Index}, slot) where {Index}
    return _gathered_stage_read_value(getfield(context.values, Index), Int32(slot), getfield(context.zeros, Index))
end

@inline function _cell_stage_tracker_value(context::_GatheredCellStageContext, key)
    return _gathered_bounded_tracker_samples(key, context.tracker_keys, context.tracker_values)
end
@inline apply_resource_operation(
    ::ResourceOperation{:cell_volume}, arguments,
    context::_GatheredCellStageContext
) = _cell_stage_tracker_value(context, Val(:cell_volume))
@inline function qualified_tracker_operation_call(
        ::Union{ResourceOperation{:cell_site_sum}, ResourceOperation{:cell_site_minimum}}, arguments::Tuple,
        context::_GatheredCellStageContext, quantity::Val, source_handle::Int32
    )
    _, value = _gathered_tracker_slot(quantity, source_handle, context.tracker_keys, context.tracker_values)
    return value
end

struct _GatheredRelationshipStageContext{P, H, V, Z, E, Q, U, M, T}
    parameters::P
    handles::H
    values::V
    zeros::Z
    endpoints::E
    payload::Q
    volumes::U
    moments::M
    scalar_zero::T
    anchor::Int32
end

@inline _gathered_site_stage_context(args...) =
    _GatheredSiteStageContext(args...)
@inline _gathered_model_stage_context(args...) =
    _GatheredModelStageContext(args...)
@inline _gathered_cell_stage_context(args...) =
    _GatheredCellStageContext(args...)
@inline _gathered_relationship_stage_context(args...) =
    _GatheredRelationshipStageContext(args...)
@inline _stage_state_reference(handle, ::Val{Index}) where {Index} =
    _ExecutableStateReference{Index, typeof(handle)}(handle)

@inline _proposal_parameters(context::_GatheredSiteStageContext) =
    context.parameters
@inline _proposal_parameters(context::_GatheredModelStageContext) =
    context.parameters
@inline _proposal_parameters(context::_GatheredRelationshipStageContext) =
    context.parameters
@inline evaluator_parameters(context::_GatheredRelationshipStageContext) =
    context.parameters
@inline _compiled_evaluator_parameters(
    context::_GatheredRelationshipStageContext
) = context.parameters

@inline context_value(
    ::ContextOperation{:energy_anchor_relationship},
    context::_GatheredRelationshipStageContext
) = context.anchor

@inline function _compiled_context_value(
        operation::ContextOperation{Identity},
        context::_GatheredRelationshipStageContext
    ) where {Identity}
    return context_value(operation, context)
end

@inline apply_resource_operation(
    ::ResourceOperation{:endpoint_a}, arguments,
    context::_GatheredRelationshipStageContext
) = context.endpoints[1]
@inline apply_resource_operation(
    ::ResourceOperation{:endpoint_b}, arguments,
    context::_GatheredRelationshipStageContext
) = context.endpoints[2]
@inline function apply_resource_operation(
        ::ResourceOperation{:edge_payload}, arguments,
        context::_GatheredRelationshipStageContext
    )
    return getfield(context.payload, Int(last(arguments)))
end

@inline function _relationship_endpoint_lane(context, owner::Int32)
    owner == context.endpoints[1] && return 1
    owner == context.endpoints[2] && return 2
    return 0
end

@inline function apply_resource_operation(
        ::ResourceOperation{:cell_volume}, arguments,
        context::_GatheredRelationshipStageContext
    )
    lane = _relationship_endpoint_lane(context, Int32(only(arguments)))
    lane == 0 && return Int32(0)
    sample = @inbounds context.volumes[lane]
    return sample.present ? something(sample.value) : Int32(0)
end

@inline function _gathered_relationship_center(context, owner::Int32)
    lane = _relationship_endpoint_lane(context, owner)
    lane == 0 && return nothing
    volume = @inbounds context.volumes[lane]
    moments = @inbounds context.moments[lane]
    volume.present && moments.present || return nothing
    count = something(volume.value)
    count > 0 || return nothing
    inverse = inv(typeof(context.scalar_zero)(count))
    values = something(moments.value)
    return map(value -> value * inverse, values)
end

@inline apply_resource_operation(
    ::ResourceOperation{:unwrapped_center}, arguments,
    context::_GatheredRelationshipStageContext
) =
    _gathered_relationship_center(context, Int32(only(arguments)))
@inline apply_resource_operation(
    ::ResourceOperation{:cell_center}, arguments,
    context::_GatheredRelationshipStageContext
) =
    _gathered_relationship_center(context, Int32(only(arguments)))
@inline apply_resource_operation(
    ::ResourceOperation{:distance}, arguments,
    ::_GatheredRelationshipStageContext
) =
    _center_distance(first(arguments), last(arguments))

@inline function _compiled_resource_operation(
        operation::ResourceOperation{Identity}, arguments::Tuple,
        context::_GatheredRelationshipStageContext
    ) where {Identity}
    return apply_resource_operation(operation, arguments, context)
end

@inline function state_value(
        context::_GatheredRelationshipStageContext,
        ::_ExecutableStateReference{Index}, site
    ) where {Index}
    endpoint = Int32(site)
    return _gathered_stage_read_value(
        getfield(context.values, Index), endpoint,
        getfield(context.zeros, Index)
    )
end

@inline function apply_resource_operation(
        ::ResourceOperation{:field_value}, arguments,
        context::_GatheredRelationshipStageContext,
    )
    return state_value(context, first(arguments), last(arguments))
end

@inline stage_site(
    ::IterationStageSite,
    context::_GatheredSiteStageContext
) =
    _checkerboard_cartesian_site(context.shape, context.item)
@inline stage_site(::ModelStageSite, ::_GatheredModelStageContext) = 1
@inline stage_site(::ModelStageSite, ::_GatheredSiteStageContext) = 1
@inline _execute_proposal_scalar(::_ExecutableProposalContext{:energy_anchor_site}, context::_GatheredSiteStageContext) =
    _stage_linear_index(context.shape, stage_site(IterationStageSite(), context))

@inline _stage_linear_index(shape, site::Int32) = site
@inline _stage_linear_index(shape, site::Integer) = Int32(site)
@inline function _stage_linear_index(
        shape::NTuple{N, Int},
        site::CartesianIndex{N}
    ) where {N}
    linear = Int32(1)
    stride = Int32(1)
    for axis in 1:N
        linear += Int32(site[axis] - 1) * stride
        stride *= Int32(shape[axis])
    end
    return linear
end

@inline function _gathered_stage_read_value(read, endpoint::Int32, fallback)
    for lane in 1:length(read)
        sample = @inbounds read[lane]
        sample.present && sample.endpoint == endpoint &&
            return something(sample.value)
    end
    return fallback
end

@inline function state_value(
        context::_GatheredSiteStageContext,
        ::_ExecutableStateReference{Index}, site
    ) where {Index}
    endpoint = _stage_linear_index(context.shape, site)
    return _gathered_stage_read_value(
        getfield(context.values, Index), endpoint,
        getfield(context.zeros, Index)
    )
end

@inline function state_value(
        context::_GatheredModelStageContext,
        ::_ExecutableStateReference{Index}, site
    ) where {Index}
    return _gathered_stage_read_value(
        getfield(context.values, Index), Int32(1),
        getfield(context.zeros, Index)
    )
end

@inline function site_owner(context::_GatheredSiteStageContext, site)
    endpoint = _stage_linear_index(context.shape, site)
    return _gathered_stage_read_value(
        context.ownership, endpoint, Int32(0)
    )
end

@inline function owner_kind(context::_GatheredSiteStageContext, owner::Integer)
    key = Int32(owner)
    key == 0 && return context.medium_kind
    key < 0 && return Int16(-key)
    for lane in 1:length(context.ownership)
        owner_sample = @inbounds context.ownership[lane]
        kind_sample = @inbounds context.kinds[lane]
        owner_sample.present && kind_sample.present &&
            something(owner_sample.value) == key &&
            return something(kind_sample.value)
    end
    return Int16(0)
end

@inline function relation_count(
        context::_GatheredSiteStageContext, relation_handle::Integer
    )
    handle = Int(relation_handle)
    1 <= handle <= length(context.contact_counts) || return 0
    return Int(@inbounds context.contact_counts[handle])
end

@inline function relation_neighbor_site(
        context::_GatheredSiteStageContext,
        relation_handle::Integer,
        center::CartesianIndex{N},
        direction::Integer,
    ) where {N}
    handle = Int(relation_handle)
    1 <= handle <= length(context.contact_starts) || return nothing
    start = Int(@inbounds context.contact_starts[handle])
    count = Int(@inbounds context.contact_counts[handle])
    1 <= direction <= count && start > 0 || return nothing
    offset = @inbounds context.contact_offsets[start + direction - 1]
    coordinates = ntuple(Val(N)) do axis
        raw = center[axis] + offset[axis]
        context.periodic[axis] ? mod1(raw, context.shape[axis]) :
            (1 <= raw <= context.shape[axis] ? raw : 0)
    end
    any(iszero, coordinates) && return nothing
    return CartesianIndex(coordinates)
end

struct _CompiledSiteStageEvaluator{HasParameters, Evaluation, T, C, V, H, Z, S, B, O, R}
    condition::C
    value::V
    handles::H
    zeros::Z
    shape::S
    periodic::B
    medium_kind::Int16
    contact_offsets::O
    contact_starts::R
    contact_counts::R
    source_handle::Int32
    trajectory_key::NTuple{2, UInt64}
    boundary::UInt16
end

struct _CompiledModelStageEvaluator{HasParameters, Evaluation, T, C, V, H, Z}
    condition::C
    value::V
    handles::H
    zeros::Z
    source_handle::Int32
    trajectory_key::NTuple{2, UInt64}
    boundary::UInt16
end

struct _CompiledCellStageEvaluator{HasParameters, Evaluation, T, C, V, H, Z, E, D}
    condition::C
    value::V
    handles::H
    zeros::Z
    source_handle::Int32
    effect::E
    trajectory_key::NTuple{2, UInt64}
    boundary::UInt16
    tracker_keys::D
end

@generated function _stage_read_prefix(reads, ::H) where {H <: Tuple}
    return Expr(
        :tuple, (
            :(getfield(reads, $index)) for index in 1:fieldcount(H)
        )...
    )
end

@inline function _compiled_stage_result(
        condition, value, baseline, source_handle::Int32,
        item::Int32, mcs::Int64
    )
    condition_valid = condition isa Bool
    enabled = condition_valid && condition
    result = enabled ? value : baseline
    value_valid = !enabled || _state_value_isfinite(result)
    invalid = !condition_valid || !value_valid
    detail = condition_valid ? LifecycleDetailNonfiniteResult :
        LifecycleDetailTriggerNotBoolean
    status = ProgramStatus(
        ProgramStatusEvaluator,
        Int32(mcs),
        ProgramStageState,
        source_handle,
        UInt64(item),
        Int32(0),
        item,
        detail,
        Int32(0), Int32(0), Int32(0)
    )
    return (
        value = result,
        enabled,
        status = LocalMath.RoutedResolutionValue(
            Int32(1), item, status, invalid
        ),
    )
end

@inline function (evaluator::_CompiledSiteStageEvaluator{HasParameters, Evaluation, T})(
        item::Int32, reads, parameters
    ) where {HasParameters, Evaluation, T}
    count = length(evaluator.handles)
    values = _stage_read_prefix(reads, evaluator.handles)
    ownership = getfield(reads, count + 1)
    kinds = getfield(reads, count + 2)
    science_parameters = HasParameters ?
        something(getfield(reads, count + 3)[1].value) : ()
    context = _gathered_site_stage_context(
        science_parameters, evaluator.handles, values,
        evaluator.zeros, ownership, kinds, evaluator.shape,
        evaluator.periodic, evaluator.medium_kind,
        evaluator.contact_offsets, evaluator.contact_starts,
        evaluator.contact_counts, item,
        _scheduled_rng_context(
            T, evaluator.trajectory_key, getfield(parameters, 1), evaluator.boundary,
            SiteEntity, UInt32(item), UInt64(0), getfield(parameters, 2)
        )
    )
    condition = _execute_proposal_scalar(evaluator.condition, context)
    target = first(evaluator.handles)
    baseline = state_value(
        context, _stage_state_reference(target, Val(1)),
        stage_site(IterationStageSite(), context)
    )
    value = condition isa Bool && condition ?
        convert(typeof(baseline), _execute_proposal_scalar(evaluator.value, context)) : baseline
    result = _compiled_stage_result(
        condition, value, baseline, evaluator.source_handle,
        item, getfield(parameters, 1)
    )
    return (value = LocalMath.UniqueValue(Evaluation(result.enabled, result.value)), status = result.status)
end

@inline function (evaluator::_CompiledModelStageEvaluator{HasParameters, Evaluation, T})(
        item::Int32, reads, parameters
    ) where {HasParameters, Evaluation, T}
    count = length(evaluator.handles)
    values = _stage_read_prefix(reads, evaluator.handles)
    science_parameters = HasParameters ?
        something(getfield(reads, count + 1)[1].value) : ()
    context = _gathered_model_stage_context(
        science_parameters, evaluator.handles, values,
        evaluator.zeros,
        _scheduled_rng_context(
            T, evaluator.trajectory_key, getfield(parameters, 1), evaluator.boundary,
            ModelEntity, UInt32(0), UInt64(0), getfield(parameters, 2)
        )
    )
    condition = _execute_proposal_scalar(evaluator.condition, context)
    target = first(evaluator.handles)
    baseline = state_value(
        context, _stage_state_reference(target, Val(1)), 1
    )
    value = condition isa Bool && condition ?
        convert(typeof(baseline), _execute_proposal_scalar(evaluator.value, context)) : baseline
    result = _compiled_stage_result(
        condition, value, baseline, evaluator.source_handle,
        item, getfield(parameters, 1)
    )
    return (
        value = LocalMath.UniqueValue(Evaluation(result.enabled, result.value)),
        status = result.status,
    )
end

struct _CompiledStageCommit{E <: AbstractCompiledEffect} end
_CompiledStageCommit(::E) where {E <: AbstractCompiledEffect} = _CompiledStageCommit{E}()

@inline function (evaluator::_CompiledCellStageEvaluator{HasParameters, Evaluation, T})(item::Int32, reads, parameters) where {HasParameters, Evaluation, T}
    count = length(evaluator.handles)
    values = _stage_read_prefix(reads, evaluator.handles)
    kind = something(getfield(reads, count + 1)[1].value)
    generation = something(getfield(reads, count + 2)[1].value)
    science_parameters = HasParameters ? something(getfield(reads, count + 3)[1].value) : ()
    context = _gathered_cell_stage_context(
        science_parameters, evaluator.handles, values, evaluator.zeros, item,
        _scheduled_rng_context(
            T, evaluator.trajectory_key, getfield(parameters, 1), evaluator.boundary,
            CellEntity, UInt32(item), generation, getfield(parameters, 2)
        ),
        evaluator.tracker_keys,
        _checkerboard_terminal_state_values(reads, Val(length(evaluator.tracker_keys)), Val(count + 2 + Int(HasParameters)))
    )
    baseline = state_value(context, _stage_state_reference(first(evaluator.handles), Val(1)), item)
    eligible = _cell_stage_eligible(evaluator.effect, kind, generation)
    condition = eligible ? _execute_proposal_scalar(evaluator.condition, context) : false
    value = condition isa Bool && condition ? convert(typeof(baseline), _execute_proposal_scalar(evaluator.value, context)) : baseline
    result = _compiled_stage_result(condition, value, baseline, evaluator.source_handle, item, getfield(parameters, 1))
    return (value = LocalMath.UniqueValue(Evaluation(result.enabled, result.value)), status = result.status)
end

@inline function (::_CompiledStageCommit{E})(item::Int32, reads, parameters) where {
        E <: Union{SiteAssignmentEffect, IteratedSiteAssignmentEffect, ModelAssignmentEffect, CellAssignmentEffect},
    }
    evaluation = something(@inbounds reads[1][1].value)
    return (value = LocalMath.ConditionalUniqueValue(evaluation.value, evaluation.enabled),)
end

struct _CheckerboardMomentTupleView{
        N, T, A <: AbstractMatrix{T},
    } <: AbstractVector{NTuple{N, T}}
    values::A
end
Base.IndexStyle(::Type{<:_CheckerboardMomentTupleView}) = IndexLinear()
Base.size(view::_CheckerboardMomentTupleView) = (size(view.values, 2),)
Base.length(view::_CheckerboardMomentTupleView) = size(view.values, 2)
Base.strides(::_CheckerboardMomentTupleView) = (1,)
Base.parent(view::_CheckerboardMomentTupleView) = view.values
Base.dataids(view::_CheckerboardMomentTupleView) = Base.dataids(view.values)
@inline function Base.getindex(
        view::_CheckerboardMomentTupleView{N}, index::Int
    ) where {N}
    @boundscheck checkbounds(view, index)
    return ntuple(dimension -> @inbounds(view.values[dimension, index]), N)
end
KernelAbstractions.get_backend(view::_CheckerboardMomentTupleView) =
    KernelAbstractions.get_backend(view.values)
_checkerboard_moment_tuple_view(values::AbstractMatrix{T}) where {T} =
    _CheckerboardMomentTupleView{
    size(values, 1), T, typeof(values),
}(values)
Adapt.adapt_structure(to, view::_CheckerboardMomentTupleView{N}) where {N} =
    _checkerboard_moment_tuple_view(Adapt.adapt(to, view.values))

struct _BoundaryRelationshipTerm{C, P, Z}
    condition::C
    payload::P
    payload_zero::Z
    code::Int32
    bank_slot::Int32
    edge_count::Int32
    source_handle::Int32
end

struct _BoundaryRelationshipEndpointEvaluator end
@inline function (::_BoundaryRelationshipEndpointEvaluator)(
        item::Int32, reads, parameters
    )
    a = something(@inbounds reads[1][1].value)
    b = something(@inbounds reads[2][1].value)
    return (endpoints = LocalMath.UniqueValue((a, b)),)
end

struct _BoundaryRelationshipRequestEvaluator{P, T, H, Z, N, S}
    terms::T
    handles::H
    zeros::Z
    scalar_zero::N
    stops::S
end

@generated function (evaluator::_BoundaryRelationshipRequestEvaluator{P})(
        item::Int32, reads, parameters
    ) where {P}
    T = fieldtype(evaluator, :terms)
    H = fieldtype(evaluator, :handles)
    handle_count = fieldcount(H)
    state_offset = 2 + P
    volume_index = state_offset + handle_count + 1
    moment_index = volume_index + 1
    parameter_index = moment_index + 1
    state_values = Expr(
        :tuple,
        [
            :(getfield(reads, $(state_offset + index)))
                for index in 1:handle_count
        ]...
    )
    payload_values = [
        :(
                something(
                    @inbounds getfield(
                        reads, $(2 + index)
                    )[1].value
                )
            ) for index in 1:P
    ]
    branches = Expr(:block)
    for term_index in 1:fieldcount(T)
        prior = term_index == 1 ? :(Int32(0)) :
            :(getfield(evaluator.stops, $(term_index - 1)))
        stop = :(getfield(evaluator.stops, $term_index))
        payload = Expr(
            :tuple, [
                :(
                        begin
                            local value = _execute_proposal_scalar(
                                getfield(term.payload, $index), context
                            )
                            value
                        end
                    ) for index in 1:P
            ]...
        )
        event_payload = [:(getfield(payload, $index)) for index in 1:P]
        push!(
            branches.args, quote
                if item <= $stop
                    local term = getfield(evaluator.terms, $term_index)
                    local edge = item - $prior
                    local endpoints = something(@inbounds reads[2][1].value)
                    local science_parameters = @inbounds(
                            getfield(reads, $parameter_index)[1].present
                        ) ?
                        something(
                            @inbounds getfield(
                                reads, $parameter_index
                            )[1].value
                        ) : ()
                    local context = _gathered_relationship_stage_context(
                        science_parameters, evaluator.handles, $state_values,
                        evaluator.zeros, endpoints,
                        ($(payload_values...),),
                        getfield(reads, $volume_index),
                        getfield(reads, $moment_index), evaluator.scalar_zero,
                        edge
                    )
                    local active = something(@inbounds reads[1][1].value)
                    local condition = active ? _execute_proposal_scalar(
                            term.condition, context
                        ) : false
                    local condition_valid = condition isa Bool
                    local enabled = condition_valid && condition &&
                        something(@inbounds reads[1][1].value)
                    local payload = enabled ? $payload : term.payload_zero
                    local payload_valid = !enabled || all(isfinite, payload)
                    local invalid = !condition_valid || !payload_valid
                    local status = ProgramStatus(
                        ProgramStatusEvaluator, getfield(parameters, 1),
                        ProgramStageState, term.source_handle,
                        UInt64(UInt32(term.source_handle)) << 32 |
                            UInt64(UInt32(edge)), Int32(0), edge,
                        condition_valid ? LifecycleDetailNonfiniteResult :
                            LifecycleDetailTriggerNotBoolean,
                        Int32(0), Int32(0), Int32(0)
                    )
                    local event = (
                        term.code, term.bank_slot, edge,
                        $(event_payload...),
                        UInt32(item), enabled && !invalid,
                    )
                    return (
                        event = LocalMath.UniqueValue(event),
                        status = LocalMath.RoutedResolutionValue(
                            Int32(1), item, status, invalid
                        ),
                    )
                end
            end
        )
    end
    return quote
        $branches
        error("relationship request item escaped its compiled ranges")
    end
end

struct _BoundaryRelationshipFoldEvaluator end
@inline function (::_BoundaryRelationshipFoldEvaluator)(
        item::Int32, reads, parameters
    )
    return (
        event = LocalMath.FoldValue(
            something(@inbounds reads[1][1].value)
        ),
    )
end

struct _BoundaryRelationshipOrderKey{P} end
@inline function (::_BoundaryRelationshipOrderKey{P})(value) where {P}
    enabled = getfield(value, 5 + P)
    enabled || return (typemax(Int32), typemax(Int32), typemax(Int32))
    return (
        getfield(value, 1), getfield(value, 3),
        Int32(getfield(value, 4 + P)),
    )
end
struct _BoundaryRelationshipOrderIdentity{P} end
@inline (::_BoundaryRelationshipOrderIdentity{P})(value) where {P} =
    getfield(value, 4 + P)

@inline function _boundary_relationship_removal_position(
        state, schema, slot::Int32, endpoint::Int32, edge::Int32
    )
    degree = Int32(
        @inbounds state.degree[
            _checkerboard_fold_degree_index(schema, slot, endpoint),
        ]
    )
    for position in Int32(1):degree
        @inbounds(
            state.incident_edges[
                _checkerboard_fold_incident_index(
                    schema, slot, endpoint, position
                ),
            ]
        ) == edge &&
            return position, degree
    end
    return Int32(0), degree
end

Base.@noinline function _boundary_relationship_removal_write(
        state, schema, slot::Int32,
        a::Int32, position_a::Int32, degree_a::Int32,
        b::Int32, position_b::Int32, degree_b::Int32,
        lane::Int32
    )
    count_a = degree_a - position_a + Int32(1)
    if lane <= count_a
        position = position_a + lane - Int32(1)
        destination = _checkerboard_fold_incident_index(
            schema, slot, a, position
        )
        value = position < degree_a ? @inbounds(
                state.incident_edges[
                    _checkerboard_fold_incident_index(
                        schema, slot, a, position + Int32(1)
                    ),
                ]
            ) : Int32(0)
        return destination, value
    end
    local_lane = lane - count_a
    count_b = degree_b - position_b + Int32(1)
    if local_lane <= count_b
        position = position_b + local_lane - Int32(1)
        destination = _checkerboard_fold_incident_index(
            schema, slot, b, position
        )
        value = position < degree_b ? @inbounds(
                state.incident_edges[
                    _checkerboard_fold_incident_index(
                        schema, slot, b, position + Int32(1)
                    ),
                ]
            ) : Int32(0)
        return destination, value
    end
    return Int32(1), Int32(0)
end

struct _BoundaryRelationshipTransition{P, S}
    schema::S
end

@generated function (transition::_BoundaryRelationshipTransition{P})(
        state, value, item::Int32, reads
    ) where {P}
    payload_names = ntuple(index -> Symbol(:payload_, index), P)
    names = (
        :active, :endpoint_a, :endpoint_b,
        :generation_a, :generation_b, payload_names...,
        :degree, :incident_edges, :seen,
    )
    payload_updates = [
        :(
                LocalMath.BoundedWrites(
                    (destination_edge,),
                    (
                        code == Int32(2) ? getfield(value, $(3 + index)) :
                        zero(typeof(getfield(value, $(3 + index)))),
                    ),
                    payload_write_count
                )
            ) for index in 1:P
    ]
    incident_values = Symbol[]
    incident_initializers = Expr[]
    for lane in 1:_CHECKERBOARD_RELATIONSHIP_INCIDENT_WRITES
        name = Symbol(:removal_write_, lane)
        push!(incident_values, name)
        push!(
            incident_initializers, :(
                $name = remove ?
                    _boundary_relationship_removal_write(
                        state, schema, slot, a, position_a, degree_a,
                        b, position_b, degree_b, $(Int32(lane))
                    ) :
                    (Int32(1), Int32(0))
            )
        )
    end
    incident_keys = Expr(
        :tuple,
        [:(getfield($name, 1)) for name in incident_values]...
    )
    incident_replacements = Expr(
        :tuple,
        [:(getfield($name, 2)) for name in incident_values]...
    )
    updates = Expr(
        :tuple,
        :(
            LocalMath.BoundedWrites(
                (invalid ? Int32(0) : destination_edge,),
                (false,), (invalid || remove) ? Int32(1) : Int32(0)
            )
        ),
        :(
            LocalMath.BoundedWrites(
                (destination_edge,), (Int32(0),),
                remove ? Int32(1) : Int32(0)
            )
        ),
        :(
            LocalMath.BoundedWrites(
                (destination_edge,), (Int32(0),),
                remove ? Int32(1) : Int32(0)
            )
        ),
        :(
            LocalMath.BoundedWrites(
                (destination_edge,), (UInt32(0),),
                remove ? Int32(1) : Int32(0)
            )
        ),
        :(
            LocalMath.BoundedWrites(
                (destination_edge,), (UInt32(0),),
                remove ? Int32(1) : Int32(0)
            )
        ),
        payload_updates...,
        :(
            LocalMath.BoundedWrites(
                (
                    _checkerboard_fold_degree_index(schema, slot, a),
                    _checkerboard_fold_degree_index(schema, slot, b),
                ),
                (
                    Int16(degree_a - Int32(1)),
                    Int16(degree_b - Int32(1)),
                ),
                remove ? Int32(2) : Int32(0)
            )
        ),
        :(
            LocalMath.BoundedWrites(
                $incident_keys, $incident_replacements, incident_count
            )
        ),
        :(
            LocalMath.BoundedWrites(
                (destination_edge,), (value,),
                apply_request && !invalid ? Int32(1) : Int32(0)
            )
        )
    )
    payload_equal = isempty(payload_names) ? :(true) : foldl(
            (left, right) -> :($left && $right),
            [
                :(
                    getfield(value, $(3 + index)) ==
                    getfield(seen, $(3 + index))
                ) for index in 1:P
            ]
        )
    return quote
        local enabled = getfield(value, $(5 + P))
        local code = getfield(value, 1)
        local slot = getfield(value, 2)
        local edge = getfield(value, 3)
        local schema = transition.schema
        local flat_edge = _checkerboard_fold_edge_offset(schema, slot) +
            edge - Int32(1)
        local in_range = Int32(1) <= edge <=
            @inbounds(schema.edge_counts[slot])
        local destination_edge = in_range ? flat_edge : Int32(1)
        local active = in_range && @inbounds(state.active[flat_edge])
        local seen = in_range ? @inbounds(state.seen[flat_edge]) : value
        local already_seen = in_range && getfield(seen, $(5 + P))
        local equivalent = code == getfield(seen, 1) &&
            (code == Int32(1) || $payload_equal)
        local apply_request = enabled && !already_seen
        local remove = apply_request && code == Int32(1)
        local retune = apply_request && code == Int32(2)
        local payload_write_count = (remove || retune) ? Int32(1) : Int32(0)
        local a = active ? @inbounds(state.endpoint_a[flat_edge]) : Int32(1)
        local b = active ? @inbounds(state.endpoint_b[flat_edge]) : Int32(1)
        local position_a, degree_a = remove ?
            _boundary_relationship_removal_position(
                state, schema, slot, a, edge
            ) : (Int32(0), Int32(1))
        local position_b, degree_b = remove ?
            _boundary_relationship_removal_position(
                state, schema, slot, b, edge
            ) : (Int32(0), Int32(1))
        local invalid = enabled && (
            !(code == Int32(1) || code == Int32(2)) ||
                (already_seen && !equivalent) ||
                (!already_seen && !active) ||
                (remove && (position_a == 0 || position_b == 0))
        )
        invalid && (remove = false; retune = false; payload_write_count = Int32(0))
        $(incident_initializers...)
        local incident_count = remove ?
            degree_a - position_a + degree_b - position_b + Int32(2) :
            Int32(0)
        local updates = NamedTuple{$(QuoteNode(names))}($updates)
        return LocalMath.FoldStep(updates)
    end
end

function _stage_gate_snapshot(external, destination, label; parameters = ())
    space = external.space
    identity = LocalMath.IdentityRelation(space)
    return LocalMath.Stage(
        space,
        (gate = LocalMath.Access(external, identity; required = true),),
        (
            LocalMath.Publication(
                (
                    LocalMath.FieldPublication(
                        destination, identity, LocalMath.PublicationValue(:gate)
                    ),
                ),
                LocalMath.Unique(Bool)
            ),
        ),
        LocalMath.Evaluator(_CheckerboardAcceptedGateCopy(), parameters),
        LocalMath.Control(),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__; label),
    )
end

function _stage_descriptors(groups::Tuple)
    return Tuple(descriptor for group in groups for descriptor in group.instances)
end

function _stage_parameter_count(descriptor::CompiledStageDescriptor)
    handles = StateHandle[]
    count = Ref(0)
    _record_expression_requirements!(
        handles, count, descriptor.condition.expression
    )
    _record_expression_requirements!(handles, count, descriptor.value.expression)
    return count[]
end

function _stage_tracker_descriptors(descriptor, tracker_plan, source)
    keys = Any[]
    _record_tracker_requirements!(keys, descriptor.condition.expression; include_owner_counts = true)
    _record_tracker_requirements!(keys, descriptor.value.expression; include_owner_counts = true)
    isempty(keys) && return ()
    return _tracker_requirement_descriptors(keys, tracker_plan; source)
end

function _stage_submission_parameters(; minimum_mcs::Int64 = Int64(1))
    return (
        LocalMath.Parameter(:mcs, Int64; bounds = (minimum_mcs, typemax(Int64))),
        LocalMath.Parameter(:invocation, UInt32; bounds = (UInt32(0), typemax(UInt32))),
    )
end

_stage_selector_matches(
    ::BoundStateValueOperation{S}, selector::Type
) where {S} = S === selector || (S === ModelStageSite && selector === IterationStageSite)

function _compile_stage_expression(
        expression::Union{LiteralExpression, ParameterExpression, StateExpression},
        source, state_handles, selector, context_type
    )
    return _compile_proposal_expression(expression, source, state_handles)
end

function _compile_stage_expression(
        expression::ContextExpression, source, state_handles, selector, context_type
    )
    operation = expression.operation
    operation_context_supported(
        operation, context_type
    ) || throw(
        ArgumentError(
            "stage source $(repr(source)) requires unsupported contextual " *
                "operation $(repr(_contextual_operation_identity(operation)))"
        )
    )
    return _ExecutableProposalContext{
        _contextual_operation_identity(operation),
    }()
end

function _compile_stage_expression(
        expression::OperationExpression, source, state_handles, selector, context_type
    )
    operation = expression.operation
    arguments = ntuple(length(expression.arguments)) do index
        argument = getfield(expression.arguments, index)
        if operation isa ResourceOperation{:draw} && index == 1 &&
                argument isa LiteralExpression && argument.value isa Integer
            return _ExecutableDrawFamily{Int(argument.value)}()
        end
        _compile_stage_expression(argument, source, state_handles, selector, context_type)
    end
    if operation isa AbstractContextualOperation
        operation_context_supported(
            operation, context_type
        ) || throw(
            ArgumentError(
                "stage source $(repr(source)) requires unsupported contextual " *
                    "operation $(repr(_contextual_operation_identity(operation)))"
            )
        )
        if operation isa BoundStateValueOperation
            _stage_selector_matches(operation, selector) || throw(
                ArgumentError(
                    "stage source $(repr(source)) uses a bound-state selector " *
                        "incompatible with $(nameof(selector))"
                )
            )
            length(expression.arguments) == 1 &&
                only(expression.arguments) isa StateExpression || throw(
                ArgumentError(
                    "stage source $(repr(source)) requires bound-state access " *
                        "to contain exactly one declared state handle"
                )
            )
        end
        if operation isa BoundCellStateValueOperation
            length(expression.arguments) == 1 && only(expression.arguments) isa StateExpression ||
                throw(ArgumentError("cell-stage source $(repr(source)) requires exactly one declared state handle for bound-cell access"))
        end
        if operation isa QualifiedTrackerOperation
            quantity = only(typeof(operation.quantity).parameters)
            return _GatheredQualifiedTrackerCall{quantity, typeof(operation.operation), typeof(arguments)}(
                operation.operation, arguments, operation.source_handle
            )
        end
        return _ExecutableContextualCall(operation, arguments)
    end
    if operation === (^) && length(expression.arguments) == 2 &&
            expression.arguments[2] isa LiteralExpression &&
            expression.arguments[2].value isa Integer
        exponent = Int(expression.arguments[2].value)
        argument = first(arguments)
        return _ExecutableIntegerPower{exponent, typeof(argument)}(argument)
    end
    return _ExecutableScalarCall(operation, arguments)
end

function _compiled_stage_expressions(
        descriptor::CompiledStageDescriptor, handles::Tuple, source
    )
    selector = descriptor.effect isa ModelAssignmentEffect ?
        ModelStageSite : IterationStageSite
    context_type = descriptor.effect isa CellAssignmentEffect ? AbstractCellStageEvaluationContext : AbstractSiteStageEvaluationContext
    return (
        _compile_stage_expression(
            descriptor.condition.expression, source, handles, selector, context_type
        ),
        _compile_stage_expression(
            descriptor.value.expression, source, handles, selector, context_type
        ),
    )
end

function _stage_offsets(descriptor::CompiledStageDescriptor, dimensions::Int)
    footprint = descriptor.access.footprint
    footprint isa FiniteSpatialFootprint || throw(
        ArgumentError(
            "after-MCS site source $(descriptor.source_handle) requires a finite spatial footprint"
        )
    )
    footprint.anchor isa IterationSiteFootprintAnchor || throw(
        ArgumentError(
            "after-MCS site source $(descriptor.source_handle) requires an iteration-site footprint"
        )
    )
    offsets = Tuple(Tuple(Int.(offset)) for offset in footprint.offsets)
    all(offset -> length(offset) == dimensions, offsets) || throw(
        ArgumentError("after-MCS site footprint dimensionality is inconsistent")
    )
    ntuple(_ -> 0, dimensions) in offsets || throw(
        ArgumentError(
            "after-MCS site footprint must include its stage-entry center"
        )
    )
    return offsets
end

function _stage_contact_tables(resources::HamiltonianDomainResources, dimensions)
    offsets = iszero(size(resources.contact_offsets, 2)) ? () :
        _proposal_offsets_tuple(resources.contact_offsets, dimensions)
    return offsets, Tuple(resources.contact_starts), Tuple(resources.contact_counts)
end

function _stage_state_fields(space, handles::Tuple, ::Type{T}; layout = nothing, stage_plan = nothing) where {T}
    model = space isa LocalMath.Space{_CheckerboardStageModelDomain} ? space :
        LocalMath.Space(_CheckerboardStageModelDomain, 1)
    return map(handles) do handle
        domain = if layout === nothing
            space
        else
            entry = state_read_source(stage_plan, layout, handle)
            entry.schema.domain === :model ? model :
                entry.schema.domain === :site && space isa LocalMath.Space{_CheckerboardStageSiteDomain} ? space :
                entry.schema.domain === :cell && space isa LocalMath.Space{_CheckerboardStageCellDomain} ? space :
                throw(ArgumentError("assignment reads require state owned by the iteration domain or the model"))
        end
        shape = Tuple(Int.(handle_shape(handle)))
        shape_matches = domain isa LocalMath.Space{_CheckerboardStageModelDomain} ?
            prod(shape) == 1 : domain isa LocalMath.Space{_CheckerboardStageCellDomain} ?
            length(shape) == 1 && only(shape) >= prod(size(domain)) : shape == Tuple(size(domain))
        shape_matches || throw(
            ArgumentError("after-MCS state handle shape does not match its source domain")
        )
        LocalMath.Field(domain, _stage_handle_element_type(handle, T))
    end
end

function _stage_model_read_relation(domain, fields)
    domain isa LocalMath.Space{_CheckerboardStageModelDomain} && return nothing
    index = findfirst(field -> field.space isa LocalMath.Space{_CheckerboardStageModelDomain}, fields)
    return index === nothing ? nothing : LocalMath.FixedRelation(domain => fields[index].space; degree = 1)
end

function _stage_access_tuple(fields::Tuple, relation, model_relation = nothing)
    names = ntuple(index -> Symbol(:state_, index), length(fields))
    values = map(
        field -> LocalMath.Access(
            field, model_relation !== nothing && field.space isa LocalMath.Space{_CheckerboardStageModelDomain} ?
                model_relation : relation; required = false
        ), fields
    )
    return NamedTuple{names}(values)
end

function _identity_stage_state_storage(domain, handle, state)
    values = state_block(state.descriptor_state, handle).values
    # Rebind the same bank region to the execution domain. Model snapshots keep
    # their logical shape; excess allocated cell slots remain outside the view.
    return BlockView(values.storage, values.offset, Tuple(size(domain)))
end

function _stage_state_bindings(fields::Tuple, handles::Tuple, state)
    return map(fields, handles) do field, handle
        field => (
            field.space isa LocalMath.Space{<:Union{_CheckerboardStageModelDomain, _CheckerboardStageCellDomain}} ?
                _identity_stage_state_storage(field.space, handle, state) :
                state_block(state.descriptor_state, handle).values
        )
    end
end

function _compile_site_assignment_law(
        descriptor::CompiledStageDescriptor,
        source_table, shape, periodic, medium_kind,
        resources, ownership, cell_kinds, status, gate, state_layout, stage_plan,
        trajectory_key::NTuple{2, UInt64}, boundary::UInt16,
        ::Type{T}; publication_result = nothing
    ) where {T}
    handles = _stage_descriptor_handles(descriptor)
    target = first(handles)
    descriptor.effect.target == target || error("stage target ordering changed")
    source = _descriptor_source(
        source_table,
        descriptor.source_handle;
        descriptor,
        operation = descriptor.effect,
        role = descriptor.stage,
        context = :site_assignment_lowering,
    )
    condition, value = _compiled_stage_expressions(descriptor, handles, source)
    dimensions = length(shape)
    offsets = _stage_offsets(descriptor, dimensions)
    lattice = LocalMath.Space(_CheckerboardStageSiteDomain, Tuple(shape))
    cells = LocalMath.Space(_CheckerboardStageCellDomain, length(cell_kinds))
    status_space = LocalMath.Space(_CheckerboardStageStatusDomain, 1)
    fields = _stage_state_fields(lattice, handles, T; layout = state_layout, stage_plan)
    first(fields).space == lattice || throw(ArgumentError("site assignment target requires site-owned storage"))
    model_relation = _stage_model_read_relation(lattice, fields)
    identity = LocalMath.IdentityRelation(lattice)
    affine = LocalMath.AffineRelation(lattice => lattice; offsets)
    relation = LocalMath.BoundaryRelation(
        affine, LocalMath.PeriodicBoundary(Tuple(periodic))
    )
    ownership_field = LocalMath.Field(lattice, Int32)
    cell_kind_field = LocalMath.Field(cells, Int16)
    owner_relation = LocalMath.compose(
        relation,
        LocalMath.IndexRelation(ownership_field => cells; optional = true)
    )
    parameter_count = _stage_parameter_count(descriptor)
    parameter_field = iszero(parameter_count) ? nothing :
        LocalMath.Field(lattice, NTuple{parameter_count, T})
    scratch = LocalMath.Field(lattice, StageEvaluation{_stage_handle_element_type(target, T)})
    status_field = LocalMath.Field(status_space, ProgramStatus)
    initial_gate = LocalMath.Field(gate.space, Bool)
    refreshed_gate = LocalMath.Field(gate.space, Bool)
    status_fragments = _checkerboard_status_fragments(
        status_field, lattice, Int32(prod(shape))
    )
    contact_offsets, contact_starts, contact_counts =
        _stage_contact_tables(resources, dimensions)
    evaluator = _CompiledSiteStageEvaluator{
        !iszero(parameter_count), eltype(scratch), T, typeof(condition), typeof(value),
        typeof(handles), typeof(
            map(
                handle -> _state_value_zero(
                    _stage_handle_element_type(handle, T)
                ), handles
            )
        ),
        typeof(Tuple(shape)), typeof(Tuple(periodic)),
        typeof(contact_offsets), typeof(contact_starts),
    }(
        condition, value, handles,
        map(handle -> _state_value_zero(_stage_handle_element_type(handle, T)), handles),
        Tuple(shape), Tuple(periodic), Int16(medium_kind),
        contact_offsets, contact_starts, contact_counts,
        descriptor.source_handle, trajectory_key, boundary
    )
    core_reads = merge(
        _stage_access_tuple(fields, relation, model_relation), (
            ownership = LocalMath.Access(
                ownership_field, relation; required = false
            ),
            kinds = LocalMath.Access(
                cell_kind_field, owner_relation;
                required = false
            ),
        )
    )
    parameter_reads = parameter_field === nothing ? NamedTuple() : (
            parameters = LocalMath.Access(
                parameter_field, identity;
                required = true
            ),
        )
    reads = merge(core_reads, parameter_reads)
    submission_parameters = _stage_submission_parameters()
    evaluate = LocalMath.Stage(
        lattice, reads,
        (
            LocalMath.Publication(
                (
                    LocalMath.FieldPublication(
                        scratch, identity, LocalMath.PublicationValue(:value)
                    ),
                ),
                LocalMath.Unique(eltype(scratch))
            ),
            status_fragments.publication,
        ),
        LocalMath.Evaluator(evaluator, submission_parameters),
        LocalMath.Control(; gate = initial_gate),
        LocalMath.SourceOrigin(
            @__FILE__, @__LINE__;
            label = :corepotts_stage_site_evaluation
        ),
    )
    commit = LocalMath.Stage(
        lattice,
        (scratch = LocalMath.Access(scratch, identity; required = true),),
        (
            LocalMath.Publication(
                (
                    LocalMath.FieldPublication(
                        first(fields), identity, LocalMath.PublicationValue(:value)
                    ),
                ),
                LocalMath.Unique(eltype(first(fields)); coverage = LocalMath.PartialCoverage(), onempty = LocalMath.PreserveEmpty())
            ),
        ),
        LocalMath.Evaluator(_CompiledStageCommit(descriptor.effect)),
        LocalMath.Control(; gate = refreshed_gate),
        LocalMath.SourceOrigin(
            @__FILE__, @__LINE__;
            label = :corepotts_stage_site_publication
        ),
    )
    evaluation = LocalMath.sequence(
        LocalMath.LocalLaw(
            _stage_gate_snapshot(
                gate, initial_gate, :corepotts_stage_site_initial_gate
            )
        ),
        LocalMath.LocalLaw(evaluate)
    )
    publication = LocalMath.sequence(
        LocalMath.LocalLaw(
            _stage_gate_snapshot(
                gate, refreshed_gate, :corepotts_stage_site_refreshed_gate;
                parameters = submission_parameters,
            )
        ),
        LocalMath.LocalLaw(commit)
    )
    if publication_result !== nothing
        publication = LocalMath.sequence(
            publication, LocalMath.LocalLaw(
                _stage_site_publication_result(scratch, publication_result, refreshed_gate)
            )
        )
    end
    return (;
        evaluation, publication, fields, handles, parameter_field, scratch,
        ownership_field, cell_kind_field, status_field,
        initial_gate, refreshed_gate, model_relation,
    )
end

function _compile_identity_assignment_law(
        descriptor::CompiledStageDescriptor,
        source_table, domain, gate, state_layout, stage_plan, tracker_plan, tracker_state,
        trajectory_key::NTuple{2, UInt64}, boundary::UInt16, ::Type{T}
    ) where {T}
    handles = _stage_descriptor_handles(descriptor)
    target = first(handles)
    source = _descriptor_source(
        source_table,
        descriptor.source_handle;
        descriptor,
        operation = descriptor.effect,
        role = descriptor.stage,
        context = :identity_assignment_lowering,
    )
    condition, value = _compiled_stage_expressions(descriptor, handles, source)
    status_space = LocalMath.Space(_CheckerboardStageStatusDomain, 1)
    fields = _stage_state_fields(domain, handles, T; layout = state_layout, stage_plan)
    first(fields).space == domain || throw(ArgumentError("identity assignment target does not match its declared domain"))
    model_relation = _stage_model_read_relation(domain, fields)
    identity = LocalMath.IdentityRelation(domain)
    parameter_count = _stage_parameter_count(descriptor)
    parameter_field = iszero(parameter_count) ? nothing :
        LocalMath.Field(domain, NTuple{parameter_count, T})
    scratch = LocalMath.Field(domain, StageEvaluation{_stage_handle_element_type(target, T)})
    status_field = LocalMath.Field(status_space, ProgramStatus)
    initial_gate = LocalMath.Field(gate.space, Bool)
    refreshed_gate = LocalMath.Field(gate.space, Bool)
    status_fragments = _checkerboard_status_fragments(
        status_field, domain, Int32(prod(size(domain)))
    )
    zeros = map(handle -> _state_value_zero(_stage_handle_element_type(handle, T)), handles)
    tracker_descriptors = _stage_tracker_descriptors(descriptor, tracker_plan, source)
    tracker_keys = map(tracker -> _compile_tracker_key(tracker_quantity(tracker)), tracker_descriptors)
    tracker_fields = map(tracker_descriptors) do tracker
        LocalMath.Field(domain, eltype(tracker_values(tracker_plan, tracker_state, tracker_quantity(tracker))))
    end
    evaluator = if descriptor.effect isa ModelAssignmentEffect
        _CompiledModelStageEvaluator{
            !iszero(parameter_count), eltype(scratch), T, typeof(condition), typeof(value),
            typeof(handles), typeof(zeros),
        }(
            condition, value, handles,
            zeros,
            descriptor.source_handle, trajectory_key, boundary
        )
    else
        _CompiledCellStageEvaluator{!iszero(parameter_count), eltype(scratch), T, typeof(condition), typeof(value), typeof(handles), typeof(zeros), typeof(descriptor.effect), typeof(tracker_keys)}(
            condition, value, handles, zeros, descriptor.source_handle, descriptor.effect,
            trajectory_key, boundary, tracker_keys,
        )
    end
    cell_kind_field = descriptor.effect isa CellAssignmentEffect ? LocalMath.Field(domain, Int16) : nothing
    cell_generation_field = descriptor.effect isa CellAssignmentEffect ? LocalMath.Field(domain, UInt32) : nothing
    identity_reads = cell_kind_field === nothing ? NamedTuple() : (
            kind = LocalMath.Access(cell_kind_field, identity; required = true),
            generation = LocalMath.Access(cell_generation_field, identity; required = true),
        )
    parameter_reads = parameter_field === nothing ? NamedTuple() : (
            parameters = LocalMath.Access(
                parameter_field, identity;
                required = true
            ),
        )
    tracker_reads = NamedTuple{ntuple(index -> Symbol(:tracker_, index), length(tracker_fields))}(
        map(field -> LocalMath.Access(field, identity; required = true), tracker_fields)
    )
    reads = merge(_stage_access_tuple(fields, identity, model_relation), identity_reads, parameter_reads, tracker_reads)
    submission_parameters = _stage_submission_parameters()
    evaluate = LocalMath.Stage(
        domain, reads,
        (
            LocalMath.Publication(
                (
                    LocalMath.FieldPublication(
                        scratch, identity, LocalMath.PublicationValue(:value)
                    ),
                ),
                LocalMath.Unique(eltype(scratch))
            ),
            status_fragments.publication,
        ),
        LocalMath.Evaluator(evaluator, submission_parameters),
        LocalMath.Control(; gate = initial_gate),
        LocalMath.SourceOrigin(
            @__FILE__, @__LINE__;
            label = :corepotts_stage_identity_evaluation
        ),
    )
    commit = LocalMath.Stage(
        domain,
        (scratch = LocalMath.Access(scratch, identity; required = true),),
        (
            LocalMath.Publication(
                (
                    LocalMath.FieldPublication(
                        first(fields), identity, LocalMath.PublicationValue(:value)
                    ),
                ),
                LocalMath.Unique(
                    eltype(first(fields)); coverage = LocalMath.PartialCoverage(),
                    onempty = LocalMath.PreserveEmpty(),
                )
            ),
        ),
        LocalMath.Evaluator(_CompiledStageCommit(descriptor.effect)),
        LocalMath.Control(; gate = refreshed_gate),
        LocalMath.SourceOrigin(
            @__FILE__, @__LINE__;
            label = :corepotts_stage_identity_publication
        ),
    )
    evaluation = LocalMath.sequence(
        LocalMath.LocalLaw(
            _stage_gate_snapshot(
                gate, initial_gate, :corepotts_stage_identity_initial_gate
            )
        ),
        LocalMath.LocalLaw(evaluate)
    )
    publication = LocalMath.sequence(
        LocalMath.LocalLaw(
            _stage_gate_snapshot(
                gate, refreshed_gate, :corepotts_stage_identity_refreshed_gate;
                parameters = submission_parameters,
            )
        ),
        LocalMath.LocalLaw(commit)
    )
    return (;
        domain, evaluation, publication, fields, handles, parameter_field, scratch, status_field,
        cell_kind_field, cell_generation_field, model_relation, tracker_descriptors, tracker_fields,
        initial_gate, refreshed_gate,
    )
end

struct _CompiledHistoryShiftAppend{RecordPublication}
    cadence::CompletedMCSCadence
    cadence_value::Int64
end

@inline function (operation::_CompiledHistoryShiftAppend{RecordPublication})(
        item::Int32, reads, parameters
    ) where {RecordPublication}
    shifted = @inbounds reads[1][1]
    appended = @inbounds reads[2][1]
    value = shifted.present ? something(shifted.value) :
        something(appended.value)
    completed_mcs = getfield(parameters, 1)
    published = _completed_mcs_due(operation.cadence, operation.cadence_value, completed_mcs) &&
        !(completed_mcs == 0 && shifted.present)
    if !published
        value = something(@inbounds reads[3][1].value)
    end
    result = (value = LocalMath.UniqueValue(value),)
    return RecordPublication ? merge(result, (published = LocalMath.RoutedContribution(Int32(1), published, true),)) : result
end

function _history_append_endpoints(
        target_shape::NTuple{N, Int}, source_shape::NTuple{M, Int}, axis::Int
    ) where {N, M}
    N == M + 1 || throw(
        ArgumentError(
            "history target must have exactly one additional dimension"
        )
    )
    target_indices = CartesianIndices(target_shape)
    source_linear = LinearIndices(source_shape)
    depth = target_shape[axis]
    endpoints = ones(Int32, 1, length(target_indices))
    counts = zeros(Int32, length(target_indices))
    for target in target_indices
        target[axis] == depth || continue
        source = CartesianIndex(
            ntuple(Val(M)) do output_axis
                input_axis = output_axis < axis ? output_axis : output_axis + 1
                target[input_axis]
            end
        )
        endpoints[1, LinearIndices(target_shape)[target]] =
            Int32(source_linear[source])
        counts[LinearIndices(target_shape)[target]] = Int32(1)
    end
    return (; endpoints, counts)
end

function _compile_history_law(
        descriptor::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        }, gate, ::Type{T}; publication_result = nothing
    ) where {C, V, E <: ShiftAppendEffect, T}
    effect = descriptor.effect
    target_shape = Tuple(Int.(handle_shape(effect.target)))
    source_shape = _history_source_shape(effect.source)
    axis = Int(effect.axis)
    1 <= axis <= length(target_shape) || throw(
        ArgumentError(
            "history shift axis is outside the target dimensions"
        )
    )
    target_shape[1:(axis - 1)] == source_shape &&
        target_shape[(axis + 1):end] == () || throw(
        ArgumentError(
            "history source and target shapes are incompatible"
        )
    )
    target_space = LocalMath.Space(_CheckerboardHistoryDomain, target_shape)
    source_space = LocalMath.Space(
        _CheckerboardHistorySourceDomain, source_shape
    )
    target = LocalMath.Field(
        target_space, _stage_handle_element_type(effect.target, T)
    )
    source = LocalMath.Field(
        source_space, _stage_handle_element_type(effect.source, T)
    )
    identity = LocalMath.IdentityRelation(target_space)
    shift_offset = ntuple(
        index -> index == axis ? 1 : 0,
        length(target_shape)
    )
    shifted = LocalMath.BoundaryRelation(
        LocalMath.AffineRelation(
            target_space => target_space;
            offsets = (shift_offset,)
        ),
        LocalMath.ExteriorBoundary()
    )
    appended = LocalMath.FixedRelation(
        target_space => source_space; degree = 1
    )
    initial_gate = LocalMath.Field(gate.space, Bool)
    stage = LocalMath.Stage(
        target_space,
        (
            shifted = LocalMath.Access(target, shifted; required = false),
            appended = LocalMath.Access(source, appended; required = false),
            current = LocalMath.Access(target, identity),
        ),
        (
            LocalMath.Publication(
                (
                    LocalMath.FieldPublication(
                        target, identity, LocalMath.PublicationValue(:value)
                    ),
                ),
                LocalMath.Unique(eltype(target))
            ),
            (publication_result === nothing ? () : (_stage_publication_result_output(target_space, publication_result),))...,
        ),
        LocalMath.Evaluator(
            _CompiledHistoryShiftAppend{publication_result !== nothing}(effect.cadence, effect.cadence_value),
            _stage_submission_parameters(; minimum_mcs = Int64(0))
        ),
        LocalMath.Control(; gate = initial_gate),
        LocalMath.SourceOrigin(
            @__FILE__, @__LINE__;
            label = :corepotts_history_shift_append
        ),
    )
    law = LocalMath.sequence(
        LocalMath.LocalLaw(
            _stage_gate_snapshot(
                gate, initial_gate, :corepotts_history_initial_gate
            )
        ),
        LocalMath.LocalLaw(stage)
    )
    endpoints = _history_append_endpoints(
        target_shape, source_shape, axis
    )
    return (; law, target, source, effect, appended, endpoints, initial_gate)
end

_relationship_contextual_operation_supported(
    ::Union{
        ResourceOperation{:endpoint_a},
        ResourceOperation{:endpoint_b},
        ResourceOperation{:edge_payload},
        ResourceOperation{:cell_volume},
        ResourceOperation{:unwrapped_center},
        ResourceOperation{:cell_center},
        ResourceOperation{:distance},
        ResourceOperation{:field_value},
    }
) = true
_relationship_contextual_operation_supported(::ContextOperation) = true
_relationship_contextual_operation_supported(::AbstractContextualOperation) =
    false

_compile_relationship_expression(
    expression::Union{
        LiteralExpression, ParameterExpression, ContextExpression, StateExpression,
    },
    source, handles
) = _compile_proposal_expression(expression, source, handles)

function _compile_relationship_expression(
        expression::OperationExpression, source, handles
    )
    arguments = map(expression.arguments) do argument
        _compile_relationship_expression(argument, source, handles)
    end
    operation = expression.operation
    if operation isa AbstractContextualOperation
        _relationship_contextual_operation_supported(operation) || throw(
            ArgumentError(
                "relationship source $(repr(source)) requires unsupported " *
                    "bounded operation " *
                    "$(repr(_contextual_operation_identity(operation)))"
            )
        )
        return _ExecutableContextualCall(operation, arguments)
    end
    return _ExecutableScalarCall(operation, arguments)
end

function _relationship_stage_terms(
        descriptors::Tuple, source_table, layout, ::Type{T}
    ) where {T}
    handles = StateHandle[]
    parameter_count = Ref(0)
    for descriptor in descriptors
        _record_expression_requirements!(
            handles, parameter_count, descriptor.condition.expression
        )
        effect = descriptor.effect
        effect isa RelationshipRetuneEffect && foreach(effect.payload) do value
            _record_expression_requirements!(
                handles, parameter_count, value.expression
            )
        end
    end
    handle_tuple = Tuple(handles)
    terms = map(descriptors) do descriptor
        effect = descriptor.effect
        location = getfield(layout.slots, Int(effect.relationship_slot))
        bank = getfield(layout.banks, Int(location.bank))
        source = _descriptor_source(
            source_table,
            descriptor.source_handle;
            descriptor,
            operation = descriptor.effect,
            role = descriptor.stage,
            context = :relationship_stage_lowering,
        )
        payload_zero = ntuple(_ -> zero(T), Int(bank.payload_count))
        payload_evaluators = if effect isa RelationshipRetuneEffect
            length(effect.payload) == length(payload_zero) || throw(
                ArgumentError("relationship retune payload schema mismatch")
            )
            map(effect.payload) do evaluator
                _compile_relationship_expression(
                    evaluator.expression, source, handle_tuple
                )
            end
        else
            map(payload_zero) do value
                _compile_relationship_expression(
                    LiteralExpression(value), source, handle_tuple
                )
            end
        end
        return (;
            bank = location.bank,
            term = _BoundaryRelationshipTerm(
                _compile_relationship_expression(
                    descriptor.condition.expression, source, handle_tuple
                ),
                payload_evaluators, payload_zero,
                effect isa RelationshipRemoveEffect ? Int32(1) : Int32(2),
                location.slot,
                getfield(bank.edge_counts, Int(location.slot)),
                descriptor.source_handle
            ),
        )
    end
    return (;
        terms, handles = handle_tuple,
        parameter_count = parameter_count[],
    )
end

function _relationship_request_endpoints(terms, layout)
    request_count = sum(term.edge_count for term in terms; init = Int32(0))
    endpoints = Matrix{Int32}(undef, 1, Int(request_count))
    position = 0
    for term in terms
        offset = Int(getfield(layout.edge_offsets, Int(term.bank_slot)))
        for edge in 1:Int(term.edge_count)
            position += 1
            @inbounds endpoints[1, position] = Int32(offset + edge - 1)
        end
    end
    return endpoints
end

function _compile_relationship_stage_group(
        descriptors::Tuple, source_table, program, relationships,
        owner_capacity::Integer, gate, ::Type{T}
    ) where {T}
    inventory = _relationship_stage_terms(
        descriptors, source_table, program.relationship_layout, T
    )
    groups = map(unique(record.bank for record in inventory.terms)) do bank_index
        records = Tuple(
            record for record in inventory.terms
                if record.bank == bank_index
        )
        terms = map(record -> record.term, records)
        bank = relationships.banks[Int(bank_index)]
        bank_layout = getfield(
            program.relationship_layout.banks,
            Int(bank_index)
        )
        payload_zero = first(terms).payload_zero
        all(
            term -> map(typeof, term.payload_zero) ==
                map(typeof, payload_zero), terms
        ) || throw(
            ArgumentError(
                "relationship stages sharing a packed bank disagree on payload schema"
            )
        )
        request_endpoints = _relationship_request_endpoints(
            terms, bank_layout
        )
        request_count = size(request_endpoints, 2)
        request_space = LocalMath.Space(
            _CheckerboardRelationshipRequestDomain, request_count
        )
        lattice = LocalMath.Space(
            _CheckerboardStageSiteDomain, Tuple(program.shape)
        )
        cells = LocalMath.Space(
            _CheckerboardRelationshipCellDomain, owner_capacity
        )
        status_space = LocalMath.Space(_CheckerboardStageStatusDomain, 1)
        request_identity = LocalMath.IdentityRelation(request_space)
        # Packed relationship storage has several physical extents: edge
        # columns, owner degrees, and incident-edge slots.  Use the canonical
        # length-grouped field schema rather than pretending every component
        # has the edge extent.
        live_fields = _checkerboard_relationship_state_fields(bank)
        shadow_fields = NamedTuple{keys(live_fields)}(
            map(values(live_fields)) do field
                LocalMath.Field(field.space, eltype(field))
            end
        )
        flat_edge_space = live_fields.active.space
        request_edge = LocalMath.FixedRelation(
            request_space => flat_edge_space; degree = 1
        )
        endpoints = LocalMath.Field(request_space, Tuple{Int32, Int32})
        endpoint_relation = LocalMath.IndexRelation(
            endpoints => lattice; optional = true
        )
        owner_relation = LocalMath.IndexRelation(
            endpoints => cells; optional = true
        )
        state_fields = _stage_state_fields(
            lattice, inventory.handles, T
        )
        volume = LocalMath.Field(cells, Int32)
        moments = LocalMath.Field(cells, NTuple{length(program.shape), T})
        parameter_width = max(inventory.parameter_count, 1)
        parameter_field = LocalMath.Field(
            request_space, NTuple{parameter_width, T}
        )
        event_type = Tuple{
            Int32, Int32, Int32, map(typeof, payload_zero)..., UInt32, Bool,
        }
        seen_initial = (
            Int32(0), Int32(0), Int32(0), payload_zero..., UInt32(0), false,
        )
        event = LocalMath.Field(request_space, event_type)
        status_field = LocalMath.Field(status_space, ProgramStatus)
        initial_gate = LocalMath.Field(gate.space, Bool)
        refreshed_gate = LocalMath.Field(gate.space, Bool)
        endpoint_stage = LocalMath.Stage(
            request_space,
            (
                endpoint_a = LocalMath.Access(
                    live_fields.endpoint_a, request_edge; required = true
                ),
                endpoint_b = LocalMath.Access(
                    live_fields.endpoint_b, request_edge; required = true
                ),
            ),
            (
                LocalMath.Publication(
                    (
                        LocalMath.FieldPublication(
                            endpoints, request_identity,
                            LocalMath.PublicationValue(:endpoints)
                        ),
                    ),
                    LocalMath.Unique(Tuple{Int32, Int32})
                ),
            ),
            LocalMath.Evaluator(_BoundaryRelationshipEndpointEvaluator()),
            LocalMath.Control(; gate = initial_gate),
            LocalMath.SourceOrigin(
                @__FILE__, @__LINE__;
                label = :corepotts_relationship_keys
            ),
        )
        read_names = Symbol[:active, :endpoints]
        read_values = Any[
            LocalMath.Access(
                live_fields.active, request_edge; required = true
            ),
            LocalMath.Access(endpoints, request_identity; required = true),
        ]
        for index in eachindex(payload_zero)
            push!(read_names, Symbol(:payload_, index))
            push!(
                read_values, LocalMath.Access(
                    getfield(live_fields, 5 + index), request_edge;
                    required = true
                )
            )
        end
        for (index, field) in enumerate(state_fields)
            push!(read_names, Symbol(:state_, index))
            push!(
                read_values, LocalMath.Access(
                    field, endpoint_relation; required = false
                )
            )
        end
        append!(read_names, (:volumes, :moments, :parameters))
        append!(
            read_values, (
                LocalMath.Access(volume, owner_relation; required = false),
                LocalMath.Access(moments, owner_relation; required = false),
                LocalMath.Access(
                    parameter_field, request_identity; required = true
                ),
            )
        )
        reads = NamedTuple{Tuple(read_names)}(Tuple(read_values))
        stops = accumulate(+, map(term -> term.edge_count, terms))
        zeros = map(
            handle -> _state_value_zero(
                _stage_handle_element_type(handle, T)
            ), inventory.handles
        )
        evaluator = _BoundaryRelationshipRequestEvaluator{
            length(payload_zero), typeof(terms), typeof(inventory.handles),
            typeof(zeros), T, typeof(stops),
        }(
            terms, inventory.handles, zeros, zero(T), stops
        )
        status_fragments = _checkerboard_status_fragments(
            status_field, request_space, Int32(request_count)
        )
        submission_parameters = _stage_submission_parameters()
        evaluate = LocalMath.Stage(
            request_space, reads,
            (
                LocalMath.Publication(
                    (
                        LocalMath.FieldPublication(
                            event, request_identity,
                            LocalMath.PublicationValue(:event)
                        ),
                    ),
                    LocalMath.Unique(event_type)
                ),
                status_fragments.publication,
            ),
            LocalMath.Evaluator(evaluator, submission_parameters),
            LocalMath.Control(; gate = initial_gate),
            LocalMath.SourceOrigin(
                @__FILE__, @__LINE__;
                label = :corepotts_relationship_requests
            ),
        )
        seen = LocalMath.Field(flat_edge_space, event_type)
        seen_source = LocalMath.Field(flat_edge_space, event_type)
        fold_state_fields = merge(shadow_fields, (; seen))
        fold_state = LocalMath.InitializedState(;
            map(
                (shadow, live) -> LocalMath.FoldComponent(shadow; from = live),
                shadow_fields, live_fields
            )...,
            seen = LocalMath.FoldComponent(seen; from = seen_source),
        )
        transition = _BoundaryRelationshipTransition{
            length(payload_zero),
            typeof(_checkerboard_immutable_relationship_schema(bank)),
        }(
            _checkerboard_immutable_relationship_schema(bank)
        )
        fold = LocalMath.OrderedFold(
            event_type, fold_state, transition;
            order = LocalMath.canonical_by(
                _BoundaryRelationshipOrderKey{length(payload_zero)}(),
                _BoundaryRelationshipOrderIdentity{
                    length(payload_zero),
                }()
            )
        )
        settle = LocalMath.Stage(
            request_space,
            (
                event = LocalMath.Access(
                    event, request_identity; required = true
                ),
            ),
            (
                LocalMath.Publication(
                    (
                        LocalMath.FoldPublication(
                            LocalMath.PublicationValue(:event)
                        ),
                    ), fold
                ),
            ),
            LocalMath.Evaluator(_BoundaryRelationshipFoldEvaluator()),
            LocalMath.Control(; gate = refreshed_gate),
            LocalMath.SourceOrigin(
                @__FILE__, @__LINE__;
                label = :corepotts_relationship_settlement
            ),
        )
        law = LocalMath.sequence(
            LocalMath.LocalLaw(
                _stage_gate_snapshot(
                    gate, initial_gate,
                    :corepotts_relationship_initial_gate
                )
            ),
            LocalMath.LocalLaw(endpoint_stage),
            LocalMath.LocalLaw(evaluate),
            LocalMath.LocalLaw(
                _stage_gate_snapshot(
                    gate, refreshed_gate,
                    :corepotts_relationship_refreshed_gate
                )
            ),
            LocalMath.LocalLaw(settle)
        )
        return (;
            law, submission_parameters, bank_index, live_fields, shadow_fields,
            fold_state_fields,
            seen, seen_source, seen_initial,
            state_fields, handles = inventory.handles, volume, moments,
            parameter_field, parameter_count = inventory.parameter_count,
            event, endpoints, request_edge, request_endpoints,
            status_field, initial_gate, refreshed_gate,
            external_gate = gate,
        )
    end
    return Tuple(groups)
end

@inline _stage_submission_count(descriptor::CompiledStageDescriptor) =
    descriptor.effect isa IteratedSiteAssignmentEffect ?
    Int(descriptor.effect.iterations) : 1

function _stage_model_read_bindings(relation, bank, shape)
    relation === nothing && return ()
    endpoints = _checkerboard_similar(bank.parameters, Int32, 1, prod(shape))
    fill!(endpoints, Int32(1))
    return (relation => endpoints,)
end

function _site_stage_bindings(
        declaration, bank, gate
    )
    bindings = (
        _stage_model_read_bindings(declaration.model_relation, bank, bank.program.shape)...,
        _stage_state_bindings(
            declaration.fields, declaration.handles, bank
        )...,
        declaration.ownership_field => bank.ownership,
        declaration.cell_kind_field => bank.cell_kinds,
        _checkerboard_parameter_binding(
            declaration.parameter_field, bank,
            bank.program.shape
        )...,
        declaration.scratch => LocalMath.Allocate(
            _checkerboard_storage_zero(declaration.scratch)
        ),
        declaration.status_field => bank.program_status,
        declaration.initial_gate => LocalMath.Allocate(false),
        declaration.external_gate => gate,
    )
    return bindings
end

function _identity_stage_bindings(
        declaration, bank, gate
    )
    bindings = (
        _stage_model_read_bindings(declaration.model_relation, bank, size(declaration.domain))...,
        _stage_state_bindings(declaration.fields, declaration.handles, bank)...,
        map(declaration.tracker_fields, declaration.tracker_descriptors) do field, tracker
            field => tracker_values(bank.program.tracker_plan, bank.trackers, tracker_quantity(tracker))
        end...,
        (
            declaration.cell_kind_field === nothing ? () : (
                    declaration.cell_kind_field => bank.cell_kinds,
                    declaration.cell_generation_field => bank.cell_generations,
                )
        )...,
        _checkerboard_parameter_binding(
            declaration.parameter_field, bank, Tuple(size(declaration.domain))
        )...,
        declaration.scratch => LocalMath.Allocate(
            _checkerboard_storage_zero(declaration.scratch)
        ),
        declaration.status_field => bank.program_status,
        declaration.initial_gate => LocalMath.Allocate(false),
        declaration.external_gate => gate,
    )
    return bindings
end

function _prepare_assignment_publication(
        declaration, evaluation, bank, gate, backend, lease_capacity, effect;
        publication_bindings = ()
    )
    # The evaluation owns scratch. Publication binds that exact storage, so
    # the queue dependency carries the evaluated value without another copy.
    target_storage = effect isa Union{ModelAssignmentEffect, CellAssignmentEffect} ?
        _identity_stage_state_storage(declaration.domain, first(declaration.handles), bank) :
        state_block(bank.descriptor_state, first(declaration.handles)).values
    bindings = (
        first(declaration.fields) => target_storage,
        declaration.scratch => LocalMath.storage(evaluation, declaration.scratch),
        declaration.refreshed_gate => LocalMath.Allocate(false),
        declaration.external_gate => gate,
    )
    return LocalMath.prepare(
        declaration.publication,
        bindings..., publication_bindings...;
        backend, lease_capacity, dependency_arity = 1
    )
end

function _prepare_history_stage_declaration(
        declaration, bank, gate, backend, lease_capacity; publication_bindings = ()
    )
    bindings = (
        declaration.target => state_block(
            bank.descriptor_state, declaration.effect.target
        ).values,
        declaration.source => _identity_stage_state_storage(
            declaration.source.space, declaration.effect.source, bank
        ),
        declaration.appended => LocalMath.Allocate(declaration.endpoints),
        declaration.initial_gate => LocalMath.Allocate(false),
        declaration.external_gate => gate,
    )
    return LocalMath.prepare(
        declaration.law, bindings..., publication_bindings...;
        backend, lease_capacity, dependency_arity = 1
    )
end

function _relationship_stage_bindings(declaration, bank)
    packed_bank = bank.relationships.banks[Int(declaration.bank_index)]
    science = _packed_relationship_science(packed_bank)
    live_bindings = map(
        values(declaration.live_fields), values(science)
    ) do field, storage
        field => storage
    end
    shadow_bindings = map(values(declaration.shadow_fields)) do field
        field => LocalMath.Allocate(_checkerboard_storage_zero(field))
    end
    state_bindings = _stage_state_bindings(
        declaration.state_fields, declaration.handles, bank
    )
    volumes = tracker_values(
        bank.program.tracker_plan, bank.trackers, Val(:cell_volume)
    )
    moment_binding = try
        moment_state = tracker_values(
            bank.program.tracker_plan, bank.trackers, Val(:cell_moments)
        )
        declaration.moments =>
            _checkerboard_moment_tuple_view(moment_state.first)
    catch error
        error isa InterruptException && rethrow()
        declaration.moments => LocalMath.Allocate(
            _checkerboard_storage_zero(declaration.moments)
        )
    end
    parameter_binding = declaration.parameter_count == 0 ?
        (
            declaration.parameter_field => LocalMath.Allocate(
                _checkerboard_storage_zero(declaration.parameter_field)
            ),
        ) :
        _checkerboard_parameter_binding(
            declaration.parameter_field, bank,
            (length(declaration.request_endpoints),)
        )
    bindings = (
        live_bindings...,
        shadow_bindings...,
        declaration.seen => LocalMath.Allocate(declaration.seen_initial),
        declaration.seen_source => LocalMath.Allocate(declaration.seen_initial),
        state_bindings...,
        declaration.volume => volumes,
        moment_binding,
        parameter_binding...,
        declaration.event => LocalMath.Allocate(
            _checkerboard_storage_zero(declaration.event)
        ),
        declaration.endpoints => LocalMath.Allocate((Int32(0), Int32(0))),
        declaration.request_edge =>
            LocalMath.Allocate(declaration.request_endpoints),
        declaration.status_field => bank.program_status,
        declaration.initial_gate => LocalMath.Allocate(false),
        declaration.refreshed_gate => LocalMath.Allocate(false),
    )
    return bindings
end

function _prepare_relationship_stage_publication(
        declaration, evaluation, bank, gate, backend, lease_capacity
    )
    external_gate = declaration.external_gate
    commit_gate = LocalMath.Field(external_gate.space, Bool)
    commit_gate_law = LocalMath.LocalLaw(
        _stage_gate_snapshot(
            external_gate, commit_gate, :corepotts_relationship_commit_gate;
            parameters = declaration.submission_parameters,
        )
    )
    commit_laws = Tuple(
        _checkerboard_field_copy_law(
                shadow, live, commit_gate,
                Symbol(:corepotts_relationship_commit_, declaration.bank_index, :_, name)
            )
            for (name, shadow, live) in zip(
                keys(declaration.shadow_fields),
                values(declaration.shadow_fields), values(declaration.live_fields)
            )
    )
    fields = (values(declaration.shadow_fields)..., values(declaration.live_fields)...)
    bindings = map(field -> field => LocalMath.storage(evaluation, field), fields)
    publication = LocalMath.sequence(commit_gate_law, commit_laws...)
    return LocalMath.prepare(
        publication, bindings...,
        external_gate => gate, commit_gate => LocalMath.Allocate(false);
        backend, lease_capacity, dependency_arity = 1
    )
end

function _stage_boundary_entry(prepared, source_handle, effect; repetitions = 1)
    typeof(prepared[1]) === typeof(prepared[2]) || throw(
        ArgumentError("checkerboard stage banks produced different PreparedPlan types")
    )
    return (; prepared, repetitions, source_handle, effect)
end

struct _StagePublicationReset end
@inline (::_StagePublicationReset)(item::Int32, reads, parameters) =
    (value = LocalMath.UniqueValue(false),)

struct _StageSitePublicationResult end
@inline function (::_StageSitePublicationResult)(item::Int32, reads, parameters)
    evaluation = something(@inbounds reads[1][1].value)
    return (published = LocalMath.RoutedContribution(Int32(1), evaluation.enabled, true),)
end

@inline _stage_publication_or(left::Bool, right::Bool) = left | right
function _stage_publication_result_output(domain, output)
    route = LocalMath.RuntimeRelation(domain => output.space; degree_bound = 1, key_type = Int32)
    return LocalMath.Publication(
        (LocalMath.FieldPublication(output, route, LocalMath.PublicationValue(:published)),),
        LocalMath.Reduce(
            Bool, _stage_publication_or; maximum = 1,
            seed = LocalMath.ExistingSeed(), order = LocalMath.CanonicalLeftFold()
        )
    )
end

function _stage_site_publication_result(scratch, output, gate)
    domain = scratch.space
    return LocalMath.Stage(
        domain,
        (evaluation = LocalMath.Access(scratch, LocalMath.IdentityRelation(domain)),),
        (_stage_publication_result_output(domain, output),),
        LocalMath.Evaluator(_StageSitePublicationResult()), LocalMath.Control(; gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__; label = :stage_source_publication)
    )
end

function _prepare_stage_publication_result(descriptor, backend, lease_capacity)
    output = LocalMath.Field(LocalMath.Space(_CheckerboardStageGateDomain, 1), Bool)
    identity = LocalMath.IdentityRelation(output.space)
    stage = LocalMath.Stage(
        output.space, NamedTuple(),
        (
            LocalMath.Publication(
                (LocalMath.FieldPublication(output, identity, LocalMath.PublicationValue(:value)),),
                LocalMath.Unique(Bool)
            ),
        ),
        LocalMath.Evaluator(_StagePublicationReset(), _stage_submission_parameters()),
        LocalMath.Control(), LocalMath.SourceOrigin(@__FILE__, @__LINE__; label = :stage_source_publication_reset)
    )
    prepared = ntuple(2) do _
        LocalMath.prepare(
            LocalMath.LocalLaw(stage), output => LocalMath.Allocate(false);
            backend, lease_capacity, dependency_arity = 1
        )
    end
    return (; descriptor, output, prepared)
end

_stage_publication_bindings(::Nothing, bank_index) = ()
_stage_publication_bindings(result, bank_index) =
    (result.output => LocalMath.storage(result.prepared[bank_index], result.output),)

struct _StageSourceRefreshGate end
@inline _any_stage_publication(::Tuple{}) = false
@inline _any_stage_publication(reads::Tuple) =
    something(@inbounds first(reads)[1].value) | _any_stage_publication(Base.tail(reads))
@inline function (::_StageSourceRefreshGate)(item::Int32, reads, parameters)
    open = something(@inbounds reads[1][1].value)
    return (value = LocalMath.UniqueValue(open && _any_stage_publication(Base.tail(reads))),)
end

function _prepare_stage_source_refresh(descriptor, results, banks, gates, backend, lease_capacity)
    domain = first(results).output.space
    external = LocalMath.Field(domain, Bool)
    gate = LocalMath.Field(domain, Bool)
    identity = LocalMath.IdentityRelation(domain)
    result_fields = map(result -> result.output, results)
    # Each publication owns a distinct singleton space, even when two
    # descriptors publish the same source. Relate those identities explicitly.
    result_relations = map(field -> LocalMath.FixedRelation(domain => field.space; degree = 1), result_fields)
    reads = merge(
        (open = LocalMath.Access(external, identity),),
        NamedTuple{ntuple(index -> Symbol(:published_, index), length(results))}(
            map((field, relation) -> LocalMath.Access(field, relation), result_fields, result_relations)
        )
    )
    admission = LocalMath.Stage(
        domain, reads,
        (
            LocalMath.Publication(
                (LocalMath.FieldPublication(gate, identity, LocalMath.PublicationValue(:value)),),
                LocalMath.Unique(Bool)
            ),
        ),
        LocalMath.Evaluator(_StageSourceRefreshGate(), _stage_submission_parameters()),
        LocalMath.Control(), LocalMath.SourceOrigin(@__FILE__, @__LINE__; label = :stage_source_refresh_gate)
    )
    first_bank = first(banks)
    declaration = _site_tracker_rebuild_declaration(
        descriptor, first_bank.program.shape,
        length(first_bank.cell_kinds), eltype(first_bank.parameters);
        submission_parameters = _stage_submission_parameters(), gate
    )
    law = LocalMath.sequence(LocalMath.LocalLaw(admission), declaration.law)
    return map((1, 2)) do bank_index
        bank = banks[bank_index]
        parameters = declaration.parameter_field === nothing ? () :
            (
                declaration.parameter_field => _checkerboard_parameter_view(
                    bank.parameters,
                    Val(declaration.parameter_count), Tuple(bank.program.shape)
                ),
            )
        LocalMath.prepare(
            law,
            external => gates[bank_index], gate => LocalMath.Allocate(false),
            (relation => LocalMath.Allocate(ones(Int32, 1, 1)) for relation in result_relations)...,
            (binding for result in results for binding in _stage_publication_bindings(result, bank_index))...,
            declaration.ownership => bank.ownership,
            (
                field => state_block(bank.descriptor_state, handle).values
                    for (field, handle) in zip(declaration.fields, declaration.handles)
            )...,
            parameters...,
            declaration.output => tracker_values(bank.program.tracker_plan, bank.trackers, descriptor.quantity),
            declaration.validation_bindings...;
            backend, lease_capacity, dependency_arity = 1
        )
    end
end

function _compile_checkerboard_stage_boundary(
        workspace, groups::Tuple, backend, queue_mcs_capacity::Integer, state_layout, stage_plan,
        boundary::UInt16
    )
    descriptors = _stage_descriptors(groups)
    isempty(descriptors) && return ()
    state = workspace.state
    banks = (state, workspace.alternate_state)
    gates = map(_checkerboard_open_gate, banks)
    T = eltype(state.parameters)
    trajectory_key = _trajectory_key(state.seed, state.replica, state.repeat)
    shape = Tuple(state.program.shape)
    periodic = Tuple(state.program.periodic)
    resources = state.program.domain_resources
    source_trackers = filter(tracker -> tracker isa _SiteExpressionTracker, tracker_instances(state.program.tracker_plan))
    publication_results = map(descriptors) do descriptor
        descriptor.effect isa Union{SiteAssignmentEffect, IteratedSiteAssignmentEffect, ShiftAppendEffect} || return nothing
        any(tracker -> _site_tracker_reads_write(tracker, descriptor.effect.target, state_layout, stage_plan), source_trackers) || return nothing
        return _prepare_stage_publication_result(descriptor, backend, queue_mcs_capacity)
    end
    is_relationship(descriptor) = descriptor.effect isa Union{
        RelationshipRemoveEffect, RelationshipRetuneEffect,
    }
    relationship_descriptors = filter(is_relationship, descriptors)
    evaluations = ()
    publications = ()
    relationship_publications = ()
    relationships_prepared = false
    for (descriptor_index, descriptor) in enumerate(descriptors)
        publication_result = publication_results[descriptor_index]
        result_field = publication_result === nothing ? nothing : publication_result.output
        if is_relationship(descriptor)
            relationships_prepared && continue
            relationships_prepared = true
            # All requests for a packed relationship bank share one transaction,
            # including descriptors separated by ordinary state assignments.
            declarations = _compile_relationship_stage_group(
                relationship_descriptors, workspace.source_table, state.program,
                state.relationships,
                length(tracker_values(state.program.tracker_plan, state.trackers, Val(:cell_volume))),
                LocalMath.Field(LocalMath.Space(_CheckerboardStageGateDomain, 1), Bool), T
            )
            for declaration in declarations
                prepared = map(banks, gates) do bank, gate
                    LocalMath.prepare(
                        declaration.law, _relationship_stage_bindings(declaration, bank)...,
                        declaration.external_gate => gate;
                        backend, lease_capacity = queue_mcs_capacity, dependency_arity = 1
                    )
                end
                evaluations = (
                    evaluations..., _stage_boundary_entry(
                        prepared, descriptor.source_handle, :RelationshipEvaluation
                    ),
                )
                published = map(prepared, banks, gates) do evaluation, bank, gate
                    _prepare_relationship_stage_publication(
                        declaration, evaluation, bank, gate, backend, queue_mcs_capacity
                    )
                end
                relationship_publications = (
                    relationship_publications..., _stage_boundary_entry(
                        published, descriptor.source_handle, :RelationshipPublication
                    ),
                )
            end
            continue
        end
        effect = descriptor.effect
        effect isa CellAssignmentEffect && isempty(state.cell_kinds) && continue
        external_gate = LocalMath.Field(
            LocalMath.Space(_CheckerboardStageGateDomain, 1), Bool
        )
        declaration = if effect isa Union{SiteAssignmentEffect, IteratedSiteAssignmentEffect}
            merge(
                _compile_site_assignment_law(
                    descriptor, workspace.source_table, shape, periodic,
                    state.program.medium_kind, resources, state.ownership,
                    state.cell_kinds, state.program_status, external_gate,
                    state_layout, stage_plan, trajectory_key, boundary, T;
                    publication_result = result_field
                ), (; external_gate)
            )
        elseif effect isa Union{ModelAssignmentEffect, CellAssignmentEffect}
            domain = effect isa ModelAssignmentEffect ?
                LocalMath.Space(_CheckerboardStageModelDomain, 1) :
                LocalMath.Space(_CheckerboardStageCellDomain, length(state.cell_kinds))
            merge(
                _compile_identity_assignment_law(
                    descriptor, workspace.source_table, domain,
                    external_gate, state_layout, stage_plan, state.program.tracker_plan, state.trackers,
                    trajectory_key, boundary, T
                ), (; external_gate)
            )
        elseif effect isa ShiftAppendEffect
            merge(_compile_history_law(descriptor, external_gate, T; publication_result = result_field), (; external_gate))
        else
            throw(
                ArgumentError(
                    "checkerboard LocalMath boundary compiler does not support " *
                        "$(nameof(typeof(effect))) from source $(descriptor.source_handle)"
                )
            )
        end
        if effect isa ShiftAppendEffect
            prepared = map((1, 2)) do bank_index
                bank, gate = banks[bank_index], gates[bank_index]
                _prepare_history_stage_declaration(
                    declaration, bank, gate, backend, queue_mcs_capacity;
                    publication_bindings = _stage_publication_bindings(publication_result, bank_index)
                )
            end
            publications = (
                publications..., _stage_boundary_entry(
                    prepared, descriptor.source_handle, effect
                ),
            )
            continue
        end
        bindings_for = effect isa Union{ModelAssignmentEffect, CellAssignmentEffect} ?
            _identity_stage_bindings : _site_stage_bindings
        if effect isa IteratedSiteAssignmentEffect
            repetitions = _stage_submission_count(descriptor)
            lease_capacity = _checked_checkerboard_capacity_mul(
                queue_mcs_capacity, repetitions, :stage_boundary_lease_capacity
            )
            prepared = map((1, 2)) do bank_index
                bank, gate = banks[bank_index], gates[bank_index]
                LocalMath.prepare(
                    LocalMath.sequence(declaration.evaluation, declaration.publication),
                    bindings_for(declaration, bank, gate)...,
                    _stage_publication_bindings(publication_result, bank_index)...,
                    declaration.refreshed_gate => LocalMath.Allocate(false);
                    backend, lease_capacity, dependency_arity = 1
                )
            end
            publications = (
                publications..., _stage_boundary_entry(
                    prepared, descriptor.source_handle, nameof(typeof(effect)); repetitions
                ),
            )
            continue
        end
        prepared = map(banks, gates) do bank, gate
            LocalMath.prepare(
                declaration.evaluation, bindings_for(declaration, bank, gate)...;
                backend, lease_capacity = queue_mcs_capacity, dependency_arity = 1
            )
        end
        evaluations = (
            evaluations..., _stage_boundary_entry(
                prepared, descriptor.source_handle, :StateEvaluation
            ),
        )
        published = map((1, 2)) do bank_index
            evaluation, bank, gate = prepared[bank_index], banks[bank_index], gates[bank_index]
            _prepare_assignment_publication(
                declaration, evaluation, bank, gate, backend, queue_mcs_capacity, effect;
                publication_bindings = _stage_publication_bindings(publication_result, bank_index)
            )
        end
        publications = (
            publications..., _stage_boundary_entry(
                published, descriptor.source_handle, nameof(typeof(effect))
            ),
        )
    end
    # Ordinary right-hand sides observe boundary-entry state. Ordered substeps
    # and history then execute in descriptor order, before relationship commit.
    results = filter(!isnothing, publication_results)
    resets = map(results) do result
        _stage_boundary_entry(result.prepared, result.descriptor.source_handle, :SourcePublicationReset)
    end
    refreshes = ()
    for tracker in source_trackers
        dependencies = filter(
            result -> _site_tracker_reads_write(
                tracker, result.descriptor.effect.target,
                state_layout, stage_plan
            ), results
        )
        isempty(dependencies) && continue
        prepared = _prepare_stage_source_refresh(tracker, dependencies, banks, gates, backend, queue_mcs_capacity)
        refreshes = (
            refreshes..., _stage_boundary_entry(
                prepared,
                first(dependencies).descriptor.source_handle, :SourceTrackerRefresh
            ),
        )
    end
    return (resets..., evaluations..., publications..., relationship_publications..., refreshes...)
end

function _prepare_checkerboard_stage_boundaries(
        workspace, stage_plan::StageExecutionPlan, backend,
        queue_mcs_capacity::Integer, state_layout
    )
    before = _compile_checkerboard_stage_boundary(
        workspace, stage_plan.before_lifecycle, backend, queue_mcs_capacity, state_layout, stage_plan,
        _SCHEDULED_BEFORE_LIFECYCLE
    )
    after = _compile_checkerboard_stage_boundary(
        workspace, stage_plan.after_lifecycle, backend, queue_mcs_capacity, state_layout, stage_plan,
        _SCHEDULED_AFTER_LIFECYCLE
    )
    return (; before, after)
end
