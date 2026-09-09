# Site-local contributions and their canonical owner-routed publication.

struct _SiteContributionContext{P, H, V} <: AbstractSiteStageEvaluationContext
    parameters::P
    handles::H
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

function _site_sum_result_access(accepted, handle, live_field, target_relation)
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

function _checkerboard_scalar_tracker_declaration(accepted, field, descriptor::SiteSumTracker,
        owner_capacity, terminal_gate, label)
    handles = expression_state_handles(descriptor.expression)
    fields = map(handles) do handle
        index = findfirst(==(handle), accepted.state_handles)
        index === nothing && throw(ArgumentError("site sum $(descriptor.quantity) source was not gathered"))
        accepted.state_fields[index]
    end
    target_relation = LocalMath.IndexRelation(accepted.target => accepted.lattice_space; optional = false)
    before_reads = map(field -> LocalMath.Access(field, target_relation; required = true), fields)
    after_declarations = map(handles, fields) do handle, live_field
        _site_sum_result_access(accepted, handle, live_field, target_relation)
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
@inline _site_contribution_context(args...) = _SiteContributionContext(args...)

@inline evaluator_parameters(context::_SiteContributionContext) = context.parameters
@inline _compiled_evaluator_parameters(context::_SiteContributionContext) = context.parameters
@inline _proposal_parameters(context::_SiteContributionContext) = context.parameters
@inline stage_site(::IterationStageSite, ::_SiteContributionContext) = Int32(1)
@inline state_value(context::_SiteContributionContext, ::_ExecutableStateReference{I}, site) where {I} =
    getfield(context.values, I)

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
    throw(ArgumentError("site sum at $source requires site-local state/parameter expressions; unsupported $(typeof(expression))"))
end
function _validate_site_contribution_expression(expression::OperationExpression, source)
    operation = expression.operation
    if operation isa BoundStateValueOperation{IterationStageSite}
        length(expression.arguments) == 1 && only(expression.arguments) isa StateExpression ||
            throw(ArgumentError("site sum at $source requires a declared handle in its bound site read"))
        return nothing
    end
    operation isa AbstractContextualOperation && throw(ArgumentError(
        "site sum at $source cannot evaluate $(repr(_contextual_operation_identity(operation))) from a site-local contribution"
    ))
    foreach(argument -> _validate_site_contribution_expression(argument, source), expression.arguments)
    return nothing
end

function _validate_tracker_sources(tracker_plan, descriptor_plan, stage_plan, parameters, shape)
    for descriptor in tracker_instances(tracker_plan)
        descriptor isa SiteSumTracker || continue
        handles = expression_state_handles(descriptor.expression)
        entries = map(handle -> state_read_source(stage_plan, descriptor_plan.state_layout, handle), handles)
        source = (quantity = descriptor.quantity, states = map(entry -> entry.schema.identity, entries))
        _validate_site_contribution_expression(descriptor.expression, source)
        for (handle, entry) in zip(handles, entries)
            entry.schema.domain === :site && Tuple(handle_shape(handle)) == shape || throw(ArgumentError(
                "site sum at $source requires lattice-shaped site source values"
            ))
        end
        count = Ref(0)
        _record_expression_requirements!(StateHandle[], count, descriptor.expression)
        count[] <= length(parameters) || throw(ArgumentError(
            "site sum at $source references an unavailable runtime parameter"
        ))
    end
    return nothing
end

struct _SiteSumRebuildEvaluator{HasParameters, E, H, T}
    expression::E
    handles::H
    zero::T
end

@generated function _site_contribution_values(reads, ::Val{Count}) where {Count}
    return Expr(:tuple, (:(something(@inbounds getfield(reads, $(index + 1))[1].value)) for index in 1:Count)...)
end

@inline function (evaluator::_SiteSumRebuildEvaluator{HasParameters})(item::Int32, reads, parameters) where {HasParameters}
    owner = something(@inbounds getfield(reads, 1)[1].value)
    values = _site_contribution_values(reads, Val(length(evaluator.handles)))
    scientific_parameters = HasParameters ?
        something(@inbounds getfield(reads, length(evaluator.handles) + 2)[1].value) : ()
    context = _site_contribution_context(scientific_parameters, evaluator.handles, values)
    value = owner > 0 ? convert(typeof(evaluator.zero), _execute_proposal_scalar(evaluator.expression, context)) : evaluator.zero
    return (sum = LocalMath.RoutedContribution(owner, value, owner > 0),)
end

function _site_sum_rebuild_declaration(descriptor::SiteSumTracker{T}, shape, owner_count, parameter_type;
        submission_parameters = ()) where {T}
    domain = LocalMath.Space(_CheckerboardStageSiteDomain, Tuple(shape))
    owners = LocalMath.Space(_CheckerboardStageCellDomain, owner_count)
    ownership = LocalMath.Field(domain, Int32)
    handles = expression_state_handles(descriptor.expression)
    fields = map(handle -> LocalMath.Field(domain, _stage_handle_element_type(handle, T)), handles)
    identity = LocalMath.IdentityRelation(domain)
    parameter_count = Ref(0)
    _record_expression_requirements!(StateHandle[], parameter_count, descriptor.expression)
    parameter_field = iszero(parameter_count[]) ? nothing :
        LocalMath.Field(domain, NTuple{parameter_count[], parameter_type})
    parameter_reads = parameter_field === nothing ? NamedTuple() :
        (parameters = LocalMath.Access(parameter_field, identity; required = true),)
    reads = merge((ownership = LocalMath.Access(ownership, identity; required = true),),
        _stage_access_tuple(fields, identity), parameter_reads)
    output = LocalMath.Field(owners, T)
    route = LocalMath.RuntimeRelation(domain => owners; degree_bound = 1, key_type = Int32)
    expression = _compile_stage_expression(descriptor.expression, descriptor.quantity, handles,
        IterationStageSite, AbstractSiteStageEvaluationContext)
    stage = LocalMath.Stage(domain, reads,
        (LocalMath.Publication((LocalMath.FieldPublication(output, route, LocalMath.PublicationValue(:sum)),),
            LocalMath.Reduce(T, _checkerboard_tracker_reduce; maximum = 1,
                seed = LocalMath.IdentitySeed(zero(T)), order = LocalMath.CanonicalLeftFold())),),
        LocalMath.Evaluator(_SiteSumRebuildEvaluator{!iszero(parameter_count[]), typeof(expression), typeof(handles), T}(
                expression, handles, zero(T)), submission_parameters),
        LocalMath.Control(),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__; label = :site_sum_rebuild))
    validation = _checkerboard_tracker_validation(output, T, 1, 1)
    law = validation === nothing ? LocalMath.LocalLaw(stage) :
        LocalMath.sequence(LocalMath.LocalLaw(stage), validation.law)
    return (; law, ownership, handles, fields, output, parameter_field, parameter_count = parameter_count[],
        validation_bindings = validation === nothing ? () : validation.bindings)
end

function _execute_site_sum_rebuild(descriptor, source, cell_kinds;
        backend = KernelAbstractions.CPU(), copy_source = false)
    declaration = _site_sum_rebuild_declaration(descriptor, source.shape, length(cell_kinds), eltype(source.parameters))
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
    prepared = LocalMath.prepare(declaration.law,
        declaration.ownership => source.ownership,
        state_bindings...,
        parameter_bindings...,
        declaration.output => LocalMath.Allocate(zero(eltype(declaration.output))),
        declaration.validation_bindings...;
        backend)
    wait(LocalMath.execute!(prepared))
    return LocalMath.storage(prepared, declaration.output)
end
