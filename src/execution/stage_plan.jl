# Generic staged-effect descriptors and their preallocated runtime buffers.

"""Scientific scheduling boundary for a compiled stage descriptor."""
abstract type AbstractCompiledStage end
"""Run a stage only for accepted copy proposals."""
struct AcceptedCopyStage <: AbstractCompiledStage end
"""Run a stage once after each completed MCS."""
struct AfterMCSStage <: AbstractCompiledStage end

"""Policy selecting the site bound to one compiled stage evaluation."""
abstract type AbstractStageSiteSelector end
"""Bind stage evaluation to the accepted proposal target site."""
struct ProposalTargetStageSite <: AbstractStageSiteSelector end
"""Bind stage evaluation to the current explicit iteration site."""
struct IterationStageSite <: AbstractStageSiteSelector end
"""Select the sole logical value of a model-scoped state block."""
struct ModelStageSite <: AbstractStageSiteSelector end

"""Read one declared state block at the site bound by a compiled stage."""
struct BoundStateValueOperation{S <: AbstractStageSiteSelector} <:
    AbstractContextualOperation end

function operation_callable(
        ::Val{:proposal_bound_state_value},
        version::VersionNumber,
    )
    version == v"1.0.0" || throw(
        ArgumentError(
            "unsupported proposal-bound-state operation version $version"
        )
    )
    return BoundStateValueOperation{ProposalTargetStageSite}()
end

function operation_callable(
        ::Val{:iteration_bound_state_value},
        version::VersionNumber,
    )
    version == v"1.0.0" || throw(
        ArgumentError(
            "unsupported iteration-bound-state operation version $version"
        )
    )
    return BoundStateValueOperation{IterationStageSite}()
end

function operation_callable(
        ::Val{:model_bound_state_value},
        version::VersionNumber,
    )
    version == v"1.0.0" || throw(
        ArgumentError(
            "unsupported model-bound-state operation version $version"
        )
    )
    return BoundStateValueOperation{ModelStageSite}()
end

"""Return the lattice site selected by a stage-site policy and context."""
function stage_site end

@inline function (operation::BoundStateValueOperation{S})(
        arguments::Tuple, context
    ) where {S <: AbstractStageSiteSelector}
    handle = only(arguments)
    return state_value(context, handle, stage_site(S(), context))
end

operation_context_supported(
    ::BoundStateValueOperation{ProposalTargetStageSite},
    ::Type{AbstractProposalEvaluationContext},
) = true

operation_context_supported(
    ::BoundStateValueOperation{IterationStageSite},
    ::Type{AbstractSiteStageEvaluationContext},
) = true

operation_context_supported(
    ::BoundStateValueOperation{ModelStageSite},
    ::Type{AbstractSiteStageEvaluationContext},
) = true

operation_context_supported(
    ::BoundStateValueOperation{ModelStageSite},
    ::Type{AbstractProposalEvaluationContext},
) = true

operation_context_supported(
    ::BoundStateValueOperation{ModelStageSite},
    ::Type{AbstractHamiltonianEvaluationContext},
) = true

operation_context_supported(
    ::BoundStateValueOperation{ModelStageSite},
    ::Type{AbstractCellStageEvaluationContext},
) = true

abstract type AbstractCompiledEffect end

"""Read one declared cell-state block at the current finite-cell slot."""
struct BoundCellStateValueOperation <: AbstractContextualOperation end

function operation_callable(::Val{:cell_bound_state_value}, version::VersionNumber)
    version == v"1.0.0" || throw(ArgumentError("unsupported cell-bound-state operation version $version"))
    return BoundCellStateValueOperation()
end

"""Return the finite-cell slot bound to a cell-stage evaluation."""
function stage_cell end

@inline (::BoundCellStateValueOperation)(arguments::Tuple, context) =
    state_value(context, only(arguments), stage_cell(context))

operation_context_supported(::BoundCellStateValueOperation, ::Type{AbstractCellStageEvaluationContext}) = true

"""Assign one logical value once to each active finite cell of a declared kind."""
struct CellAssignmentEffect{H <: StateHandle} <: AbstractCompiledEffect
    target::H
    domain_kind::Int16
    function CellAssignmentEffect(target::H, domain_kind::Integer) where {H <: StateHandle}
        1 <= domain_kind <= typemax(Int16) || throw(ArgumentError("cell assignment requires a positive finite-cell kind"))
        return new{H}(target, Int16(domain_kind))
    end
