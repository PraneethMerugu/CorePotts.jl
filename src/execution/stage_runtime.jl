# Generic accepted-copy and after-MCS staged-effect execution.

struct _SiteStageEvaluationContext{R, I, G} <:
    AbstractSiteStageEvaluationContext
    runtime::R
    site::I
    rng::G
end

struct _CellStageEvaluationContext{R, G} <: AbstractCellStageEvaluationContext
    runtime::R
    cell::Int32
    rng::G
end

@inline function apply_resource_operation(
        ::ResourceOperation{:draw}, arguments,
        context::Union{_SiteStageEvaluationContext, _CellStageEvaluationContext}
    )
    return _scheduled_draw(arguments, context.rng)
end

@inline _compiled_resource_operation(
    operation::ResourceOperation{:draw}, arguments::Tuple,
    context::Union{_SiteStageEvaluationContext, _CellStageEvaluationContext},
) = apply_resource_operation(operation, arguments, context)

@inline stage_cell(context::_CellStageEvaluationContext) = context.cell
@inline context_value(::ContextOperation{:energy_anchor_cell}, context::_CellStageEvaluationContext) = stage_cell(context)
@inline _compiled_context_value(operation::ContextOperation{:energy_anchor_cell}, context::_CellStageEvaluationContext) = context_value(operation, context)
operation_context_supported(::ContextOperation{:energy_anchor_cell}, ::Type{AbstractCellStageEvaluationContext}) = true
@inline stage_site(::ModelStageSite, ::_CellStageEvaluationContext) = Int32(1)
@inline _compiled_evaluator_parameters(context::_CellStageEvaluationContext) = context.runtime.parameters
@inline evaluator_parameters(context::_CellStageEvaluationContext) = context.runtime.parameters
@inline state_value(context::_CellStageEvaluationContext, handle::StateHandle, slot) =
    @inbounds state_block(context.runtime.descriptor_state, handle).values[slot]

@inline function _cell_stage_eligible(effect::CellAssignmentEffect, kind, generation)
    return kind == effect.domain_kind && !iszero(generation)
end

function _emit_after_mcs_descriptor!(runtime, descriptor::CompiledStageDescriptor{C, V, E, AfterMCSStage}, boundary::UInt16) where {C, V, E <: CellAssignmentEffect}
    scratch = runtime.stage_buffers.after_mcs_cell[Int(descriptor.buffer_slot)]
    T = _stage_value_type(descriptor.effect, eltype(runtime.parameters))
    for cell in eachindex(runtime.cell_kinds)
        if !_cell_stage_eligible(descriptor.effect, runtime.cell_kinds[cell], runtime.cell_generations[cell])
            scratch[cell] = _state_value_zero(StageEvaluation{T})
            continue
        end
        context = _CellStageEvaluationContext(
            runtime, Int32(cell),
            _scheduled_rng_context(runtime, boundary, CellEntity, cell, runtime.cell_generations[cell], 0)
        )
        condition = _compiled_evaluate_static(descriptor.condition, context)
        condition isa Bool || throw(ArgumentError("cell-stage condition must return Bool"))
        value = condition ? convert(T, _compiled_evaluate_static(descriptor.value, context)) : _state_value_zero(T)
        _state_value_isfinite(value) || throw(DomainError(value, "cell-stage value must be finite"))
        scratch[cell] = StageEvaluation(condition, value)
    end
    return runtime
end

function _apply_after_mcs_descriptor!(runtime, descriptor::CompiledStageDescriptor{C, V, E, AfterMCSStage}, boundary::UInt16) where {C, V, E <: CellAssignmentEffect}
    scratch = runtime.stage_buffers.after_mcs_cell[Int(descriptor.buffer_slot)]
    values = state_block(runtime.descriptor_state, descriptor.effect.target).values
    for cell in eachindex(scratch)
        evaluation = scratch[cell]
        evaluation.enabled && (values[cell] = evaluation.value)
    end
    return runtime
