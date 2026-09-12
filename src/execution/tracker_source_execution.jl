# Site-local contributions and their canonical owner-routed publication.

struct _SiteContributionContext{P, H, V} <: AbstractSiteStageEvaluationContext
    parameters::P
    handles::H
    values::V
end

struct _BoundSiteContributionContext{P, V} <: AbstractSiteStageEvaluationContext
    parameters::P
    values::V
end

struct _SiteSumOwnershipEvaluator{Name, HasParameters, E, H, T}
    expression::E
    handles::H
    zero::T
end

@inline function (evaluator::_SiteSumOwnershipEvaluator{Name, HasParameters})(item::Int32, reads, parameters) where {Name, HasParameters}
    disposition = something(@inbounds getfield(reads, 1)[1].value)
    old_owner, new_owner = something(@inbounds getfield(reads, 2)[1].value)
    count = length(evaluator.handles)
    before = _checkerboard_terminal_state_values(reads, Val(count), Val(2))
    after = _checkerboard_terminal_state_values(reads, Val(count), Val(2 + count))
    scientific_parameters = HasParameters ?
        something(@inbounds getfield(reads, 3 + 2count)[1].value) : ()
    before_context = _site_contribution_context(scientific_parameters, evaluator.handles, before)
    after_context = _site_contribution_context(scientific_parameters, evaluator.handles, after)
    accepted = disposition == _PROGRAM_CHECKERBOARD_ACCEPTED
    old_value = accepted && old_owner > 0 ?
        convert(typeof(evaluator.zero), _execute_proposal_scalar(evaluator.expression, before_context)) : evaluator.zero
    new_value = accepted && new_owner > 0 ?
        convert(typeof(evaluator.zero), _execute_proposal_scalar(evaluator.expression, after_context)) : evaluator.zero
    return NamedTuple{(Name,)}((
        (_checkerboard_tracker_contribution(old_owner, -old_value, accepted && old_owner > 0),
            _checkerboard_tracker_contribution(new_owner, new_value, accepted && new_owner > 0)),
    ))
end

function _site_tracker_result_access(accepted, handle, live_field, target_relation)
    index = findfirst(==(handle), accepted.accepted_state_handles)
    index === nothing || return (
        access = LocalMath.Access(accepted.state_scratch[index], target_relation; required = true), bindings = ())
    parent_index = findfirst(accepted.history_clear_groups) do group
        group.handle.bank == handle.bank && group.handle.slot == handle.slot
    end
    parent_index === nothing && return (
        access = LocalMath.Access(live_field, target_relation; required = true), bindings = ())
    group = accepted.history_clear_groups[parent_index]
    # The canonical history owner already proved this complete sample handle.
    # Read that same sample from its completed clear shadow through a relation,
    # rather than binding a second aliased state field or clearing it again.
    offset = Int(handle.location.offset) - Int(group.handle.location.offset)
    endpoints = reshape(Int32.(offset .+ (1:prod(accepted.shape))), 1, :)
    sample_relation = LocalMath.FixedRelation(accepted.lattice_space => group.shadow.space; degree = 1)
    relation = LocalMath.compose(target_relation, sample_relation)
    return (access = LocalMath.Access(group.shadow, relation; required = true),
        bindings = (sample_relation => LocalMath.Allocate(endpoints),))
end