end

"""Assign one logical value to one site in a declared auxiliary-state block."""
struct SiteAssignmentEffect{H <: StateHandle} <: AbstractCompiledEffect
    target::H
end

"""Assign one model-scoped logical value once at an after-MCS boundary."""
struct ModelAssignmentEffect{H <: StateHandle} <: AbstractCompiledEffect
    target::H
end

"""Repeat a synchronous site assignment through a fixed number of substeps."""
struct IteratedSiteAssignmentEffect{H <: StateHandle} <:
    AbstractCompiledEffect
    target::H
    iterations::Int32
    function IteratedSiteAssignmentEffect(
            target::H, iterations::Integer
        ) where {H <: StateHandle}
        iterations > 0 || throw(
            ArgumentError(
                "an iterated site assignment requires a positive iteration count"
            )
        )
        return new{H}(target, Int32(iterations))
    end
end

"""Shift a dense state block along one axis and append another state block."""
struct ShiftAppendEffect{
        T <: StateHandle,
        S <: StateHandle,
    } <: AbstractCompiledEffect
    target::T
    source::S
    axis::Int32
    cadence::CompletedMCSCadence
    cadence_value::Int64
    function ShiftAppendEffect(
            target::T,
            source::S,
            axis::Integer;
            cadence::CompletedMCSCadence = EveryMCSCadence,
            cadence_value::Integer = 1,
        ) where {T <: StateHandle, S <: StateHandle}
        axis > 0 || throw(
            ArgumentError(
                "a shift-append effect axis must be positive"
            )
        )
        _validate_completed_mcs_cadence(cadence, cadence_value; initialization = true)
        return new{T, S}(target, source, Int32(axis), cadence, Int64(cadence_value))
    end
end

# A zero-dimensional model block is one sample, not an empty source domain.
_history_source_shape(handle::StateHandle) =
    isempty(handle_shape(handle)) ? (1,) : Tuple(Int.(handle_shape(handle)))

"""Create one bounded relationship record from compiled endpoint and payload evaluators."""
struct RelationshipCreateEffect{
        A <: StaticEvaluator,
        B <: StaticEvaluator,
        P <: Tuple,
    } <: AbstractCompiledEffect
    relationship_slot::Int32
    endpoint_a::A
    endpoint_b::B
    payload::P
    priority::Int32
end

function RelationshipCreateEffect(
        relationship_slot::Integer,
        endpoint_a::A,
        endpoint_b::B,
        payload::P,
        priority::Integer = 0,
    ) where {A <: StaticEvaluator, B <: StaticEvaluator, P <: Tuple}
    relationship_slot > 0 || throw(
        ArgumentError(
            "a relationship-create effect requires a positive storage slot"
        )
    )
    all(evaluator -> evaluator isa StaticEvaluator, payload) ||
        throw(
        ArgumentError(
            "relationship payload entries must be compiled evaluators"
        )
    )
    return RelationshipCreateEffect{A, B, P}(
        Int32(relationship_slot),
        endpoint_a,
        endpoint_b,
        payload,
        Int32(priority),
    )
end


"""Remove records selected over one bounded relationship store after an MCS."""
struct RelationshipRemoveEffect <: AbstractCompiledEffect
    relationship_slot::Int32
    function RelationshipRemoveEffect(relationship_slot::Integer)
        relationship_slot > 0 || throw(
            ArgumentError(
                "a relationship-remove effect requires a positive storage slot"
            )
        )
        return new(Int32(relationship_slot))
    end
end

"""Retune one bounded relationship payload from compiled evaluators."""
struct RelationshipRetuneEffect{P <: Tuple} <: AbstractCompiledEffect
    relationship_slot::Int32
    payload::P
    function RelationshipRetuneEffect(
            relationship_slot::Integer,
            payload::P,
        ) where {P <: Tuple}
        relationship_slot > 0 || throw(
            ArgumentError(
                "a relationship-retune effect requires a positive storage slot"
            )
        )
        all(evaluator -> evaluator isa StaticEvaluator, payload) || throw(
            ArgumentError(
                "relationship-retune payload entries must be compiled evaluators"
            )
        )
        return new{P}(Int32(relationship_slot), payload)
    end
end