end

struct _RelationshipStageEvaluationContext{R, S} <:
    AbstractRelationshipStageEvaluationContext
    runtime::R
    relationship::S
    edge::Int32
end

@inline _compiled_evaluator_parameters(
    context::_RelationshipStageEvaluationContext
) = context.runtime.parameters
@inline evaluator_parameters(
    context::_RelationshipStageEvaluationContext
) = context.runtime.parameters
@inline context_value(
    ::ContextOperation{:energy_anchor_relationship},
    context::_RelationshipStageEvaluationContext,
) = context.edge
@inline function _compiled_context_value(
        operation::ContextOperation{Identity},
        context::_RelationshipStageEvaluationContext,
    ) where {Identity}
    return invoke(
        context_value,
        Tuple{
            ContextOperation{Identity},
            _RelationshipStageEvaluationContext,
        },
        operation,
        context,
    )
end
@inline function apply_resource_operation(
        ::ResourceOperation{:endpoint_a},
        arguments,
        context::_RelationshipStageEvaluationContext,
    )
    return @inbounds context.relationship.endpoint_a[Int(only(arguments))]
end
@inline function apply_resource_operation(
        ::ResourceOperation{:endpoint_b},
        arguments,
        context::_RelationshipStageEvaluationContext,
    )
    return @inbounds context.relationship.endpoint_b[Int(only(arguments))]
end
@inline function apply_resource_operation(
        ::ResourceOperation{:edge_payload},
        arguments,
        context::_RelationshipStageEvaluationContext,
    )
    return relationship_payload(
        context.relationship,
        Int(first(arguments)),
        Int(last(arguments)),
    )
end
@inline function apply_resource_operation(
        ::ResourceOperation{:cell_volume},
        arguments,
        context::_RelationshipStageEvaluationContext,
    )
    owner = Int(only(arguments))
    owner <= 0 && return Int32(0)
    return program_tracker_value(
        context.runtime, Val(:cell_volume), owner
    )
end
@inline apply_resource_operation(
    ::ResourceOperation{:unwrapped_center},
    arguments,
    context::_RelationshipStageEvaluationContext,
) = _cell_center(context.runtime, Int32(only(arguments)))
@inline apply_resource_operation(
    ::ResourceOperation{:cell_center},
    arguments,
    context::_RelationshipStageEvaluationContext,
) = _cell_center(context.runtime, Int32(only(arguments)))
@inline apply_resource_operation(
    ::ResourceOperation{:distance},
    arguments,
    ::_RelationshipStageEvaluationContext,
) = _center_distance(first(arguments), last(arguments))
@inline function _compiled_resource_operation(
        operation::ResourceOperation{Identity},
        arguments::Tuple,
        context::_RelationshipStageEvaluationContext,
    ) where {Identity}
    return invoke(
        apply_resource_operation,
        Tuple{
            ResourceOperation{Identity},
            Any,
            _RelationshipStageEvaluationContext,
        },
        operation,
        arguments,
        context,
    )
end

operation_context_supported(
    operation::ContextOperation,
    ::Type{AbstractRelationshipStageEvaluationContext},
) = hasmethod(
    context_value,
    Tuple{typeof(operation), _RelationshipStageEvaluationContext},
)

operation_context_supported(
    operation::ResourceOperation,
    ::Type{AbstractRelationshipStageEvaluationContext},
) = hasmethod(
    apply_resource_operation,
    Tuple{typeof(operation), Tuple, _RelationshipStageEvaluationContext},
)
@inline function state_value(
        context::_RelationshipStageEvaluationContext,
        handle::StateHandle,
        site,
    )
    return @inbounds state_block(
        context.runtime.descriptor_state, handle
    ).values[site]
end

@inline function apply_resource_operation(
        ::ResourceOperation{:field_value}, arguments,
        context::_RelationshipStageEvaluationContext,
    )
    return state_value(context, first(arguments), last(arguments))