function _checkerboard_owner_tracker_declaration(accepted, field, descriptor::SiteSumTracker,
        owner_capacity, terminal_gate, label)
    handles = expression_state_handles(descriptor.expression)
    fields = map(handles) do handle
        index = findfirst(==(handle), accepted.state_handles)
        index === nothing && throw(ArgumentError("site-expression tracker $(descriptor.quantity) source was not gathered"))
        accepted.state_fields[index]
    end
    target_relation = LocalMath.IndexRelation(accepted.target => accepted.lattice_space; optional = false)
    before_reads = map(field -> LocalMath.Access(field, target_relation; required = true), fields)
    after_declarations = map(handles, fields) do handle, live_field
        _site_tracker_result_access(accepted, handle, live_field, target_relation)
    end
    names = (ntuple(index -> Symbol(:before_, index), length(handles))...,
        ntuple(index -> Symbol(:after_, index), length(handles))...)
    state_reads = NamedTuple{names}((before_reads..., map(declaration -> declaration.access, after_declarations)...))
    parameter_reads = accepted.science_parameters === nothing ? NamedTuple() :
        (parameters = LocalMath.Access(accepted.science_parameters, accepted.identity; required = true),)
    reads = merge((
        disposition = LocalMath.Access(accepted.disposition, accepted.identity; required = true),
        owners = LocalMath.Access(accepted.owners, accepted.identity; required = true),
    ), state_reads, parameter_reads)
    expression = _compile_stage_expression(descriptor.expression, descriptor.quantity, handles,
        IterationStageSite, AbstractSiteStageEvaluationContext)
    evaluator = _SiteSumOwnershipEvaluator{label, accepted.science_parameters !== nothing,
        typeof(expression), typeof(handles), eltype(field)}(expression, handles, zero(eltype(field)))
    route = LocalMath.RuntimeRelation(accepted.source_space => field.space; degree_bound = 2, key_type = Int32)
    stage = LocalMath.Stage(accepted.source_space, reads,
        (LocalMath.Publication((LocalMath.FieldPublication(field, route, LocalMath.PublicationValue(label)),),
            LocalMath.Reduce(eltype(field), _checkerboard_tracker_reduce; maximum = 2,
                seed = LocalMath.ExistingSeed(), order = LocalMath.CanonicalLeftFold())),),
        LocalMath.Evaluator(evaluator), LocalMath.Control(; prefix = accepted.batch_size, gate = terminal_gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__; label))
    return (laws = (LocalMath.LocalLaw(stage),),
        bindings = Tuple(binding for declaration in after_declarations for binding in declaration.bindings))
end

# Qualify the concrete construction in typed IR, as with gathered stage contexts.
function _checkerboard_owner_tracker_declaration(
        accepted, field, descriptor::SiteMinimumTracker,
        owner_capacity, terminal_gate, label
    )
    handles = expression_state_handles(descriptor.expression)
    identity = LocalMath.IdentityRelation(accepted.lattice_space)
    sources = map(handles) do handle
        index = findfirst(==(handle), accepted.state_handles)
        index === nothing && throw(ArgumentError("site minimum $(descriptor.quantity) source was not gathered"))
        _site_tracker_result_access(accepted, handle, accepted.state_fields[index], identity)
    end
    state_accesses = NamedTuple{ntuple(index -> Symbol(:state_, index), length(handles))}(
        map(source -> source.access, sources)
    )
    parameter_count = Ref(0)
    _record_expression_requirements!(StateHandle[], parameter_count, descriptor.expression)
    parameter_access, parameter_bindings = if iszero(parameter_count[])
        nothing, ()
    else
        relation = LocalMath.FixedRelation(accepted.lattice_space => accepted.source_space; degree = 1)
        LocalMath.Access(accepted.science_parameters, relation; required = true),
            (relation => LocalMath.Allocate(ones(Int32, 1, prod(accepted.shape))),)
    end
    declaration = _site_tracker_rebuild_declaration(
        descriptor, accepted.shape, owner_capacity, Float32;
        gate = terminal_gate, ownership_field = accepted.ownership_scratch,
        state_accesses, parameter_access, destination = field
    )
    return (
        laws = (declaration.law,), bindings = (
            (binding for source in sources for binding in source.bindings)...,
            parameter_bindings..., declaration.validation_bindings...,
        ),
    )
end

@inline _site_contribution_context(args...) = _SiteContributionContext(args...)

@inline evaluator_parameters(context::_SiteContributionContext) = context.parameters
@inline _compiled_evaluator_parameters(context::_SiteContributionContext) = context.parameters
@inline _proposal_parameters(context::_SiteContributionContext) = context.parameters
@inline stage_site(::IterationStageSite, ::_SiteContributionContext) = Int32(1)
@inline state_value(context::_SiteContributionContext, ::_ExecutableStateReference{I}, site) where {I} =
    getfield(context.values, I)

@inline _proposal_parameters(context::_BoundSiteContributionContext) = context.parameters
@inline _compiled_evaluator_parameters(context::_BoundSiteContributionContext) = context.parameters
@inline evaluator_parameters(context::_BoundSiteContributionContext) = context.parameters
@inline stage_site(::IterationStageSite, ::_BoundSiteContributionContext) = Int32(1)
@inline state_value(context::_BoundSiteContributionContext, ::_ExecutableStateReference{I}, site) where {I} =
    getfield(context.values, I)

@generated function _bound_site_source_values(sources::S, site) where {S <: Tuple}
    return Expr(
        :tuple,
        (:(@inbounds getfield(sources, $index)[site])
         for index in 1:fieldcount(S))...,
    )
end

@generated function _bound_site_parameters(parameters, ::Val{Count}) where {Count}
    return Expr(
        :tuple,
        (:(@inbounds parameters[$index]) for index in 1:Count)...,
    )