function stage_effect_buffered end
stage_effect_buffered(::AbstractCompiledEffect) = false
stage_effect_buffered(::SiteAssignmentEffect) = true
stage_effect_buffered(::ModelAssignmentEffect) = true
stage_effect_buffered(::CellAssignmentEffect) = true
stage_effect_buffered(::IteratedSiteAssignmentEffect) = true
stage_effect_buffered(::RelationshipCreateEffect) = true
stage_effect_buffered(::RelationshipRemoveEffect) = true
stage_effect_buffered(::RelationshipRetuneEffect) = true

"""One condition, value, effect, access contract, and scheduling boundary."""
struct CompiledStageDescriptor{
        C <: StaticEvaluator,
        V <: StaticEvaluator,
        E <: AbstractCompiledEffect,
        P <: AbstractCompiledStage,
        A <: ResourceAccess,
        S,
    }
    condition::C
    value::V
    effect::E
    stage::P
    access::A
    support::S
    source_handle::Int32
    buffer_slot::Int32
end

function CompiledStageDescriptor(
        condition::C,
        value::V,
        effect::E,
        stage::P,
        access::A,
        support::S,
        source_handle::Integer,
        buffer_slot::Integer,
    ) where {
        C <: StaticEvaluator,
        V <: StaticEvaluator,
        E <: AbstractCompiledEffect,
        P <: AbstractCompiledStage,
        A <: ResourceAccess,
        S,
    }
    source_handle > 0 || throw(
        ArgumentError(
            "a stage descriptor source handle must be positive"
        )
    )
    buffer_slot >= 0 || throw(
        ArgumentError(
            "a stage descriptor buffer slot cannot be negative"
        )
    )
    stage_effect_buffered(effect) == (buffer_slot > 0) ||
        throw(
        ArgumentError(
            "buffered stage effects require a positive slot and commit-only " *
                "effects require slot zero"
        )
    )
    return CompiledStageDescriptor{C, V, E, P, A, S}(
        condition,
        value,
        effect,
        stage,
        access,
        support,
        Int32(source_handle),
        Int32(buffer_slot),
    )
end

descriptor_state_requirements(descriptor::CompiledStageDescriptor) =
    descriptor.access.reads
descriptor_workspace_requirements(::CompiledStageDescriptor) = ()
descriptor_resource_access(descriptor::CompiledStageDescriptor) = descriptor.access
descriptor_stage(descriptor::CompiledStageDescriptor) = descriptor.stage
descriptor_role(descriptor::CompiledStageDescriptor) = descriptor.effect
descriptor_dependencies(::CompiledStageDescriptor) = ()
descriptor_support(descriptor::CompiledStageDescriptor) = descriptor.support
descriptor_source_handle(descriptor::CompiledStageDescriptor) =
    descriptor.source_handle
descriptor_checkpoint_policy(::CompiledStageDescriptor) =
    :reconstruct_from_executable
descriptor_checkpoint_encode(::CompiledStageDescriptor) = nothing
descriptor_checkpoint_reconstruct(
    descriptor::CompiledStageDescriptor, ::Nothing
) = descriptor
descriptor_evaluator_node_count(descriptor::CompiledStageDescriptor) =
    evaluator_node_count(descriptor.condition) + evaluator_node_count(descriptor.value)

function _stage_descriptor_handles(descriptor::CompiledStageDescriptor)
    handles = StateHandle[]
    effect = descriptor.effect
    target = effect isa Union{SiteAssignmentEffect, CellAssignmentEffect, ModelAssignmentEffect, IteratedSiteAssignmentEffect} ? effect.target : nothing
    target === nothing || push!(handles, target)
    for handle in descriptor.access.reads
        any(==(handle), handles) || push!(handles, handle)
    end
    return Tuple(handles)
end

descriptor_inspection(descriptor::CompiledStageDescriptor) = (
    source_handle = descriptor.source_handle,
    buffer_slot = descriptor.buffer_slot,
    stage = nameof(typeof(descriptor.stage)),
    effect = nameof(typeof(descriptor.effect)),
    condition = nameof(typeof(descriptor.condition.expression)),
    value = nameof(typeof(descriptor.value.expression)),
)

"""Homogeneous stage descriptors sharing one concrete evaluator/effect schema."""
struct StageDescriptorGroup{D, V <: AbstractVector{D}}
    instances::V
end