end

@inline _compiled_evaluator_parameters(
    context::_SiteStageEvaluationContext
) = context.runtime.parameters
@inline evaluator_parameters(context::_SiteStageEvaluationContext) =
    context.runtime.parameters
@inline stage_site(
    ::IterationStageSite,
    context::_SiteStageEvaluationContext,
) = context.site
@inline stage_site(
    ::ModelStageSite,
    ::_SiteStageEvaluationContext,
) = 1
@inline context_value(::ContextOperation{:energy_anchor_site}, context::_SiteStageEvaluationContext) =
    _stage_linear_index(size(context.runtime.ownership), stage_site(IterationStageSite(), context))
@inline _compiled_context_value(operation::ContextOperation{:energy_anchor_site}, context::_SiteStageEvaluationContext) = context_value(operation, context)
operation_context_supported(::ContextOperation{:energy_anchor_site}, ::Type{AbstractSiteStageEvaluationContext}) = true
@inline function state_value(
        context::_SiteStageEvaluationContext,
        handle::StateHandle,
        site,
    )
    return @inbounds state_block(
        context.runtime.descriptor_state, handle
    ).values[site]
end
@inline site_owner(
    context::_SiteStageEvaluationContext, site
) = @inbounds context.runtime.ownership[site]
@inline owner_kind(
    context::_SiteStageEvaluationContext, owner::Integer
) = _owner_kind(context.runtime, Int32(owner))
@inline function relation_count(
        context::_SiteStageEvaluationContext,
        relation_handle::Integer,
    )
    _, count = _contact_domain_columns(
        context.runtime.program.descriptor_plan.domain_resources,
        Int32(relation_handle),
    )
    return Int(count)
end
@inline function relation_neighbor_site(
        context::_SiteStageEvaluationContext,
        relation_handle::Integer,
        center,
        direction::Integer,
    )
    resources = context.runtime.program.descriptor_plan.domain_resources
    start, count = _contact_domain_columns(
        resources, Int32(relation_handle)
    )
    1 <= direction <= count || return nothing
    return _neighbor_index(
        context.runtime.program,
        center,
        resources.contact_offsets,
        Int(start + Int32(direction - 1)),
    )
end

@inline function descriptor_emit_requests!(
        requests::Ref{StageEvaluation{T}},
        descriptor::CompiledStageDescriptor{
            C, V, E, AcceptedCopyStage,
        },
        context::_ProposalEvaluationContext,
    ) where {T, C, V, E}
    condition = _compiled_evaluate_static(descriptor.condition, context)
    condition isa Bool || throw(
        ArgumentError(
            "accepted-copy stage condition must return Bool"
        )
    )
    value = condition ? convert(
            T, _compiled_evaluate_static(
                descriptor.value, context
            )
        ) : _state_value_zero(T)
    _state_value_isfinite(value) || throw(
        DomainError(
            value, "accepted-copy stage value must be finite"
        )
    )
    requests[] =
        StageEvaluation(condition, value)
    return requests
end

@inline function _relationship_create_request(
        effect::RelationshipCreateEffect,
        context::_ProposalEvaluationContext,
    )
    endpoint_a = Int32(
        _compiled_evaluate_static(
            effect.endpoint_a, context
        )
    )
    endpoint_b = Int32(
        _compiled_evaluate_static(
            effect.endpoint_b, context
        )
    )
    payload = map(
        evaluator -> _compiled_evaluate_static(evaluator, context),
        effect.payload,
    )
    generation_a = 1 <= endpoint_a <= length(context.runtime.cell_generations) ?
        @inbounds(context.runtime.cell_generations[endpoint_a]) :
        UInt32(0)
    generation_b = 1 <= endpoint_b <= length(context.runtime.cell_generations) ?
        @inbounds(context.runtime.cell_generations[endpoint_b]) :
        UInt32(0)
    return CreateRelationshipRequest(
        endpoint_a,
        endpoint_b,
        payload;
        generation_a,
        generation_b,
        priority = effect.priority,
        identity = context.attempt,
        on_failure = RelationshipFailureFilter,
    )