end

Base.@noinline function _bound_site_tracker_contribution(
        descriptor::_BoundSiteSumTracker{T}, site,
    ) where {T}
    values = _bound_site_source_values(descriptor.sources, site)
    parameters = _bound_site_parameters(
        descriptor.parameters, descriptor.parameter_count
    )
    context = _BoundSiteContributionContext(parameters, values)
    return convert(T, _execute_proposal_scalar(descriptor.expression, context))
end

Base.@noinline function _site_tracker_contribution(
        descriptor::_BoundSiteSumTracker, site,
    )
    value = _bound_site_tracker_contribution(descriptor, site)
    _state_value_isfinite(value) || throw(ArgumentError(
        "site sum contribution produced a nonfinite value"
    ))
    return value
end

function _bind_site_sum_tracker(descriptor::SiteSumTracker{T}, source) where {T}
    handles = expression_state_handles(descriptor.expression)
    expression = _compile_stage_expression(
        descriptor.expression, descriptor.quantity, handles,
        IterationStageSite, AbstractSiteStageEvaluationContext,
    )
    sources = map(handles) do handle
        state_block(source.descriptor_state, handle).values
    end
    parameter_count = Ref(0)
    _record_expression_requirements!(
        StateHandle[], parameter_count, descriptor.expression
    )
    return _BoundSiteSumTracker(
        descriptor.quantity, expression, sources, source.parameters,
        Val(parameter_count[]), zero(T),
    )
end

_bind_lifecycle_tracker(descriptor, source) = descriptor
_bind_lifecycle_tracker(descriptor::SiteSumTracker, source) =
    _bind_site_sum_tracker(descriptor, source)
function _bind_lifecycle_tracker(group::DenseScalarTrackerGroup, source)
    descriptors = map(
        descriptor -> _bind_lifecycle_tracker(descriptor, source),
        Tuple(group.descriptors),
    )
    return _DenseScalarTrackerKernelGroup(
        group.quantity, descriptors, Tuple(group.source_handles)
    )
end
function _bind_lifecycle_tracker(
        group::_DenseScalarTrackerKernelGroup, source
    )
    return _DenseScalarTrackerKernelGroup(
        group.quantity,
        map(
            descriptor -> _bind_lifecycle_tracker(descriptor, source),
            group.descriptors,
        ),
        group.source_handles,
    )
end

function _bind_lifecycle_tracker_plan(plan::AbstractTrackerPlan, source)
    return TrackerKernelPlan(map(
        descriptor -> _bind_lifecycle_tracker(descriptor, source),
        plan.descriptors,
    ))
end

@inline _lifecycle_tracker_entry_updates_valid(
    ::Tuple{}, ::Tuple{}, target, old_owner,
) = true

@inline function _lifecycle_tracker_entry_updates_valid(
        descriptors::Tuple, values::Tuple, target, old_owner,
    )
    _lifecycle_tracker_entry_update_valid(
        first(descriptors), first(values), target, old_owner,
    ) || return false
    return _lifecycle_tracker_entry_updates_valid(
        Base.tail(descriptors), Base.tail(values), target, old_owner,
    )
end

@inline _lifecycle_tracker_entry_update_valid(
    descriptor::AbstractTrackerPlanEntry, values, target, old_owner,
) = true

@inline function _lifecycle_tracker_entry_update_valid(
        descriptor::_BoundSiteSumTracker,
        values, target, old_owner,
    )
    old_owner > 0 || return true
    amount = _bound_site_tracker_contribution(descriptor, target)
    _state_value_isfinite(amount) || return false
    old_owner <= length(values) || return false
    updated = @inbounds values[Int(old_owner)] - amount
    return _state_value_isfinite(updated)
end

@inline function _lifecycle_tracker_entry_update_valid(
        group::_DenseScalarTrackerKernelGroup,
        values, target, old_owner,
    )
    for column in eachindex(group.descriptors)
        _lifecycle_tracker_entry_update_valid(
            getfield(group.descriptors, column), values, column,
            target, old_owner,
        ) || return false
    end
    return true
end

@inline _lifecycle_tracker_entry_update_valid(
    descriptor::AbstractTrackerDescriptor, values, column,
    target, old_owner,
) = true

@inline function _lifecycle_tracker_entry_update_valid(
        descriptor::_BoundSiteSumTracker,
        values, column, target, old_owner,
    )
    old_owner > 0 || return true
    amount = _bound_site_tracker_contribution(descriptor, target)
    _state_value_isfinite(amount) || return false
    old_owner <= size(values, 1) || return false
    updated = @inbounds values[Int(old_owner), column] - amount
    return _state_value_isfinite(updated)