"""Ordered accepted-copy and lifecycle-boundary stage groups."""
struct StageExecutionPlan{A <: Tuple, B <: Tuple, L <: Tuple}
    accepted_copy::A
    before_lifecycle::B
    after_lifecycle::L
    accepted_count::Int32
    after_mcs_scratch_count::Int32
    fingerprint::String
end

@inline _after_mcs_groups(plan::StageExecutionPlan) =
    (plan.before_lifecycle..., plan.after_lifecycle...)

function StageExecutionPlan(
        accepted_copy::A,
        before_lifecycle::B,
        after_lifecycle::L,
        accepted_count::Integer,
        after_mcs_scratch_count::Integer,
        fingerprint,
    ) where {A <: Tuple, B <: Tuple, L <: Tuple}
    all(
        group -> group isa StageDescriptorGroup && all(
            descriptor -> descriptor isa CompiledStageDescriptor,
            group.instances,
        ),
        (accepted_copy..., before_lifecycle..., after_lifecycle...),
    ) || throw(
        ArgumentError(
            "stage execution plans admit only compiler-owned CompiledStageDescriptor values"
        )
    )
    accepted_count >= 0 || throw(
        ArgumentError(
            "accepted-copy descriptor count cannot be negative"
        )
    )
    after_mcs_scratch_count >= 0 || throw(
        ArgumentError(
            "after-MCS scratch-buffer count cannot be negative"
        )
    )
    actual_accepted = sum(
        length(group.instances) for group in accepted_copy; init = 0
    )
    actual_accepted == accepted_count || throw(
        ArgumentError(
            "accepted-copy descriptor count does not match its groups"
        )
    )
    any(
        descriptor -> descriptor.effect isa Union{ModelAssignmentEffect, CellAssignmentEffect},
        (descriptor for group in accepted_copy for descriptor in group.instances),
    ) && throw(
        ArgumentError(
            "model and cell assignments are admitted only at the after-MCS boundary"
        )
    )
    after_mcs = (before_lifecycle..., after_lifecycle...)
    model_slots = sort!(
        Int[
            descriptor.buffer_slot
                for group in after_mcs
                for descriptor in group.instances
                if descriptor.effect isa ModelAssignmentEffect
        ]
    )
    model_slots == collect(eachindex(model_slots)) || throw(
        ArgumentError(
            "after-MCS model-assignment buffer slots must be dense and unique"
        )
    )
    cell_slots = sort!(Int[descriptor.buffer_slot for group in after_mcs for descriptor in group.instances if descriptor.effect isa CellAssignmentEffect])
    cell_slots == collect(eachindex(cell_slots)) || throw(ArgumentError("after-MCS cell-assignment buffer slots must be dense and unique"))
    return StageExecutionPlan{A, B, L}(
        accepted_copy,
        before_lifecycle,
        after_lifecycle,
        Int32(accepted_count),
        Int32(after_mcs_scratch_count),
        String(fingerprint),
    )
end


StageExecutionPlan() = StageExecutionPlan(
    (), (), (), 0, 0, "empty-stage-plan-v1"
)

_history_descriptors(plan::StageExecutionPlan) =
    _history_descriptors(Tuple(descriptor for group in _after_mcs_groups(plan) for descriptor in group.instances))
function _history_descriptors(descriptors::Tuple)
    all(descriptor -> descriptor isa CompiledStageDescriptor, descriptors) ||
        throw(ArgumentError("history source queries require compiled stage descriptors"))
    return Tuple(descriptor for descriptor in descriptors if descriptor.effect isa ShiftAppendEffect)
end

function _history_contract(plan, layout::StateLayout, target::StateHandle)
    targets = filter(entry -> entry.handle == target, layout.entries)
    length(targets) == 1 && only(targets).schema.domain === :history ||
        throw(ArgumentError("a history target must be one canonical history layout entry"))
    effects = [
        descriptor.effect for descriptor in _history_descriptors(plan)
            if descriptor.effect.target == target
    ]
    length(effects) == 1 || throw(ArgumentError("a history target requires exactly one shift-append source"))
    effect = only(effects)
    source = effect.source
    entries = filter(entry -> entry.handle == source, layout.entries)
    length(entries) == 1 || throw(ArgumentError("the history source must resolve to one canonical state-layout entry"))
    source_entry = only(entries)
    source_entry.schema.domain in (:model, :cell, :site) ||
        throw(ArgumentError("history requires a canonical model, cell, or site source"))
    target_entry = only(targets)
    source_shape = _history_source_shape(source)
    target_shape = Tuple(target_entry.schema.shape)
    effect.axis == length(target_shape) &&
        length(target_shape) == length(source_shape) + 1 &&
        target_shape[1:(end - 1)] == source_shape && last(target_shape) > 0 ||
        throw(ArgumentError("history samples require a positive dense trailing retention axis over the source domain"))
    target_entry.schema.element_type === source_entry.schema.element_type ||
        throw(ArgumentError("history samples and their source must have the same logical element type"))
    return (; target = target_entry, source = source_entry, effect)