end

@inline function descriptor_emit_requests!(
        requests::Ref{StageEvaluation{T}},
        descriptor::CompiledStageDescriptor{
            C, V, E, AcceptedCopyStage,
        },
        context::_ProposalEvaluationContext,
    ) where {
        T,
        C,
        V,
        E <: RelationshipCreateEffect,
    }
    condition = _compiled_evaluate_static(descriptor.condition, context)
    condition isa Bool || throw(
        ArgumentError(
            "accepted-copy relationship condition must return Bool"
        )
    )
    enabled = false
    if condition
        effect = descriptor.effect
        request = _relationship_create_request(effect, context)
        emit_relationship_request_at!(
            context.runtime.stage_buffers.relationship_transactions,
            effect.relationship_slot,
            request,
        )
        enabled = true
    end
    requests[] =
        StageEvaluation(enabled, zero(T))
    return requests
end

@inline function descriptor_emit_requests!(
        scratch::AbstractArray{T},
        descriptor::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        context::_SiteStageEvaluationContext,
    ) where {T, C, V, E}
    condition = _compiled_evaluate_static(descriptor.condition, context)
    condition isa Bool || throw(
        ArgumentError(
            "after-MCS stage condition must return Bool"
        )
    )
    value = condition ? convert(
            T, _compiled_evaluate_static(
                descriptor.value, context
            )
        ) : convert(
            T, state_value(
                context, descriptor.effect.target, context.site
            )
        )
    _state_value_isfinite(value) || throw(
        DomainError(
            value, "after-MCS stage value must be finite"
        )
    )
    @inbounds scratch[context.site] = value
    return scratch
end

@inline function descriptor_emit_requests!(
        scratch::Ref{StageEvaluation{T}},
        descriptor::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        context::_SiteStageEvaluationContext,
    ) where {T, C, V, E <: ModelAssignmentEffect}
    condition = _compiled_evaluate_static(descriptor.condition, context)
    condition isa Bool || throw(
        ArgumentError(
            "after-MCS model assignment condition must return Bool"
        )
    )
    value = condition ? convert(
            T, _compiled_evaluate_static(
                descriptor.value, context
            )
        ) : _state_value_zero(T)
    condition && !_state_value_isfinite(value) && throw(
        DomainError(
            value, "after-MCS model assignment value must be finite"
        )
    )
    scratch[] =
        StageEvaluation(condition, value)
    return scratch
end

@inline function _apply_site_assignment!(
        descriptor::CompiledStageDescriptor,
        request::StageEvaluation,
        state::AuxiliaryState,
        site,
    )
    request.enabled || return state
    effect = descriptor.effect
    effect isa SiteAssignmentEffect || throw(
        ArgumentError(
            "unsupported compiled accepted-copy effect"
        )
    )
    @inbounds state_block(state, effect.target).values[site] = request.value
    return state
end

@inline function descriptor_apply_stage!(
        descriptor::CompiledStageDescriptor{
            C, V, E, AcceptedCopyStage,
        },
        request::StageEvaluation,
        runtime,
        context::_ProposalEvaluationContext,
    ) where {C, V, E <: SiteAssignmentEffect}
    return _apply_site_assignment!(
        descriptor,
        request,
        runtime.descriptor_state,
        context.target,
    )
end

@inline function descriptor_apply_stage!(
        descriptor::CompiledStageDescriptor{
            C, V, E, AcceptedCopyStage,
        },
        evaluation::StageEvaluation,
        runtime,
        context::_ProposalEvaluationContext,
    ) where {C, V, E <: RelationshipCreateEffect}
    evaluation.enabled || return runtime
    return runtime