end

@inline _lifecycle_tracker_completed_updates_valid(
    ::Tuple{}, ::Tuple{}, target, owner,
) = true

@inline function _lifecycle_tracker_completed_updates_valid(
        descriptors::Tuple, values::Tuple, target, owner,
    )
    _lifecycle_tracker_completed_update_valid(
        first(descriptors), first(values), target, owner,
    ) || return false
    return _lifecycle_tracker_completed_updates_valid(
        Base.tail(descriptors), Base.tail(values), target, owner,
    )
end

@inline _lifecycle_tracker_completed_update_valid(
    descriptor::AbstractTrackerPlanEntry, values, target, owner,
) = true

@inline function _lifecycle_tracker_completed_update_valid(
        descriptor::_BoundSiteSumTracker,
        values, target, owner,
    )
    owner > 0 || return true
    owner <= length(values) || return false
    amount = _bound_site_tracker_contribution(descriptor, target)
    _state_value_isfinite(amount) || return false
    updated = @inbounds values[Int(owner)] + amount
    return _state_value_isfinite(updated)
end

@inline function _lifecycle_tracker_completed_update_valid(
        group::_DenseScalarTrackerKernelGroup,
        values, target, owner,
    )
    for column in eachindex(group.descriptors)
        _lifecycle_tracker_completed_update_valid(
            getfield(group.descriptors, column), values, column,
            target, owner,
        ) || return false
    end
    return true
end

@inline _lifecycle_tracker_completed_update_valid(
    descriptor::AbstractTrackerDescriptor, values, column,
    target, owner,
) = true

@inline function _lifecycle_tracker_completed_update_valid(
        descriptor::_BoundSiteSumTracker,
        values, column, target, owner,
    )
    owner > 0 || return true
    owner <= size(values, 1) || return false
    amount = _bound_site_tracker_contribution(descriptor, target)
    _state_value_isfinite(amount) || return false
    updated = @inbounds values[Int(owner), column] + amount
    return _state_value_isfinite(updated)
end

@inline function _tracker_source_entry_delta(
        descriptor::_BoundSiteSumTracker{T}, source, target,
        old_owner, new_owner,
    ) where {T}
    amount = old_owner > 0 ?
        _site_tracker_contribution(descriptor, target) : zero(T)
    return OldNewOwnerValueDelta(-amount, zero(T))
end

@inline function _finish_tracker_source_change!(
        descriptor::_BoundSiteSumTracker,
        values, source, target, old_owner, owner, cell_kinds,
    )
    owner > 0 || return nothing
    amount = _site_tracker_contribution(descriptor, target)
    _validate_owner_index(values, owner)
    @inbounds values[Int(owner)] = _checked_tracker_add(values[Int(owner)], amount)
    return nothing
end

@inline function _site_contribution_state_value(handles::Tuple, values::Tuple, handle)
    first(handles) == handle && return first(values)
    return _site_contribution_state_value(Base.tail(handles), Base.tail(values), handle)
end
@inline _site_contribution_state_value(::Tuple{}, ::Tuple{}, handle) =
    throw(ArgumentError("site contribution read was not declared"))
@inline state_value(context::_SiteContributionContext, handle::StateHandle, site) =
    _site_contribution_state_value(context.handles, context.values, handle)

_validate_site_contribution_expression(::Union{LiteralExpression, ParameterExpression}, source) = nothing
function _validate_site_contribution_expression(expression::AbstractStaticExpression, source)
    throw(ArgumentError("site-expression tracker at $source requires site-local state/parameter expressions; unsupported $(typeof(expression))"))
end
function _validate_site_contribution_expression(expression::OperationExpression, source)
    operation = expression.operation
    if operation isa BoundStateValueOperation{IterationStageSite}
        length(expression.arguments) == 1 && only(expression.arguments) isa StateExpression ||
            throw(ArgumentError("site-expression tracker at $source requires a declared handle in its bound site read"))
        return nothing
    end
    operation isa AbstractContextualOperation && throw(ArgumentError(
            "site-expression tracker at $source cannot evaluate $(repr(_contextual_operation_identity(operation))) from a site-local contribution"
    ))
    foreach(argument -> _validate_site_contribution_expression(argument, source), expression.arguments)
    return nothing
end