end

"""
    history_source(plan, layout::StateLayout, target::StateHandle)

Return the canonical source layout entry for a dense history target. The unique
`ShiftAppendEffect` is the source authority; the returned entry contains its
existing source `handle` and `schema`, not a separately retained history registry.
An absent or ambiguous history writer, or a source outside `layout`, is invalid.
`plan` is a `StageExecutionPlan` or its already lowered descriptor tuple.
"""
history_source(plan::Union{StageExecutionPlan, Tuple}, layout::StateLayout, target::StateHandle) =
    _history_contract(plan, layout, target).source

"""
    history_sample_handle(plan, layout, history, lag)

Select one retained source-domain sample without copying storage. Zero selects
the newest sample. The history's unique shift-append effect and canonical layout
prove the dense trailing-axis projection. The returned handle is a read view,
not a new writable state declaration. `plan` may be a `StageExecutionPlan` or
the tuple of its already lowered descriptors during compiler construction.
"""
function history_sample_handle(plan::Union{StageExecutionPlan, Tuple}, layout::StateLayout, history::StateHandle, lag::Integer)
    lag isa Bool && throw(ArgumentError("a history lag must be an integer sample index, not Bool"))
    contract = _history_contract(plan, layout, history)
    depth = last(contract.target.schema.shape)
    0 <= lag < depth || throw(ArgumentError("history lag $lag is outside retained sample indices 0:$(depth - 1)"))
    shape = Tuple(contract.source.schema.shape)
    count = prod(BigInt.(shape); init = big(1))
    offset = BigInt(history.location.offset) + (depth - 1 - lag) * count
    1 <= offset <= typemax(Int32) || throw(ArgumentError("history sample offset exceeds the representable storage location"))
    return StateHandle(handle_representation(history), history.bank, history.slot, Int(offset), shape)
end

function _history_read_source(plan, layout::StateLayout, handle::StateHandle)
    parents = filter(layout.entries) do entry
        parent = entry.handle
        entry.schema.domain === :history && parent.bank == handle.bank && parent.slot == handle.slot &&
            handle_representation(parent) === handle_representation(handle)
    end
    length(parents) == 1 || throw(ArgumentError("state read does not identify a declared history sample"))
    parent = only(parents).handle
    contract = _history_contract(plan, layout, parent)
    shape = Tuple(contract.source.schema.shape)
    handle_shape(handle) == shape || throw(ArgumentError("history read must select one complete source-shaped sample"))
    count = prod(BigInt.(shape); init = big(1))
    offset = BigInt(handle.location.offset) - parent.location.offset
    depth = last(contract.target.schema.shape)
    # All valid samples of an empty source share the same empty physical view.
    valid = iszero(count) ? iszero(offset) :
        offset >= 0 && iszero(rem(offset, count)) && div(offset, count) < depth
    valid || throw(ArgumentError("history read is not aligned to a retained whole sample"))
    return contract.source
end

"""Resolve an ordinary state read or a proven history-sample read to its canonical source declaration. This query does not authorize writes through projected handles."""
function state_read_source(plan, layout::StateLayout, handle::StateHandle)
    entries = filter(entry -> entry.handle == handle, layout.entries)
    length(entries) == 1 && return only(entries)
    return _history_read_source(plan, layout, handle)
end

function _validate_state_write_handles(layout::StateLayout, handles, source)
    for handle in handles
        handle isa StateHandle || continue
        any(entry -> entry.handle == handle, layout.entries) ||
            throw(ArgumentError("state write at $source requires a canonical layout handle, not a read-only history sample"))
    end
    return nothing
end