end

@inline function descriptor_apply_stage!(
        descriptor::CompiledStageDescriptor,
        scratch::AbstractArray,
        state::AuxiliaryState,
    )
    effect = descriptor.effect
    effect isa Union{SiteAssignmentEffect, IteratedSiteAssignmentEffect} ||
        throw(
        ArgumentError(
            "unsupported compiled after-MCS effect"
        )
    )
    copyto!(state_block(state, effect.target).values, scratch)
    return state
end

@inline _emit_accepted_copy_groups!(
    requests, ::Tuple{}, context
) = requests
@inline function _emit_accepted_copy_groups!(
        requests,
        groups::Tuple,
        context,
    )
    for descriptor in first(groups).instances
        descriptor_emit_requests!(requests[Int(descriptor.buffer_slot)], descriptor, context)
    end
    return _emit_accepted_copy_groups!(
        requests, Base.tail(groups), context
    )
end

@inline _apply_accepted_copy_groups!(
    runtime, ::Tuple{}, requests, context
) = runtime
@inline function _apply_accepted_copy_groups!(
        runtime,
        groups::Tuple,
        requests,
        context,
    )
    for descriptor in first(groups).instances
        request = @inbounds requests[Int(descriptor.buffer_slot)][]
        descriptor_apply_stage!(
            descriptor, request, runtime, context
        )
    end
    return _apply_accepted_copy_groups!(
        runtime, Base.tail(groups), requests, context
    )
end

@inline function _emit_accepted_copy_stage!(
        runtime::ProgramRuntime,
        context::_ProposalEvaluationContext,
    )
    _reset_relationship_transactions!(
        runtime.stage_buffers.relationship_transactions,
        runtime.relationships,
    )
    result = _emit_accepted_copy_groups!(
        runtime.stage_buffers.accepted_copy,
        runtime.program.stage_plan.accepted_copy,
        context,
    )
    _prepare_relationship_transactions!(
        runtime.stage_buffers.relationship_transactions,
        runtime.cell_kinds,
        runtime.cell_generations,
        runtime.program.relationships,
    )
    return result
end

@inline function _apply_accepted_copy_stage!(
        runtime::ProgramRuntime,
        context::_ProposalEvaluationContext,
    )
    _apply_accepted_copy_groups!(
        runtime,
        runtime.program.stage_plan.accepted_copy,
        runtime.stage_buffers.accepted_copy,
        context,
    )
    _publish_relationship_transactions!(
        runtime.relationships,
        runtime.stage_buffers.relationship_transactions,
    )
    return nothing
end

@inline function _clear_site_samples!(values, site::CartesianIndex{N}) where {N}
    cleared = _state_value_zero(eltype(values))
    if ndims(values) == N
        @inbounds values[site] = cleared
    else
        for sample in axes(values, N + 1)
            @inbounds values[site, sample] = cleared
        end
    end
    return values
end

function _clear_ownership_changed_state!(
        layout::StateLayout,
        state::AuxiliaryState,
        site,
    )
    for entry in layout.entries
        lifecycle = entry.schema.lifecycle
        declared = lifecycle isa NamedTuple && haskey(lifecycle, :declared) ?
            lifecycle.declared : nothing
        declared === :ClearOnOwnershipChange || continue
        values = state_block(state, entry.handle).values
        _clear_site_samples!(values, site)
    end
    return state
end

function _emit_after_mcs_descriptor!(
        runtime,
        descriptor::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        boundary::UInt16,
    ) where {C, V, E <: SiteAssignmentEffect}
    scratch = @inbounds runtime.stage_buffers.after_mcs[
        Int(descriptor.buffer_slot),
    ]
    for site in CartesianIndices(runtime.ownership)
        descriptor_emit_requests!(
            scratch,
            descriptor,
            _SiteStageEvaluationContext(
                runtime, site,
                _scheduled_rng_context(runtime, boundary, SiteEntity, LinearIndices(runtime.ownership)[site], 0, 0)
            ),
        )
    end
    return runtime