_validate_tracker_update_extent(::OldNewOwnerUpdateBound, shape, quantity) = nothing
function _validate_tracker_update_extent(bound::FullLatticeReconstructionUpdateBound, shape, quantity)
    prod(shape) <= bound.maximum_sites || throw(
        ArgumentError(
            "tracker $quantity requires at most $(bound.maximum_sites) sites; lattice has $(prod(shape))"
        )
    )
    return nothing
end

function _validate_tracker_sources(tracker_plan, descriptor_plan, stage_plan, parameters, shape)
    minima = filter(descriptor -> descriptor isa SiteMinimumTracker, tracker_instances(tracker_plan))
    if !isempty(minima)
        for group in descriptor_plan.groups, proposal in group.instances
            keys = Any[]
            _record_tracker_requirements!(keys, proposal.evaluator.expression)
            any(minimum -> any(isequal(minimum.quantity), keys), minima) && throw(
                ArgumentError(
                    "site minimum proposal reads are not admitted; use a published cell-stage value until bounded hypothetical reconstruction is supported"
                )
            )
        end
    end
    for descriptor in tracker_instances(tracker_plan)
        _validate_tracker_update_extent(tracker_contract(descriptor).update_bound, shape, tracker_quantity(descriptor))
        descriptor isa _SiteExpressionTracker || continue
        handles = expression_state_handles(descriptor.expression)
        entries = map(handle -> state_read_source(stage_plan, descriptor_plan.state_layout, handle), handles)
        source = (quantity = descriptor.quantity, states = map(entry -> entry.schema.identity, entries))
        _validate_site_contribution_expression(descriptor.expression, source)
        for (handle, entry) in zip(handles, entries)
            entry.schema.domain === :site && Tuple(handle_shape(handle)) == shape || throw(ArgumentError(
                    "site-expression tracker at $source requires lattice-shaped site source values"
            ))
        end
        count = Ref(0)
        _record_expression_requirements!(StateHandle[], count, descriptor.expression)
        count[] <= length(parameters) || throw(ArgumentError(
                "site-expression tracker at $source references an unavailable runtime parameter"
        ))
    end
    return nothing
end

struct _SiteTrackerRebuildEvaluator{HasParameters, E, H, T}
    expression::E
    handles::H
    zero::T
end

@generated function _site_contribution_values(reads, ::Val{Count}) where {Count}
    return Expr(:tuple, (:(something(@inbounds getfield(reads, $(index + 1))[1].value)) for index in 1:Count)...)
end

@inline function (evaluator::_SiteTrackerRebuildEvaluator{HasParameters})(item::Int32, reads, parameters) where {HasParameters}
    owner = something(@inbounds getfield(reads, 1)[1].value)
    values = _site_contribution_values(reads, Val(length(evaluator.handles)))
    scientific_parameters = HasParameters ?
        something(@inbounds getfield(reads, length(evaluator.handles) + 2)[1].value) : ()
    context = _site_contribution_context(scientific_parameters, evaluator.handles, values)
    value = owner > 0 ? convert(typeof(evaluator.zero), _execute_proposal_scalar(evaluator.expression, context)) : evaluator.zero
    return (value = LocalMath.RoutedContribution(owner, value, owner > 0),)
end