_validate_stage_tracker_anchor(::AbstractStaticExpression, effect, source) = nothing
function _validate_stage_tracker_anchor(expression::OperationExpression, effect, source)
    operation = expression.operation
    source_sum = operation isa ResourceOperation{:cell_site_sum} ||
        (operation isa QualifiedTrackerOperation && operation.operation isa ResourceOperation{:cell_site_sum})
    if source_sum || (effect isa CellAssignmentEffect && operation isa ResourceOperation{:cell_volume})
        effect isa CellAssignmentEffect || throw(ArgumentError("source sum at $source requires a scheduled cell context"))
        !source_sum || operation isa QualifiedTrackerOperation ||
            throw(ArgumentError("source sum at $source requires a compiler-bound tracker key"))
        length(expression.arguments) == 1 &&
            only(expression.arguments) isa ContextExpression{ContextOperation{:energy_anchor_cell}} ||
            throw(ArgumentError("cell tracker read at $source requires the current bound cell"))
    end
    foreach(argument -> _validate_stage_tracker_anchor(argument, effect, source), expression.arguments)
    return nothing
end

function _validate_stage_state_domains(plan::StageExecutionPlan, layout, sources, kind_count, medium_kinds, tracker_plan)
    for group in (plan.accepted_copy..., plan.before_lifecycle..., plan.after_lifecycle...),
            descriptor in group.instances
        source = _descriptor_source(
            sources, descriptor.source_handle;
            descriptor, context = :stage_state_domains
        )
        _validate_model_read_domain(descriptor.condition.expression, layout, nothing, source, plan)
        _validate_model_read_domain(descriptor.value.expression, layout, nothing, source, plan)
        _validate_state_write_handles(layout, descriptor.access.writes, source)
        effect = descriptor.effect
        _validate_stage_tracker_anchor(descriptor.condition.expression, effect, source)
        _validate_stage_tracker_anchor(descriptor.value.expression, effect, source)
        effect isa CellAssignmentEffect && _stage_tracker_descriptors(descriptor, tracker_plan, source)
        effect isa ShiftAppendEffect && _history_contract(plan, layout, effect.target)
        if effect isa Union{SiteAssignmentEffect, IteratedSiteAssignmentEffect, ModelAssignmentEffect, CellAssignmentEffect}
            index = findfirst(entry -> entry.handle == effect.target, layout.entries)
            entry = index === nothing ? nothing : layout.entries[index]
            domain = effect isa ModelAssignmentEffect ? :model :
                effect isa CellAssignmentEffect ? :cell : :site
            entry !== nothing && entry.schema.domain === domain ||
                throw(ArgumentError("stage target at $source requires $domain-owned storage"))
            if domain === :model
                prod(handle_shape(effect.target); init = 1) == 1 ||
                    throw(ArgumentError("model-owned stage target at $source requires one logical value"))
            end
        end
        if effect isa CellAssignmentEffect
            effect.domain_kind <= kind_count && !medium_kinds[effect.domain_kind] ||
                throw(ArgumentError("cell-stage at $source requires a declared finite-cell kind"))
            expression_handles = (expression_state_handles(descriptor.condition.expression)...,
                expression_state_handles(descriptor.value.expression)...)
            all(handle -> any(==(handle), descriptor.access.reads), expression_handles) ||
                throw(ArgumentError("cell-stage at $source reads state absent from its declared access contract"))
            for handle in _stage_descriptor_handles(descriptor)
                entry = state_read_source(plan, layout, handle)
                domain = entry.schema.domain
                domain in (:cell, :model) ||
                    throw(ArgumentError("cell-stage at $source requires cell-owned or model-owned reads, not $domain"))
                domain !== :cell || length(handle_shape(handle)) == 1 ||
                    throw(ArgumentError("cell-stage at $source requires one-dimensional cell state"))
            end
        end
    end
    return nothing
end

struct StageEvaluation{T}
    enabled::Bool
    value::T
end

_state_value_zero(::Type{StageEvaluation{T}}) where {T} =
    StageEvaluation(false, _state_value_zero(T))

mutable struct StageRuntimeBuffers{A, S, M, C, R}
    accepted_copy::A
    after_mcs::S
    after_mcs_model::M
    after_mcs_cell::C
    relationship_transactions::R
end