end

function _emit_after_mcs_descriptor!(
        runtime,
        descriptor::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        boundary::UInt16,
    ) where {C, V, E <: ModelAssignmentEffect}
    descriptor_emit_requests!(
        runtime.stage_buffers.after_mcs_model[Int(descriptor.buffer_slot)],
        descriptor,
        _SiteStageEvaluationContext(
            runtime, 1, _scheduled_rng_context(runtime, boundary, ModelEntity, 0, 0, 0)
        ),
    )
    return runtime
end

@inline function _emit_after_mcs_descriptor!(
        runtime,
        ::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        boundary::UInt16,
    ) where {C, V, E <: ShiftAppendEffect}
    return runtime
end

@inline function _emit_after_mcs_descriptor!(
        runtime,
        ::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        boundary::UInt16,
    ) where {C, V, E <: IteratedSiteAssignmentEffect}
    return runtime
end

function _emit_after_mcs_relationship_descriptor!(
        state,
        runtime,
        descriptor::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
    ) where {
        C, V, E <: Union{
            RelationshipRemoveEffect, RelationshipRetuneEffect,
        },
    }
    effect = descriptor.effect
    for edge in eachindex(state.active)
        @inbounds state.active[edge] || continue
        context = _RelationshipStageEvaluationContext(
            runtime, state, Int32(edge)
        )
        condition = _compiled_evaluate_static(
            descriptor.condition,
            context,
        )
        condition isa Bool || throw(
            ArgumentError(
                "relationship lifecycle condition must return Bool"
            )
        )
        condition || continue
        identity = UInt64(UInt32(descriptor.source_handle)) << 32 |
            UInt64(UInt32(edge))
        request = if effect isa RelationshipRemoveEffect
            RemoveRelationshipRequest(edge; identity)
        else
            payload = map(
                evaluator -> _compiled_evaluate_static(evaluator, context),
                effect.payload,
            )
            RetuneRelationshipRequest(edge, payload; identity)
        end
        emit_relationship_request_at!(
            runtime.stage_buffers.relationship_transactions,
            effect.relationship_slot,
            request,
        )
    end
    return runtime
end

function _emit_after_mcs_descriptor!(
        runtime,
        descriptor::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        boundary::UInt16,
    ) where {
        C, V, E <: Union{
            RelationshipRemoveEffect, RelationshipRetuneEffect,
        },
    }
    return _call_relationship_slot(
        _emit_after_mcs_relationship_descriptor!,
        runtime.relationships,
        descriptor.effect.relationship_slot,
        (runtime, descriptor),
    )
end

function _emit_after_mcs_groups!(runtime, ::Tuple{}, boundary::UInt16)
    return runtime
end
function _emit_after_mcs_groups!(runtime, groups::Tuple, boundary::UInt16)
    for descriptor in first(groups).instances
        _emit_after_mcs_descriptor!(runtime, descriptor, boundary)
    end
    return _emit_after_mcs_groups!(runtime, Base.tail(groups), boundary)
end

function _apply_after_mcs_descriptor!(
        runtime,
        descriptor::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        boundary::UInt16,
    ) where {C, V, E <: SiteAssignmentEffect}
    scratch = @inbounds runtime.stage_buffers.after_mcs[
        Int(descriptor.buffer_slot),
    ]
    descriptor_apply_stage!(descriptor, scratch, runtime.descriptor_state)
    return runtime
end

function _apply_after_mcs_descriptor!(
        runtime,
        descriptor::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        boundary::UInt16,
    ) where {C, V, E <: ModelAssignmentEffect}
    evaluation = @inbounds runtime.stage_buffers.after_mcs_model[
        Int(descriptor.buffer_slot),
    ][]
    evaluation.enabled || return runtime
    values = state_block(runtime.descriptor_state, descriptor.effect.target).values
    length(values) == 1 || throw(
        ArgumentError(
            "compiled model assignment target must contain exactly one logical value"
        )
    )
    @inbounds values[firstindex(values)] = evaluation.value
    return runtime