function _site_tracker_rebuild_declaration(
        descriptor::_SiteExpressionTracker, shape, owner_count, parameter_type;
        submission_parameters = (), gate = nothing, ownership_field = nothing,
        state_accesses = nothing, parameter_access = nothing, destination = nothing
    )
    _validate_tracker_update_extent(tracker_contract(descriptor).update_bound, shape, descriptor.quantity)
    T = _site_tracker_value_type(descriptor)
    domain = ownership_field === nothing ? LocalMath.Space(_CheckerboardStageSiteDomain, Tuple(shape)) : ownership_field.space
    owners = destination === nothing ? LocalMath.Space(_CheckerboardStageCellDomain, owner_count) : destination.space
    ownership = ownership_field === nothing ? LocalMath.Field(domain, Int32) : ownership_field
    handles = expression_state_handles(descriptor.expression)
    fields = map(handle -> LocalMath.Field(domain, _stage_handle_element_type(handle, T)), handles)
    identity = LocalMath.IdentityRelation(domain)
    parameter_count = Ref(0)
    _record_expression_requirements!(StateHandle[], parameter_count, descriptor.expression)
    parameter_field = iszero(parameter_count[]) ? nothing :
        LocalMath.Field(domain, NTuple{parameter_count[], parameter_type})
    parameter_reads = parameter_field === nothing ? NamedTuple() :
        (parameters = parameter_access === nothing ? LocalMath.Access(parameter_field, identity; required = true) : parameter_access,)
    reads = merge((ownership = LocalMath.Access(ownership, identity; required = true),),
        state_accesses === nothing ? _stage_access_tuple(fields, identity) : state_accesses, parameter_reads
    )
    output = destination === nothing ? LocalMath.Field(owners, T) : destination
    reduction_output = descriptor isa SiteMinimumTracker ? LocalMath.Field(owners, T) : output
    route = LocalMath.RuntimeRelation(domain => owners; degree_bound = 1, key_type = Int32)
    expression = _compile_stage_expression(descriptor.expression, descriptor.quantity, handles,
        IterationStageSite, AbstractSiteStageEvaluationContext)
    stage = LocalMath.Stage(domain, reads,
        (
            LocalMath.Publication(
                (LocalMath.FieldPublication(reduction_output, route, LocalMath.PublicationValue(:value)),),
                LocalMath.Reduce(
                    T, _site_tracker_reduction(descriptor); maximum = 1,
                    seed = LocalMath.IdentitySeed(_site_tracker_identity(descriptor)), order = LocalMath.CanonicalLeftFold()
                )
            ),
        ),
        LocalMath.Evaluator(
            _SiteTrackerRebuildEvaluator{!iszero(parameter_count[]), typeof(expression), typeof(handles), T}(
                expression, handles, zero(T)), submission_parameters),
        LocalMath.Control(; gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__; label = :site_tracker_rebuild)
    )
    reconstruction = LocalMath.LocalLaw(stage)
    extra_bindings = ()
    if descriptor isa SiteMinimumTracker
        finalization = LocalMath.Stage(
            owners,
            (minimum = LocalMath.Access(reduction_output, LocalMath.IdentityRelation(owners); required = true),),
            (
                LocalMath.Publication(
                    (LocalMath.FieldPublication(output, LocalMath.IdentityRelation(owners), LocalMath.PublicationValue(:value)),),
                    LocalMath.Unique(T; coverage = LocalMath.PartialCoverage(), onempty = LocalMath.FillEmpty(descriptor.empty))
                ),
            ),
            LocalMath.Evaluator(_SiteMinimumFinalize()), LocalMath.Control(; gate),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__; label = :site_minimum_empty_owner)
        )
        reconstruction = LocalMath.sequence(reconstruction, LocalMath.LocalLaw(finalization))
        extra_bindings = (reduction_output => LocalMath.Allocate(zero(T)),)
    end
    # Accepted-copy destinations already belong to a transactional tracker
    # group, which validates the completed scratch exactly once before commit.
    validation = destination === nothing ? _checkerboard_tracker_validation(output, T, 1, 1) : nothing
    law = validation === nothing ? reconstruction : LocalMath.sequence(reconstruction, validation.law)
    return (;
        law, ownership, handles, fields, output, parameter_field, parameter_count = parameter_count[],
        validation_bindings = (extra_bindings..., (validation === nothing ? () : validation.bindings)...),
    )
end

_site_tracker_reduction(::SiteSumTracker) = _checkerboard_tracker_reduce
_site_tracker_reduction(::SiteMinimumTracker) = _site_minimum_reduce
_site_tracker_identity(descriptor::SiteSumTracker) = zero(_site_tracker_value_type(descriptor))
_site_tracker_identity(::SiteMinimumTracker) = Inf32

# The identity is internal only. Every emitted contribution must be finite;
# otherwise preserve invalidity even when a smaller finite value is present.
@inline _site_minimum_reduce(current::Float32, contribution::Float32) =
    isfinite(contribution) ? min(current, contribution) : NaN32

struct _SiteMinimumFinalize end
@inline function (::_SiteMinimumFinalize)(item::Int32, reads, parameters)
    value = something(@inbounds getfield(reads, 1)[1].value)
    return (value = LocalMath.ConditionalUniqueValue(value, value != Inf32),)
end

# Read admission proves history projections; physical parent identity determines
# invalidation. Updating a history's source does not yet update a retained lag.
_same_state_parent(left, right) = left.bank == right.bank && left.slot == right.slot &&
    handle_representation(left) === handle_representation(right)

function _site_tracker_reads_write(descriptor::_SiteExpressionTracker, target, layout, stage_plan)
    return any(expression_state_handles(descriptor.expression)) do handle
        # The returned semantic source is deliberately not the physical parent
        # of a lag read. This call admits the projection; its retained bank/slot
        # identifies the history block whose publication changes that sample.
        state_read_source(stage_plan, layout, handle)
        _same_state_parent(handle, target)
    end
end