function _stage_buffer_descriptors(groups, count, predicate)
    descriptors = [descriptor for group in groups for descriptor in group.instances if predicate(descriptor.effect)]
    sort!(descriptors; by = descriptor -> descriptor.buffer_slot)
    [Int(descriptor.buffer_slot) for descriptor in descriptors] == collect(1:count) ||
        throw(ArgumentError("stage buffer slots must be dense and unique within their effect domain"))
    return Tuple(descriptors)
end

_stage_value_type(effect::RelationshipCreateEffect, ::Type{T}) where {T} = T
_stage_value_type(effect, ::Type{T}) where {T} = _stage_handle_element_type(effect.target, T)

_stage_handle_element_type(handle::StateHandle, ::Type{T}) where {T} =
    handle_representation(handle) <: StateStorageRepresentation ?
    _state_handle_element_type(handle) : T

function _stage_evaluation_buffer(descriptor, ::Type{T}) where {T}
    V = _stage_value_type(descriptor.effect, T)
    return Ref(_state_value_zero(StageEvaluation{V}))
end

function allocate_stage_runtime_buffers(
        plan::StageExecutionPlan,
        ::Type{T},
        shape::NTuple{N, Int},
        relationships::RelationshipStorage = RelationshipStorage(()),
        ;
        accepted_batch_bound::Integer = 1,
        accepted_relationship_transactions::Bool = true,
        cell_capacity::Integer = 0,
    ) where {T <: AbstractFloat, N}
    accepted_batch_bound > 0 || throw(
        ArgumentError(
            "accepted-copy batch bound must be positive"
        )
    )
    accepted_descriptors = _stage_buffer_descriptors(plan.accepted_copy, Int(plan.accepted_count), _ -> true)
    accepted = map(descriptor -> _stage_evaluation_buffer(descriptor, T), accepted_descriptors)
    site_descriptors = _stage_buffer_descriptors(_after_mcs_groups(plan), Int(plan.after_mcs_scratch_count), effect -> effect isa Union{SiteAssignmentEffect, IteratedSiteAssignmentEffect})
    after = map(site_descriptors) do descriptor
        V = _stage_value_type(descriptor.effect, T)
        map(_ -> _state_value_zero(StageEvaluation{V}), CartesianIndices(shape))
    end
    model_count = sum(
        (
            1
                for group in _after_mcs_groups(plan)
                for descriptor in group.instances
                if descriptor.effect isa ModelAssignmentEffect
        ); init = 0
    )
    model_descriptors = _stage_buffer_descriptors(_after_mcs_groups(plan), model_count, effect -> effect isa ModelAssignmentEffect)
    after_model = map(descriptor -> _stage_evaluation_buffer(descriptor, T), model_descriptors)
    cell_capacity >= 0 || throw(ArgumentError("cell-stage capacity cannot be negative"))
    cell_count = sum((descriptor.effect isa CellAssignmentEffect for group in _after_mcs_groups(plan) for descriptor in group.instances); init = 0)
    cell_descriptors = _stage_buffer_descriptors(_after_mcs_groups(plan), cell_count, effect -> effect isa CellAssignmentEffect)
    after_cell = map(cell_descriptors) do descriptor
        V = _stage_value_type(descriptor.effect, T)
        fill(_state_value_zero(StageEvaluation{V}), cell_capacity)
    end
    transactions = Any[]
    for store_slot in eachindex(relationships)
        accepted_bound = accepted_relationship_transactions ? sum(
                (
                    1
                    for group in plan.accepted_copy
                    for descriptor in group.instances
                    if descriptor.effect isa RelationshipCreateEffect &&
                    descriptor.effect.relationship_slot == store_slot
                ); init = 0
            ) : 0
        after_bound = sum(
            (
                length(relationships[store_slot].active)
                    for group in _after_mcs_groups(plan)
                    for descriptor in group.instances
                    if descriptor.effect isa Union{
                        RelationshipRemoveEffect, RelationshipRetuneEffect,
                    } &&
                    descriptor.effect.relationship_slot == store_slot
            ); init = 0
        )
        capacity = max(accepted_bound * accepted_batch_bound, after_bound)
        push!(
            transactions,
            iszero(capacity) ? nothing : RelationshipTransactionBuffer(
                    relationships[store_slot], capacity
                ),
        )
    end
    relationship_transactions = all(isnothing, transactions) ? nothing :
        RelationshipStorage(transactions)
    return StageRuntimeBuffers(
        accepted, after, after_model, after_cell, relationship_transactions
    )
end