end

function _apply_after_mcs_descriptor!(
        runtime,
        ::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        boundary::UInt16,
    ) where {
        C, V, E <: Union{
            RelationshipRemoveEffect, RelationshipRetuneEffect,
        },
    }
    return runtime
end

function _apply_after_mcs_descriptor!(
        runtime,
        descriptor::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        boundary::UInt16,
    ) where {C, V, E <: IteratedSiteAssignmentEffect}
    scratch = @inbounds runtime.stage_buffers.after_mcs[
        Int(descriptor.buffer_slot),
    ]
    for invocation in 0:(Int(descriptor.effect.iterations) - 1)
        for site in CartesianIndices(runtime.ownership)
            descriptor_emit_requests!(
                scratch,
                descriptor,
                _SiteStageEvaluationContext(
                    runtime, site,
                    _scheduled_rng_context(runtime, boundary, SiteEntity, LinearIndices(runtime.ownership)[site], 0, invocation)
                ),
            )
        end
        descriptor_apply_stage!(
            descriptor, scratch, runtime.descriptor_state
        )
    end
    return runtime
end

function _apply_after_mcs_descriptor!(
        runtime,
        descriptor::CompiledStageDescriptor{
            C, V, E, AfterMCSStage,
        },
        boundary::UInt16,
    ) where {C, V, E <: ShiftAppendEffect}
    _apply_history_effect!(runtime.descriptor_state, descriptor.effect, runtime.mcs + 1)
    return runtime
end

function _apply_history_effect!(state, effect::ShiftAppendEffect, completed_mcs::Integer)
    _completed_mcs_due(effect.cadence, effect.cadence_value, completed_mcs) || return state
    target = state_block(state, effect.target).values
    source = state_block(state, effect.source).values
    axis = Int(effect.axis)
    1 <= axis <= ndims(target) || error(
        "compiled shift-append axis is outside its target block"
    )
    size(target)[1:(axis - 1)] == _history_source_shape(effect.source) || error(
        "compiled shift-append source shape is incompatible"
    )
    size(target)[(axis + 1):end] == () || error(
        "compiled shift-append target has trailing dimensions"
    )
    depth = size(target, axis)
    if completed_mcs != 0
        for index in 1:(depth - 1)
            copyto!(
                selectdim(target, axis, index),
                selectdim(target, axis, index + 1),
            )
        end
    end
    copyto!(selectdim(target, axis, depth), source)
    return state
end

function _apply_after_mcs_groups!(runtime, ::Tuple{}, boundary::UInt16)
    return runtime
end
function _apply_after_mcs_groups!(runtime, groups::Tuple, boundary::UInt16)
    for descriptor in first(groups).instances
        _apply_after_mcs_descriptor!(runtime, descriptor, boundary)
    end
    return _apply_after_mcs_groups!(runtime, Base.tail(groups), boundary)
end

function _execute_after_mcs_stage!(runtime, groups, boundary::UInt16)
    _reset_relationship_transactions!(
        runtime.stage_buffers.relationship_transactions,
        runtime.relationships,
    )
    _emit_after_mcs_groups!(runtime, groups, boundary)
    _prepare_relationship_transactions!(
        runtime.stage_buffers.relationship_transactions,
        runtime.cell_kinds,
        runtime.cell_generations,
        runtime.program.relationships,
    )
    _apply_after_mcs_groups!(runtime, groups, boundary)
    _publish_relationship_transactions!(
        runtime.relationships,
        runtime.stage_buffers.relationship_transactions,
    )
    return nothing
end

"""Log acceptance ratio for the conventional descriptor-driven law."""