function _refresh_published_site_trackers!(runtime, published)
    isempty(published) && return nothing
    program = runtime.program
    source = tracker_source_view(
        program, runtime.ownership;
        parameters = runtime.parameters, descriptor_state = runtime.descriptor_state
    )
    for descriptor in tracker_instances(program.tracker_plan)
        descriptor isa _SiteExpressionTracker || continue
        any(
            target -> _site_tracker_reads_write(
                descriptor, target,
                program.descriptor_plan.state_layout, program.stage_plan
            ), published
        ) || continue
        values = _execute_site_tracker_rebuild(descriptor, source, runtime.cell_kinds)
        copyto!(tracker_values(program.tracker_plan, runtime.trackers, descriptor.quantity), values)
    end
    return nothing
end

function _site_tracker_source_bindings(declaration, source; backend, copy_source = false)
    state_bindings = map(declaration.fields, declaration.handles) do field, handle
        values = state_block(source.descriptor_state, handle).values
        field => (copy_source ? LocalMath.Allocate(values) : values)
    end
    parameter_bindings = if declaration.parameter_field === nothing
        ()
    else
        values = source.parameters
        if KernelAbstractions.get_backend(values) != backend
            # Only the flat candidate input vector crosses the boundary. The
            # existing packed view broadcasts it without a lattice-sized copy.
            values = KernelAbstractions.allocate(backend, eltype(source.parameters), length(source.parameters))
            copyto!(values, source.parameters)
        end
        (declaration.parameter_field => _checkerboard_parameter_view(values,
            Val(declaration.parameter_count), Tuple(source.shape)),)
    end
    return (
        declaration.ownership => source.ownership,
        state_bindings...,
        parameter_bindings...,
    )
end

function _execute_site_tracker_rebuild(
        descriptor, source, cell_kinds;
        backend = KernelAbstractions.CPU(), copy_source = false
    )
    declaration = _site_tracker_rebuild_declaration(descriptor, source.shape, length(cell_kinds), eltype(source.parameters))
    prepared = LocalMath.prepare(
        declaration.law,
        _site_tracker_source_bindings(declaration, source; backend, copy_source)...,
        declaration.output => LocalMath.Allocate(zero(eltype(declaration.output))),
        declaration.validation_bindings...;
        backend)
    wait(LocalMath.execute!(prepared))
    return LocalMath.storage(prepared, declaration.output)
end

function _rebuild_reconstruction_trackers!(plan, state, source, cell_kinds)
    for descriptor in tracker_instances(plan)
        tracker_contract(descriptor).update_bound isa FullLatticeReconstructionUpdateBound || continue
        values = tracker_rebuild(descriptor, source, cell_kinds)
        copyto!(tracker_values(plan, state, tracker_quantity(descriptor)), values)
    end
    return nothing
end

struct _SiteTrackerMutationEvaluator end
@inline _site_tracker_read_pairs_differ(::Tuple{}) = false
@inline function _site_tracker_read_pairs_differ(reads::Tuple{A, B, Vararg}) where {A, B}
    previous = something(@inbounds getfield(reads, 1)[1].value)
    completed = something(@inbounds getfield(reads, 2)[1].value)
    return !isequal(previous, completed) || _site_tracker_read_pairs_differ(Base.tail(Base.tail(reads)))
end
@inline function (::_SiteTrackerMutationEvaluator)(item::Int32, reads, parameters)
    open = something(@inbounds getfield(reads, 1)[1].value)
    changed = open && _site_tracker_read_pairs_differ(Base.tail(reads))
    return (value = LocalMath.RoutedContribution(Int32(1), changed),)
end

function _prepare_lifecycle_site_tracker_snapshot(descriptor, declaration, source, layout, stage_plan, backend, lease_capacity)
    domain = declaration.ownership.space
    previous_ownership = LocalMath.Field(domain, Int32)
    # Both engines stage lifecycle changes in the current transaction bank.
    # Capture its actual boundary entry, not the alternate whole-MCS bank.
    parents = filter(entry -> _site_tracker_reads_write(descriptor, entry.handle, layout, stage_plan), layout.entries)
    parent_sources = map(entry -> LocalMath.Field(LocalMath.Space(Tuple(entry.schema.shape)), entry.schema.element_type), parents)
    parent_snapshots = map(field -> LocalMath.Field(field.space, eltype(field)), parent_sources)
    snapshot_law = LocalMath.sequence(
        _checkerboard_field_copy_law(declaration.ownership, previous_ownership, nothing, :lifecycle_entry_ownership),
        map((current, previous) -> _checkerboard_field_copy_law(current, previous, nothing, :lifecycle_entry_site_source), parent_sources, parent_snapshots)...
    )
    snapshot = LocalMath.prepare(
        snapshot_law,
        declaration.ownership => source.ownership,
        previous_ownership => LocalMath.Allocate(Int32(0)),
        (field => state_block(source.descriptor_state, entry.handle).values for (field, entry) in zip(parent_sources, parents))...,
        (field => LocalMath.Allocate(zero(eltype(field))) for field in parent_snapshots)...;
        backend, lease_capacity
    )
    previous_fields = map(field -> LocalMath.Field(domain, eltype(field)), declaration.fields)
    previous_bindings = map(previous_fields, declaration.handles) do field, handle
        parent_index = only(findall(entry -> _same_state_parent(handle, entry.handle), parents))
        parent = parents[parent_index].handle
        values = BlockView(
            LocalMath.storage(snapshot, parent_snapshots[parent_index]),
            Int(handle.location.offset) - Int(parent.location.offset) + 1, Tuple(handle_shape(handle))
        )
        field => values
    end
    return (; snapshot, previous_ownership, previous_fields, previous_bindings)
end

_execute_lifecycle_site_tracker_snapshot!(prepared) = LocalMath.execute!(prepared.snapshot)

function _prepare_lifecycle_site_trackers(bank, open, backend, lease_capacity, layout, stage_plan)
    workspace = bank.lifecycle_workspace
    source = tracker_source_view(
        bank.program, workspace.staged_ownership;
        parameters = bank.parameters, descriptor_state = workspace.staged_descriptor_state
    )
    descriptors = filter(
        descriptor -> tracker_contract(descriptor).update_bound isa FullLatticeReconstructionUpdateBound,
        tracker_instances(bank.program.tracker_plan)
    )
    return map(descriptors) do descriptor
        gate_space = LocalMath.Space(1)
        external = LocalMath.Field(gate_space, Bool)
        imported = LocalMath.Field(gate_space, Bool)
        gate = LocalMath.Field(gate_space, Bool)
        declaration = _site_tracker_rebuild_declaration(
            descriptor, source.shape,
            length(workspace.staged_cell_kinds), eltype(source.parameters); gate
        )
        domain = declaration.ownership.space
        (; snapshot, previous_ownership, previous_fields, previous_bindings) =
            _prepare_lifecycle_site_tracker_snapshot(descriptor, declaration, source, layout, stage_plan, backend, lease_capacity)
        fields = (
            previous_ownership, declaration.ownership,
            Tuple(field for pair in zip(previous_fields, declaration.fields) for field in pair)...,
        )
        gate_relation = LocalMath.FixedRelation(domain => gate_space; degree = 1)
        reads = merge(
            (open = LocalMath.Access(imported, gate_relation; required = true),),
            _stage_access_tuple(fields, LocalMath.IdentityRelation(domain))
        )
        route = LocalMath.RuntimeRelation(domain => gate_space; degree_bound = 1, key_type = Int32)
        mutation = LocalMath.Stage(
            domain, reads,
            (
                LocalMath.Publication(
                    (LocalMath.FieldPublication(gate, route, LocalMath.PublicationValue(:value)),),
                    LocalMath.Reduce(Bool, |; maximum = 1, seed = LocalMath.IdentitySeed(false), order = LocalMath.CanonicalLeftFold())
                ),
            ),
            LocalMath.Evaluator(_SiteTrackerMutationEvaluator()), LocalMath.Control(),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__; label = :lifecycle_site_source_change)
        )
        # The total mutation publication writes false even for closed planning;
        # no previous submission may leave a stale open reconstruction gate.
        law = LocalMath.sequence(
            LocalMath.LocalLaw(_stage_gate_snapshot(external, imported, :lifecycle_tracker_planning_gate)),
            LocalMath.LocalLaw(mutation), declaration.law
        )
        reconstruction = LocalMath.prepare(
            law,
            external => open, imported => LocalMath.Allocate(false), gate => LocalMath.Allocate(false),
            gate_relation => LocalMath.Allocate(ones(Int32, 1, length(source.ownership))),
            previous_ownership => LocalMath.storage(snapshot, previous_ownership),
            previous_bindings...,
            _site_tracker_source_bindings(declaration, source; backend)...,
            declaration.output => tracker_values(bank.program.tracker_plan, workspace.staged_trackers, descriptor.quantity),
            declaration.validation_bindings...;
            backend, lease_capacity
        )
        (; snapshot, reconstruction)
    end
end
