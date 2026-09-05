# LocalMath topology, bounded gathers, and scientific proposal evaluation.

struct _CheckerboardProposalDomain end
struct _CheckerboardLatticeDomain end
struct _CheckerboardCellDomain end

struct _CheckerboardGeometryEvaluator{N,O}
    shape::NTuple{N,Int}
    periodic::NTuple{N,Bool}
    offsets::O
    trajectory_seed::UInt64
    site_count::Int32
end

@inline function _checkerboard_neighbor_linear(
        shape::NTuple{N,Int},
        periodic::NTuple{N,Bool},
        target_linear::Int32,
        offset::NTuple{N,Int8},
    ) where {N}
    target = CartesianIndices(shape)[Int(target_linear)]
    coordinates = Tuple(target)
    source = ntuple(Val(N)) do dimension
        value = coordinates[dimension] + Int(offset[dimension])
        periodic[dimension] ? mod1(value, shape[dimension]) :
            1 <= value <= shape[dimension] ? value : 0
    end
    any(iszero, source) && return Int32(0)
    return Int32(LinearIndices(shape)[CartesianIndex(source)])
end

@inline function (evaluator::_CheckerboardGeometryEvaluator)(
        item::Int32, reads, parameters,
    )
    target_options = something(@inbounds reads[1][1].value)
    mcs = getfield(parameters, 1)
    color = getfield(parameters, 2)
    attempt_round = getfield(parameters, 3)
    target = @inbounds target_options[color]
    semantic = (attempt_round - Int32(1)) * evaluator.site_count + target
    direction_address = _program_address(
        ProposalDirectionStream, Int(mcs), 2, semantic; subround = color)
    direction = Int(bounded_uint(
        Philox4x32x10V2(), evaluator.trajectory_seed,
        direction_address, UInt32(length(evaluator.offsets)))) + 1
    source = _checkerboard_neighbor_linear(
        evaluator.shape, evaluator.periodic, target,
        getfield(evaluator.offsets, direction))
    priority_address = _program_address(
        CheckerboardPriorityStream, Int(mcs), 4, semantic; subround = color)
    priority = _rng_word(
        Philox4x32x10V2(), evaluator.trajectory_seed, priority_address)
    return (
        target = LocalMath.UniqueValue(target),
        sites = LocalMath.UniqueValue((target, source)),
        semantic = LocalMath.UniqueValue(semantic),
        priority = LocalMath.UniqueValue(priority),
    )
end

function _proposal_offsets_tuple(
        offsets::AbstractMatrix{<:Integer}, dimensions::Integer)
    size(offsets, 1) == dimensions || throw(ArgumentError(
        "proposal offsets do not match the checkerboard dimensionality"))
    size(offsets, 2) > 0 || throw(ArgumentError(
        "proposal geometry requires at least one source offset"))
    size(offsets, 2) <= typemax(UInt32) || throw(ArgumentError(
        "proposal geometry offset count exceeds the semantic RNG bound"))
    return ntuple(size(offsets, 2)) do column
        ntuple(dimensions) do dimension
            value = offsets[dimension, column]
            typemin(Int8) <= value <= typemax(Int8) || throw(ArgumentError(
                "proposal geometry offset exceeds the Int8 execution ABI"))
            Int8(value)
        end
    end
end

_checkerboard_scratch_unique(::Type{T}) where {T} = LocalMath.Unique(
    T; coverage = LocalMath.PartialCoverage(),
    onempty = LocalMath.PreserveEmpty())

function _checkerboard_geometry_declaration(
        plan::CheckerboardPlan,
        proposal_offsets::AbstractMatrix{<:Integer},
        seed::UInt64,
        replica::UInt32,
        repeat::UInt32,
    )
    maximum_batch = Int(plan.maximum_color_size)
    source_space = LocalMath.Space(_CheckerboardProposalDomain, maximum_batch)
    target_options = LocalMath.Field(
        source_space, NTuple{Int(plan.color_count),Int32})
    target = LocalMath.Field(source_space, Int32)
    sites = LocalMath.Field(source_space, NTuple{2,Int32})
    semantic = LocalMath.Field(source_space, Int32)
    priority = LocalMath.Field(source_space, UInt32)
    identity = LocalMath.IdentityRelation(source_space)
    mcs = LocalMath.Parameter(:mcs, Int64;
        bounds = (Int64(1), typemax(Int64)))
    color = LocalMath.Parameter(:color, Int32;
        bounds = (Int32(1), plan.color_count))
    attempt_round = LocalMath.Parameter(:attempt_round, Int32;
        bounds = (Int32(1), typemax(Int32)))
    batch_size = LocalMath.Parameter(:batch_size, Int32;
        bounds = (Int32(0), plan.maximum_color_size))
    evaluator = _CheckerboardGeometryEvaluator(
        plan.shape,
        plan.periodic,
        _proposal_offsets_tuple(proposal_offsets, length(plan.shape)),
        _trajectory_seed(seed, replica, repeat),
        Int32(prod(plan.shape; init = 1)),
    )
    publication(field, name, type) = LocalMath.Publication((
        LocalMath.FieldPublication(
            field, identity, LocalMath.PublicationValue(name)),),
        _checkerboard_scratch_unique(type))
    stage = LocalMath.Stage(
        source_space,
        (target_options = LocalMath.Access(
            target_options, identity; required = true),),
        (
            publication(target, :target, Int32),
            publication(sites, :sites, NTuple{2,Int32}),
            publication(semantic, :semantic, Int32),
            publication(priority, :priority, UInt32),
        ),
        LocalMath.Evaluator(
            evaluator, (mcs, color, attempt_round, batch_size)),
        LocalMath.Control(; prefix = batch_size),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_proposal_geometry),
    )
    law = LocalMath.LocalLaw(stage;
        parameters = LocalMath.ParameterSchema(
            mcs, color, attempt_round, batch_size))
    return (; law, target_options, target, sites, semantic, priority, evaluator,
        source_space, identity, mcs, color, attempt_round, batch_size)
end

struct _CheckerboardOwnerEvaluator end

@inline function (::_CheckerboardOwnerEvaluator)(
        item::Int32, reads, parameters,
    )
    owner_samples = getfield(reads, 1)
    old_owner = something(@inbounds owner_samples[1].value)
    source_sample = @inbounds owner_samples[2]
    new_owner = source_sample.present ? something(source_sample.value) : old_owner
    actionable = source_sample.present && old_owner != new_owner
    raw_priority = something(@inbounds getfield(reads, 2)[1].value)
    return (
        owners = LocalMath.UniqueValue((old_owner, new_owner)),
        priority = LocalMath.UniqueValue(
            actionable ? raw_priority : UInt32(0)),
        actionable = LocalMath.UniqueValue(actionable),
    )
end

function _checkerboard_proposal_topology_declaration(
        plan::CheckerboardPlan,
        proposal_offsets::AbstractMatrix{<:Integer},
        seed::UInt64,
        replica::UInt32,
        repeat::UInt32,
    )
    geometry = _checkerboard_geometry_declaration(
        plan, proposal_offsets, seed, replica, repeat)
    lattice_space = LocalMath.Space(_CheckerboardLatticeDomain, plan.shape)
    ownership = LocalMath.Field(lattice_space, Int32)
    owner_relation = LocalMath.IndexRelation(
        geometry.sites => lattice_space; optional = true)
    owners = LocalMath.Field(geometry.source_space, NTuple{2,Int32})
    actionable = LocalMath.Field(geometry.source_space, Bool)
    publication(field, name, type) = LocalMath.Publication((
        LocalMath.FieldPublication(
            field, geometry.identity, LocalMath.PublicationValue(name)),),
        _checkerboard_scratch_unique(type))
    owner_stage = LocalMath.Stage(
        geometry.source_space,
        (
            ownership = LocalMath.Access(ownership, owner_relation),
            raw_priority = LocalMath.Access(
                geometry.priority, geometry.identity; required = true),
        ),
        (
            publication(owners, :owners, NTuple{2,Int32}),
            publication(geometry.priority, :priority, UInt32),
            publication(actionable, :actionable, Bool),
        ),
        LocalMath.Evaluator(_CheckerboardOwnerEvaluator()),
        LocalMath.Control(; prefix = geometry.batch_size),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_proposal_owners),
    )
    law = LocalMath.sequence(
        geometry.law, LocalMath.LocalLaw(owner_stage))
    return merge(geometry, (;
        law, lattice_space, ownership, owner_relation,
        owners, qualified_priority = geometry.priority, actionable))
end

struct _CheckerboardCellResourceEvaluator end
struct _CheckerboardTrackerResourceEvaluator{Names,Types} end

@generated function (::_CheckerboardTrackerResourceEvaluator{Names,Types})(
        item::Int32, reads, parameters) where {Names,Types}
    results = map(enumerate(Names)) do (index, name)
        T = Types.parameters[index]
        quote
            read = getfield(reads, $index)
            left = @inbounds read[1]
            right = @inbounds read[2]
            LocalMath.UniqueValue((
                left.present ? something(left.value) : zero($T),
                right.present ? something(right.value) : zero($T)))
        end
    end
    return :(NamedTuple{$(QuoteNode(Names))}(($(results...),)))
end

struct _CheckerboardContactGatherEvaluator{Degree} end
struct _CheckerboardReverseContactGatherEvaluator{Degree} end

Base.@noinline function _checkerboard_contact_sample(samples, lane::Int)
    return @inbounds samples[lane]
end

function _checkerboard_contact_result(::Val{Reverse}, ::Val{Degree}) where {Reverse,Degree}
    samples = [gensym(:sample) for _ in 1:Degree]
    loads = [:( $(samples[lane]) =
                    _checkerboard_contact_sample(source, $lane) )
             for lane in 1:Degree]
    owners = Expr(:tuple, (
        :($(samples[lane]).present ?
            something($(samples[lane]).value) : Int32(0))
        for lane in 1:Degree)...)
    sites = Expr(:tuple, (
        :($(samples[lane]).present ?
            $(samples[lane]).endpoint : Int32(0))
        for lane in 1:Degree)...)
    owner_name = Reverse ? :reverse_contact_owners : :contact_owners
    site_name = Reverse ? :reverse_contact_sites : :contact_sites
    result = Reverse ?
        :(($site_name = LocalMath.UniqueValue($sites),
           $owner_name = LocalMath.UniqueValue($owners))) :
        :(($owner_name = LocalMath.UniqueValue($owners),
           $site_name = LocalMath.UniqueValue($sites)))
    return quote
        source = getfield(reads, 1)
        $(loads...)
        $result
    end
end

@generated function (::_CheckerboardContactGatherEvaluator{Degree})(
        item::Int32, reads, parameters) where {Degree}
    return _checkerboard_contact_result(Val(false), Val(Degree))
end

@generated function (::_CheckerboardReverseContactGatherEvaluator{Degree})(
        item::Int32, reads, parameters) where {Degree}
    return _checkerboard_contact_result(Val(true), Val(Degree))
end


struct _CheckerboardContactKindEvaluator{Degree} end
struct _CheckerboardReverseContactKindEvaluator{Degree} end

function _checkerboard_contact_kind_result(
        ::Val{Reverse}, ::Val{Degree}) where {Reverse,Degree}
    samples = [gensym(:sample) for _ in 1:Degree]
    loads = [:( $(samples[lane]) = @inbounds(source[$lane]) )
             for lane in 1:Degree]
    kinds = Expr(:tuple, (
        :($(samples[lane]).present ?
            something($(samples[lane]).value) : Int16(0))
        for lane in 1:Degree)...)
    name = Reverse ? :reverse_contact_kinds : :contact_kinds
    return quote
        source = getfield(reads, 1)
        $(loads...)
        ($name = LocalMath.UniqueValue($kinds),)
    end
end

@generated function (::_CheckerboardContactKindEvaluator{Degree})(
        item::Int32, reads, parameters) where {Degree}
    return _checkerboard_contact_kind_result(Val(false), Val(Degree))
end

@generated function (::_CheckerboardReverseContactKindEvaluator{Degree})(
        item::Int32, reads, parameters) where {Degree}
    return _checkerboard_contact_kind_result(Val(true), Val(Degree))
end

@inline function (::_CheckerboardCellResourceEvaluator)(
        item::Int32, reads, parameters)
    kind_samples = getfield(reads, 1)
    volume_samples = getfield(reads, 2)
    old_sample = @inbounds kind_samples[1]
    new_sample = @inbounds kind_samples[2]
    old_kind = old_sample.present ? something(old_sample.value) : Int16(0)
    new_kind = new_sample.present ? something(new_sample.value) : Int16(0)
    old_volume_sample = @inbounds volume_samples[1]
    new_volume_sample = @inbounds volume_samples[2]
    old_volume = old_volume_sample.present ?
        something(old_volume_sample.value) : Int32(0)
    new_volume = new_volume_sample.present ?
        something(new_volume_sample.value) : Int32(0)
    return (
        kinds = LocalMath.UniqueValue((old_kind, new_kind)),
        volumes = LocalMath.UniqueValue((old_volume, new_volume)),
    )
end

struct _CheckerboardProposalContextPlan{
        N,Handles,Ranges,TrackerDescriptors,MomentDescriptor,
        RelationshipSchemas,
    }
    shape::NTuple{N,Int}
    trajectory_seed::UInt64
    state_handles::Handles
    contact_ranges::Ranges
    tracker_descriptors::TrackerDescriptors
    moment_descriptor::MomentDescriptor
    relationship_schemas::RelationshipSchemas
end

struct _CheckerboardScientificEvaluator{
        T,Degree,HasParameters,Terms,Accepted,Relationships,
        SiteNames,RelationshipNames,Context,
    }
    context::Context
    terms::Terms
    accepted_site_terms::Accepted
    accepted_relationship_terms::Relationships
end

struct _CheckerboardConstraintEvaluator{
        T,Degree,HasParameters,Terms,Context,
    }
    context::Context
    terms::Terms
end

const _ACCEPTED_SITE_DISABLED = UInt8(0x00)
const _ACCEPTED_SITE_READY = UInt8(0x01)
const _ACCEPTED_SITE_INVALID_CONDITION = UInt8(0x02)
const _ACCEPTED_SITE_INVALID_VALUE = UInt8(0x03)

@inline _evaluate_accepted_site_terms(
    ::Tuple{}, context, ::Type{T}) where {T<:AbstractFloat} = ()
@inline function _evaluate_accepted_site_terms(
        terms::Tuple, context, ::Type{T}) where {T<:AbstractFloat}
    term = first(terms)
    condition = _execute_proposal_scalar(term.condition, context)
    code, value = if !(condition isa Bool)
        (_ACCEPTED_SITE_INVALID_CONDITION, zero(T))
    elseif !condition
        (_ACCEPTED_SITE_DISABLED, zero(T))
    else
        value = T(_execute_proposal_scalar(term.value, context))
        isfinite(value) ? (_ACCEPTED_SITE_READY, value) :
            (_ACCEPTED_SITE_INVALID_VALUE, zero(T))
    end
    return (code, value,
        _evaluate_accepted_site_terms(Base.tail(terms), context, T)...)
end

@inline _disabled_accepted_site_terms(
    ::Tuple{}, ::Type{T}) where {T<:AbstractFloat} = ()
@inline function _disabled_accepted_site_terms(
        terms::Tuple, ::Type{T}) where {T<:AbstractFloat}
    return (_ACCEPTED_SITE_DISABLED, zero(T),
        _disabled_accepted_site_terms(Base.tail(terms), T)...)
end

const _ACCEPTED_RELATIONSHIP_DISABLED = UInt8(0x00)
const _ACCEPTED_RELATIONSHIP_READY = UInt8(0x01)
const _ACCEPTED_RELATIONSHIP_INVALID_CONDITION = UInt8(0x02)
const _ACCEPTED_RELATIONSHIP_INVALID_VALUE = UInt8(0x03)

@inline _execute_accepted_relationship_payload(::Tuple{}, context) = ()
@inline function _execute_accepted_relationship_payload(
        payload::Tuple, context)
    return (_execute_proposal_scalar(first(payload), context),
        _execute_accepted_relationship_payload(Base.tail(payload), context)...)
end

@inline function _evaluate_accepted_relationship_term(term, context)
    condition = _execute_proposal_scalar(term.condition, context)
    condition isa Bool || return (
        _ACCEPTED_RELATIONSHIP_INVALID_CONDITION,
        Int32(0), Int32(0), term.payload_zero...)
    condition || return (
        _ACCEPTED_RELATIONSHIP_DISABLED,
        Int32(0), Int32(0), term.payload_zero...)
    valid_a, endpoint_a = _checkerboard_endpoint_value(
        _execute_proposal_scalar(term.endpoint_a, context))
    valid_b, endpoint_b = _checkerboard_endpoint_value(
        _execute_proposal_scalar(term.endpoint_b, context))
    payload = _execute_accepted_relationship_payload(term.payload, context)
    valid_payload, converted_payload = _checkerboard_payload_values(
        term.payload_zero, payload)
    code = valid_a & valid_b & valid_payload ?
        _ACCEPTED_RELATIONSHIP_READY :
        _ACCEPTED_RELATIONSHIP_INVALID_VALUE
    return (code, endpoint_a, endpoint_b, converted_payload...)
end

@inline _evaluate_accepted_relationship_terms(::Tuple{}, context) = ()
@inline function _evaluate_accepted_relationship_terms(terms::Tuple, context)
    return (_evaluate_accepted_relationship_term(first(terms), context)...,
        _evaluate_accepted_relationship_terms(Base.tail(terms), context)...)
end

@inline _disabled_accepted_relationship_terms(::Tuple{}) = ()
@inline function _disabled_accepted_relationship_terms(terms::Tuple)
    term = first(terms)
    return (_ACCEPTED_RELATIONSHIP_DISABLED,
        Int32(0), Int32(0), term.payload_zero...,
        _disabled_accepted_relationship_terms(Base.tail(terms))...)
end

@inline function _checkerboard_scientific_result(evaluation, ::Tuple{})
    return (
        delta_h = LocalMath.UniqueValue(evaluation.delta_h),
        drive_energy = LocalMath.UniqueValue(evaluation.drive_energy),
        drive_log_bias = LocalMath.UniqueValue(evaluation.drive_log_bias),
        kinetic_modifier = LocalMath.UniqueValue(evaluation.kinetic_modifier),
    )
end

@generated function _accepted_site_scientific_result(
        ::Val{Names}, ::Terms, evaluations::Tuple,
    ) where {Names,Terms<:Tuple}
    values = Expr[]
    for index in 1:fieldcount(Terms)
        push!(values, :(LocalMath.UniqueValue(
            getfield(evaluations, $(2index - 1)))))
        push!(values, :(LocalMath.UniqueValue(
            getfield(evaluations, $(2index)))))
    end
    return :(NamedTuple{$(QuoteNode(Names))}(($(values...),)))
end

@generated function _accepted_relationship_scientific_result(
        ::Val{Names}, ::Terms, evaluations::Tuple,
    ) where {Names,Terms<:Tuple}
    values = Expr[]
    offset = 1
    for term_type in Terms.parameters
        payload_type = term_type.parameters[5]
        push!(values, :(LocalMath.UniqueValue(
            getfield(evaluations, $offset))))
        push!(values, :(LocalMath.UniqueValue((
            getfield(evaluations, $(offset + 1)),
            getfield(evaluations, $(offset + 2)),
        ))))
        for payload in 1:fieldcount(payload_type)
            push!(values, :(LocalMath.UniqueValue(
                getfield(evaluations, $(offset + 2 + payload)))))
        end
        offset += 3 + fieldcount(payload_type)
    end
    return :(NamedTuple{$(QuoteNode(Names))}(($(values...),)))
end

@inline function _checkerboard_scientific_result(
        evaluation, accepted_site_terms::Tuple,
        accepted_site_evaluations::Tuple, site_names,
        accepted_relationship_terms::Tuple,
        accepted_relationship_evaluations::Tuple,
        relationship_names,
    )
    base = _checkerboard_scientific_result(evaluation, ())
    sites = _accepted_site_scientific_result(
        site_names, accepted_site_terms, accepted_site_evaluations)
    relationships = _accepted_relationship_scientific_result(
        relationship_names, accepted_relationship_terms,
        accepted_relationship_evaluations)
    return merge(base, sites, relationships)
end

struct _CheckerboardParameterView{
        N,T,A<:AbstractVector{T},
    } <: AbstractVector{NTuple{N,T}}
    values::A
    extent::Int
end

struct _GatheredRelationshipSchema{P,D,N}
    handle::Int32
    edge_offset::Int32
end

struct _GatheredRelationshipReads{A,EA,EB,P,V,MF,MS}
    handle::Int32
    edge_offset::Int32
    active::A
    endpoint_a::EA
    endpoint_b::EB
    payload::P
    endpoint_volumes::V
    moment_first::MF
    moment_second::MS
end

@generated function _gathered_relationship_reads(arguments...)
    length(arguments) == 9 || error(
        "gathered relationship construction schema changed")
    relationship_type = _GatheredRelationshipReads{arguments[3:9]...}
    values = (:(getfield(arguments, $index)) for index in 1:9)
    return :($relationship_type($(values...)))
end

struct _CheckerboardRelationshipEndpointKeyEvaluator{D} end

struct _CheckerboardRelationshipEdgeKeyEvaluator{D}
    edge_offset::Int32
end

@inline function _checkerboard_relationship_edge_key(
        sample, offset::Int32)
    sample.present || return Int32(0)
    sample.value === nothing && return Int32(0)
    value = Int32(something(sample.value))
    return value > 0 ? offset + value - Int32(1) : Int32(0)
end

@generated function (
        evaluator::_CheckerboardRelationshipEdgeKeyEvaluator{D})(
        item::Int32, reads, parameters) where {D}
    keys = Expr(:tuple, (
        :(_checkerboard_relationship_edge_key(
            @inbounds(getfield(reads, 1)[$lane]),
            evaluator.edge_offset)) for lane in 1:D)...)
    return :((edge_keys = LocalMath.UniqueValue($keys),))
end

@inline _checkerboard_relationship_endpoint_key(sample) =
    sample.present ? Int32(something(sample.value)) : Int32(0)

@generated function (
        ::_CheckerboardRelationshipEndpointKeyEvaluator{D})(
        item::Int32, reads, parameters) where {D}
    keys = Expr(:tuple)
    for lane in 1:D
        push!(keys.args, :(_checkerboard_relationship_endpoint_key(
            @inbounds getfield(reads, 1)[$lane])))
        push!(keys.args, :(_checkerboard_relationship_endpoint_key(
            @inbounds getfield(reads, 2)[$lane])))
    end
    return :((endpoint_keys = LocalMath.UniqueValue($keys),))
end

function _checkerboard_relationship_science_declarations(
        handles::Tuple,
        source_space::LocalMath.Space,
        batch_size::LocalMath.Parameter,
        cell_space::LocalMath.Space,
        cell_volumes::LocalMath.Field,
        owner_relation::LocalMath.Relation,
        moment_source_fields::Tuple,
        moment_descriptor,
        bank_field_authorities::Tuple,
        domain_resources::HamiltonianDomainResources,
        relationship_schemas::RelationshipStorage,
        relationship_state::RelationshipStorage)
    return Tuple(map(handles) do handle
        storage_slot = _relationship_domain_slot(domain_resources, handle)
        1 <= storage_slot <= length(relationship_state) || throw(ArgumentError(
            "checkerboard relationship-energy handle is outside packed storage"))
        schema_location = _relationship_location(
            relationship_schemas, Int(storage_slot))
        # The host schema is the location authority. Adapted runtime slot
        # tables may live on the device and are never scalar-indexed cold.
        state_location = schema_location
        bank = relationship_state.banks[Int(state_location.bank)]
        bank isa PackedRelationshipBank || throw(ArgumentError(
            "checkerboard relationship energy requires packed storage"))
        schema_bank = relationship_schemas.banks[Int(schema_location.bank)]
        schema = schema_bank[Int(schema_location.slot)]
        edge_offsets, _ = _relationship_offsets(
            map(entry -> entry.capacity, schema_bank))
        incident_offsets, _ = _relationship_offsets(map(
            entry -> length(cell_space) * Int(entry.maximum_degree),
            schema_bank))
        edge_offset = edge_offsets[Int(schema_location.slot)]
        incident_offset = incident_offsets[Int(schema_location.slot)]
        maximum_degree = Int(schema.maximum_degree)
        selected_degree = 2maximum_degree
        bank_fields = bank_field_authorities[Int(state_location.bank)]
        incident_slot_relation = LocalMath.FixedRelation(
            cell_space => bank_fields.incident_edges.space;
            degree = maximum_degree)
        incidence = LocalMath.SelectedRelation(
            incident_slot_relation, owner_relation)
        edge_keys = LocalMath.Field(
            source_space, NTuple{selected_degree,Int32})
        edge_relation = LocalMath.IndexRelation(
            edge_keys => bank_fields.active.space; optional = true)
        endpoint_keys = LocalMath.Field(
            source_space, NTuple{2selected_degree,Int32})
        endpoint_relation = LocalMath.IndexRelation(
            endpoint_keys => cell_space; optional = true)
        payload = ntuple(length(schema.payload_defaults)) do index
            getfield(bank_fields, 5 + index)
        end
        fields = (
            active = bank_fields.active,
            endpoint_a = bank_fields.endpoint_a,
            endpoint_b = bank_fields.endpoint_b,
            payload,
        )
        edge_stage = LocalMath.Stage(
            source_space,
            (incident_edges = LocalMath.Access(
                bank_fields.incident_edges, incidence),),
            (LocalMath.Publication((LocalMath.FieldPublication(
                edge_keys, LocalMath.IdentityRelation(source_space),
                LocalMath.PublicationValue(:edge_keys)),),
        _checkerboard_scratch_unique(NTuple{selected_degree,Int32})),),
            LocalMath.Evaluator(
                _CheckerboardRelationshipEdgeKeyEvaluator{selected_degree}(
                    edge_offset)),
            LocalMath.Control(; prefix = batch_size),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__;
                label = :checkerboard_relationship_edge_keys),
        )
        endpoint_stage = LocalMath.Stage(
            source_space,
            (endpoint_a = LocalMath.Access(fields.endpoint_a, edge_relation),
             endpoint_b = LocalMath.Access(fields.endpoint_b, edge_relation)),
            (LocalMath.Publication((LocalMath.FieldPublication(
                endpoint_keys, LocalMath.IdentityRelation(source_space),
                LocalMath.PublicationValue(:endpoint_keys)),),
        _checkerboard_scratch_unique(NTuple{2selected_degree,Int32})),),
            LocalMath.Evaluator(
                _CheckerboardRelationshipEndpointKeyEvaluator{
                    selected_degree}()),
            LocalMath.Control(; prefix = batch_size),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__;
                label = :checkerboard_relationship_endpoint_keys),
        )
        dimensions = moment_descriptor === nothing ? 0 :
            typeof(moment_descriptor).parameters[1]
        (; handle, storage_slot, state_location, maximum_degree,
            incident_offset,
            incident_slot_relation, incidence, edge_keys, edge_relation,
            edge_stage, fields, endpoint_keys, endpoint_relation,
            endpoint_stage, incident_edges_field = bank_fields.incident_edges,
            cell_volumes,
            moment_source_fields,
            schema = _GatheredRelationshipSchema{
                length(fields.payload),selected_degree,dimensions}(
                    handle, edge_offset))
    end)
end

function _checkerboard_relationship_science_reads(declarations::Tuple)
    names = Symbol[]
    reads = Any[]
    for (ordinal, declaration) in enumerate(declarations)
        prefix = Symbol(:proposal_relationship_, ordinal)
        push!(names, Symbol(prefix, :_active))
        push!(reads, LocalMath.Access(
            declaration.fields.active, declaration.edge_relation))
        push!(names, Symbol(prefix, :_endpoint_a))
        push!(reads, LocalMath.Access(
            declaration.fields.endpoint_a, declaration.edge_relation))
        push!(names, Symbol(prefix, :_endpoint_b))
        push!(reads, LocalMath.Access(
            declaration.fields.endpoint_b, declaration.edge_relation))
        for (payload_index, field) in enumerate(declaration.fields.payload)
            push!(names, Symbol(prefix, :_payload_, payload_index))
            push!(reads, LocalMath.Access(field, declaration.edge_relation))
        end
        push!(names, Symbol(prefix, :_endpoint_volumes))
        push!(reads, LocalMath.Access(
            declaration.cell_volumes, declaration.endpoint_relation))
        for (moment_index, field) in enumerate(
                declaration.moment_source_fields)
            push!(names, Symbol(prefix, :_endpoint_moment_, moment_index))
            push!(reads, LocalMath.Access(field, declaration.endpoint_relation))
        end
    end
    return NamedTuple{Tuple(names)}(Tuple(reads))
end

@generated function _checkerboard_relationship_read_count(
        ::Schemas) where {Schemas<:Tuple}
    count = sum(begin
            payload_count, _, dimensions = schema_type.parameters
            4 + payload_count + dimensions + dimensions * dimensions
        end for schema_type in Schemas.parameters; init = 0)
    return :($count)
end

@inline _checkerboard_materialize_read(read, ::Val{0}, lane::Int) = ()
@inline function _checkerboard_materialize_read(
        read, ::Val{N}, lane::Int = 1) where {N}
    return (
        @inbounds(read[lane]),
        _checkerboard_materialize_read(read, Val(N - 1), lane + 1)...,
    )
end

@inline _checkerboard_relationship_payload(
    reads, ::Val{0}, degree::Val, ::Val{Offset},
) where {Offset} = ()
@inline function _checkerboard_relationship_payload(
        reads, ::Val{P}, degree::Val, ::Val{Offset},
    ) where {P,Offset}
    return (
        _checkerboard_materialize_read(
            getfield(reads, Offset + 4), degree),
        _checkerboard_relationship_payload(
            reads, Val(P - 1), degree, Val(Offset + 1))...,
    )
end

@generated function _checkerboard_materialize_components(
        reads, ::Val{Count}, degree::Val, ::Val{Index},
    ) where {Count,Index}
    values = Expr(:tuple, (
        :(_checkerboard_materialize_read(
            getfield(reads, $(Index + component - 1)), degree))
        for component in 1:Count)...)
    return Expr(:block, Expr(:meta, :inline), values)
end

@inline _checkerboard_scientific_relationships(
    reads, ::Tuple{}, moment_descriptor, offset,
) = ()
@inline function _checkerboard_scientific_relationships(
        reads,
        schemas::Tuple{_GatheredRelationshipSchema{P,D,N},Vararg},
        moment_descriptor,
        ::Val{Offset},
    ) where {P,D,N,Offset}
    schema = first(schemas)
    degree = Val(D)
    endpoint_degree = Val(2D)
    moments = _checkerboard_materialize_components(
        reads, Val(N + N * N), endpoint_degree, Val(Offset + 5 + P))
    moment_first, moment_second = _checkerboard_split_moment_values(
        moments, moment_descriptor)
    resource = _gathered_relationship_reads(
        schema.handle,
        schema.edge_offset,
        _checkerboard_materialize_read(
            getfield(reads, Offset + 1), degree),
        _checkerboard_materialize_read(
            getfield(reads, Offset + 2), degree),
        _checkerboard_materialize_read(
            getfield(reads, Offset + 3), degree),
        _checkerboard_relationship_payload(
            reads, Val(P), degree, Val(Offset)),
        _checkerboard_materialize_read(
            getfield(reads, Offset + 4 + P), endpoint_degree),
        moment_first,
        moment_second,
    )
    return (
        resource,
        _checkerboard_scientific_relationships(
            reads, Base.tail(schemas), moment_descriptor,
            Val(Offset + 4 + P + N + N * N))...,
    )
end

function _checkerboard_parameter_view(
        values::AbstractVector{T}, ::Val{N}, extent::Integer,
    ) where {T,N}
    length(values) >= N || throw(ArgumentError(
        "checkerboard parameter storage is shorter than its compiled schema"))
    extent >= 0 || throw(ArgumentError(
        "checkerboard parameter view extent cannot be negative"))
    return _CheckerboardParameterView{N,T,typeof(values)}(
        values, Int(extent))
end

Base.IndexStyle(::Type{<:_CheckerboardParameterView}) = IndexLinear()
Base.size(view::_CheckerboardParameterView) = (view.extent,)
Base.length(view::_CheckerboardParameterView) = view.extent
Base.strides(::_CheckerboardParameterView) = (1,)
@inline function Base.getindex(
        view::_CheckerboardParameterView{N}, index::Int,
    ) where {N}
    @boundscheck checkbounds(view, index)
    return ntuple(N) do slot
        @inbounds view.values[slot]
    end
end
KernelAbstractions.get_backend(view::_CheckerboardParameterView) =
    KernelAbstractions.get_backend(view.values)
Adapt.adapt_structure(to, view::_CheckerboardParameterView{N}) where {N} =
    _checkerboard_parameter_view(
        Adapt.adapt(to, view.values), Val(N), view.extent)

@inline _checkerboard_cartesian_site(
    shape::NTuple{1,<:Integer}, linear::Int32,
) = CartesianIndex(linear)
@inline function _checkerboard_cartesian_site(
        shape::NTuple{2,<:Integer}, linear::Int32)
    offset = linear - Int32(1)
    first = rem(offset, Int32(shape[1])) + Int32(1)
    second = div(offset, Int32(shape[1])) + Int32(1)
    return CartesianIndex(first, second)
end
@inline function _checkerboard_cartesian_site(
        shape::NTuple{3,<:Integer}, linear::Int32)
    offset = linear - Int32(1)
    first_extent = Int32(shape[1])
    second_extent = Int32(shape[2])
    first = rem(offset, first_extent) + Int32(1)
    plane_offset = div(offset, first_extent)
    second = rem(plane_offset, second_extent) + Int32(1)
    third = div(plane_offset, second_extent) + Int32(1)
    return CartesianIndex(first, second, third)
end
@generated function _checkerboard_scientific_gathers(
        reads::R, ::Val{Count}, ::Val{Offset}, ::Val{Degree},
    ) where {R,Count,Offset,Degree}
    records = Expr[]
    for index in 1:Count
        read = gensym(:site_read)
        target = gensym(:target_value)
        source = gensym(:source_value)
        contact_read = gensym(:contact_read)
        reverse_read = gensym(:reverse_read)
        affected_read = gensym(:affected_read)
        push!(records, quote
            $read = getfield(reads, $(index + Offset))
            $target = something(@inbounds($read[1].value))
            $source = something(@inbounds($read[2].value), $target)
            $contact_read = $(iszero(Degree) ? :(nothing) :
                :(getfield(reads, $(Offset + Count + index))))
            $reverse_read = $(iszero(Degree) ? :(nothing) :
                :(getfield(reads, $(Offset + 2 * Count + index))))
            $affected_read = $(iszero(Degree) ? :(nothing) :
                :(getfield(reads, $(Offset + 3 * Count + index))))
            (sites = ($target, $source),
                contacts = $(iszero(Degree) ? :(()) : contact_read),
                reverse_contacts = $(iszero(Degree) ? :(()) : reverse_read),
                affected_contacts = $(iszero(Degree) ? :(()) : affected_read))
        end)
    end
    return Expr(:tuple, records...)
end

@generated function _checkerboard_scientific_tracker_values(
        reads, ::Val{Count}, ::Val{Offset}) where {Count,Offset}
    return Expr(:tuple, (
        :(something(@inbounds getfield(reads, $(Offset + index))[1].value))
        for index in 1:Count)...)
end

@generated function _checkerboard_scientific_moment_values(
        reads, ::Val{Count}, ::Val{Offset}, ::Type{T}) where {Count,Offset,T}
    return Expr(:tuple, (
        quote
            local read = getfield(reads, $(Offset + index))
            local left = @inbounds read[1]
            local right = @inbounds read[2]
            (
                left.present ? something(left.value) : zero($T),
                right.present ? something(right.value) : zero($T),
            )
        end for index in 1:Count)...)
end

@generated function _checkerboard_split_moment_values(
        values::Tuple, ::CellMomentsTracker{N}) where {N}
    first = Expr(:tuple, (:(getfield(values, $index)) for index in 1:N)...)
    second = Expr(:tuple, (
        :(getfield(values, $(N + index))) for index in 1:(N * N))...)
    return :(($first, $second))
end

@inline _checkerboard_split_moment_values(values::Tuple, ::Nothing) = ((), ())

@inline _checkerboard_scientific_moments(
    reads, ::Nothing, ::Val,
) = ((), ())
@generated function _checkerboard_scientific_moments(
        reads, descriptor::CellMomentsTracker{N,T},
        ::Val{Offset}) where {N,T,Offset}
    count = N + N * N
    values = :(_checkerboard_scientific_moment_values(
        reads, Val($count), Val($Offset), $T))
    return :(_checkerboard_split_moment_values($values, descriptor))
end

_checkerboard_moment_component_count(::Nothing) = 0
_checkerboard_moment_component_count(::CellMomentsTracker{N}) where {N} =
    N + N * N


@inline _checkerboard_scientific_parameters(reads, ::Val{false}) = ()
@inline _checkerboard_scientific_parameters(reads, ::Val{true}) =
    something(@inbounds getfield(reads, 7)[1].value)

@generated function _checkerboard_scientific_contact(
        reads, ::Val{Degree}, ::Val{HasParameters},
    ) where {Degree,HasParameters}
    iszero(Degree) && return :(((), (), (), (), (), ()))
    offset = HasParameters ? 1 : 0
    return quote
        (
            something(@inbounds getfield(reads, $(7 + offset))[1].value),
            something(@inbounds getfield(reads, $(8 + offset))[1].value),
            something(@inbounds getfield(reads, $(9 + offset))[1].value),
            something(@inbounds getfield(reads, $(10 + offset))[1].value),
            something(@inbounds getfield(reads, $(11 + offset))[1].value),
            something(@inbounds getfield(reads, $(12 + offset))[1].value),
        )
    end
end

@inline function _checkerboard_proposal_context(
        plan::_CheckerboardProposalContextPlan, reads, parameters,
        ::Type{T}, ::Val{Degree}, ::Val{HasParameters},
    ) where {T,Degree,HasParameters}
    sites = something(@inbounds getfield(reads, 1)[1].value)
    owners = something(@inbounds getfield(reads, 2)[1].value)
    kinds = something(@inbounds getfield(reads, 3)[1].value)
    volumes = something(@inbounds getfield(reads, 4)[1].value)
    actionable = something(@inbounds getfield(reads, 5)[1].value)
    semantic = something(@inbounds getfield(reads, 6)[1].value)
    science_parameters = _checkerboard_scientific_parameters(
        reads, Val(HasParameters))
    contact_sites, contact_owners, contact_kinds,
    reverse_contact_sites, reverse_contact_owners, reverse_contact_kinds =
        _checkerboard_scientific_contact(
            reads, Val(Degree), Val(HasParameters))
    tracker_values = _checkerboard_scientific_tracker_values(
        reads, Val(length(plan.tracker_descriptors)),
        Val(6 + (HasParameters ? 1 : 0) + (iszero(Degree) ? 0 : 6)))
    tracker_offset = 6 + (HasParameters ? 1 : 0) +
        (iszero(Degree) ? 0 : 6)
    moment_first, moment_second = _checkerboard_scientific_moments(
        reads, plan.moment_descriptor,
        Val(tracker_offset + length(plan.tracker_descriptors)))
    relationship_offset = tracker_offset +
        length(plan.tracker_descriptors) +
        _checkerboard_moment_component_count(plan.moment_descriptor)
    relationship_resources = _checkerboard_scientific_relationships(
        reads, plan.relationship_schemas, plan.moment_descriptor,
        Val(relationship_offset))
    state_values = _checkerboard_scientific_gathers(
        reads, Val(length(plan.state_handles)),
        Val(6 + (HasParameters ? 1 : 0) + (iszero(Degree) ? 0 : 6) +
            length(plan.tracker_descriptors) +
            _checkerboard_moment_component_count(
                plan.moment_descriptor) +
            _checkerboard_relationship_read_count(
                plan.relationship_schemas)),
        Val(Degree))
    target_linear, source_linear = sites
    target = _checkerboard_cartesian_site(plan.shape, target_linear)
    source = source_linear > 0 ?
        _checkerboard_cartesian_site(plan.shape, source_linear) : target
    context = _gathered_proposal_context(
        source,
        target,
        target_linear,
        owners[1],
        owners[2],
        kinds[1],
        kinds[2],
        volumes,
        semantic,
        getfield(parameters, 1),
        getfield(parameters, 2),
        plan.trajectory_seed,
        zero(T),
        science_parameters,
        state_values,
        contact_sites,
        contact_owners,
        contact_kinds,
        reverse_contact_sites,
        reverse_contact_owners,
        reverse_contact_kinds,
        plan.contact_ranges,
        tracker_values, plan.tracker_descriptors,
        moment_first, moment_second, plan.moment_descriptor,
        relationship_resources,
    )
    return actionable, context
end

Base.@noinline function (evaluator::_CheckerboardScientificEvaluator{
        T,Degree,HasParameters,Terms,Accepted,Relationships,
        SiteNames,RelationshipNames,Context})(
        item::Int32, reads, parameters,
    ) where {
        T,Degree,HasParameters,Terms,Accepted,Relationships,
        SiteNames,RelationshipNames,Context,
    }
    actionable, context = _checkerboard_proposal_context(
        evaluator.context, reads, parameters, T, Val(Degree),
        Val(HasParameters))
    evaluation = actionable ?
        _fold_executable_proposal_numeric_terms(
            evaluator.terms, context, T, _neutral_proposal_evaluation(T)) :
        _neutral_proposal_evaluation(T)
    accepted_site_evaluations = actionable ?
        _evaluate_accepted_site_terms(
            evaluator.accepted_site_terms, context, T) :
        _disabled_accepted_site_terms(evaluator.accepted_site_terms, T)
    accepted_relationship_evaluations = actionable ?
        _evaluate_accepted_relationship_terms(
            evaluator.accepted_relationship_terms, context) :
        _disabled_accepted_relationship_terms(
            evaluator.accepted_relationship_terms)
    return _checkerboard_scientific_result(
        evaluation, evaluator.accepted_site_terms,
        accepted_site_evaluations, Val(SiteNames),
        evaluator.accepted_relationship_terms,
        accepted_relationship_evaluations,
        Val(RelationshipNames))
end

Base.@noinline function (evaluator::_CheckerboardConstraintEvaluator{
        T,Degree,HasParameters,Terms,Context})(
        item::Int32, reads, parameters,
    ) where {T,Degree,HasParameters,Terms,Context}
    actionable, context = _checkerboard_proposal_context(
        evaluator.context, reads, parameters, T, Val(Degree),
        Val(HasParameters))
    allowed = !actionable ||
        _fold_executable_proposal_constraints(evaluator.terms, context)
    return (constraints_allowed = LocalMath.UniqueValue(allowed),)
end

function _checkerboard_scientific_declaration(
        checkerboard::CheckerboardPlan,
        proposal_offsets::AbstractMatrix{<:Integer},
        seed::UInt64,
        replica::UInt32,
        repeat::UInt32,
        descriptor_plan::DescriptorExecutionPlan,
        stage_plan::StageExecutionPlan,
        tracker_plan,
        ownership_change_handles::Tuple,
        relationship_schemas::RelationshipStorage,
        relationship_state::RelationshipStorage,
        minimum_parameter_count::Integer,
        cell_capacity::Integer,
        ::Type{T},
    ) where {T<:AbstractFloat}
    cell_capacity >= 0 || throw(ArgumentError(
        "checkerboard cell capacity cannot be negative"))
    topology = _checkerboard_proposal_topology_declaration(
        checkerboard, proposal_offsets, seed, replica, repeat)
    inventory = _proposal_gather_inventory(descriptor_plan)
    requirements = _checkerboard_scientific_requirements(
        inventory, stage_plan, ownership_change_handles, tracker_plan)
    state_handles = requirements.state_handles
    terms = _compile_proposal_terms(descriptor_plan, state_handles)
    numeric_terms = _proposal_numeric_terms(terms)
    constraint_terms = _proposal_constraint_terms(terms)
    accepted_site_terms = _compile_accepted_site_terms(
        stage_plan, descriptor_plan, state_handles)
    accepted_relationship_terms = _compile_accepted_relationship_terms(
        stage_plan, descriptor_plan, state_handles,
        relationship_schemas, relationship_state)
    cell_space = LocalMath.Space(_CheckerboardCellDomain, Int(cell_capacity))
    cell_kinds = LocalMath.Field(cell_space, Int16)
    cell_generations = LocalMath.Field(cell_space, UInt32)
    cell_volumes = LocalMath.Field(cell_space, Int32)
    kind_relation = LocalMath.IndexRelation(
        topology.owners => cell_space; optional = true)
    kinds = LocalMath.Field(topology.source_space, NTuple{2,Int16})
    volumes = LocalMath.Field(topology.source_space, NTuple{2,Int32})
    tracker_keys = requirements.tracker_keys
    tracker_descriptors = requirements.tracker_descriptors
    moment_descriptor = requirements.moment_descriptor
    tracker_source_fields = map(tracker_descriptors) do descriptor
        LocalMath.Field(cell_space,
            _tracker_storage_eltype(tracker_storage(descriptor)))
    end
    tracker_pair_fields = map(tracker_source_fields) do field
        LocalMath.Field(topology.source_space, NTuple{2,eltype(field)})
    end
    tracker_names = ntuple(
        index -> Symbol(:proposal_tracker_, index), length(tracker_pair_fields))
    moment_source_fields = if moment_descriptor === nothing
        ()
    else
        dimensions = typeof(moment_descriptor).parameters[1]
        moment_type = typeof(moment_descriptor).parameters[2]
        ntuple(dimensions + dimensions * dimensions) do _
            LocalMath.Field(cell_space, moment_type)
        end
    end
    moment_names = ntuple(index -> Symbol(:proposal_moment_, index),
        length(moment_source_fields))
    relationship_bank_fields = Tuple(map(
        _checkerboard_relationship_state_fields,
        relationship_state.banks))
    relationship_science = _checkerboard_relationship_science_declarations(
        requirements.relationship_handles, topology.source_space,
        topology.batch_size, cell_space, cell_volumes, kind_relation,
        moment_source_fields, moment_descriptor,
        relationship_bank_fields,
        descriptor_plan.domain_resources,
        relationship_schemas, relationship_state)
    relationship_schemas_compiled = map(
        declaration -> declaration.schema, relationship_science)
    evaluation = (
        delta_h = LocalMath.Field(topology.source_space, T),
        drive_energy = LocalMath.Field(topology.source_space, T),
        drive_log_bias = LocalMath.Field(topology.source_space, T),
        kinetic_modifier = LocalMath.Field(topology.source_space, T),
        constraints_allowed = LocalMath.Field(topology.source_space, Bool),
    )
    all(handle -> Tuple(Int.(handle_shape(handle))) == checkerboard.shape,
        state_handles) || throw(ArgumentError(
            "checkerboard proposal state fields must match the lattice shape"))
    state_fields = map(state_handles) do handle
        LocalMath.Field(topology.lattice_space,
            _state_handle_element_type(handle))
    end
    accepted_state_handles = requirements.accepted_state_handles
    accepted_state_fields = map(accepted_state_handles) do handle
        slot = findfirst(==(handle), state_handles)
        slot === nothing && error("accepted state handle was not gathered")
        getfield(state_fields, slot)
    end
    proposal_site_relation = LocalMath.IndexRelation(
        topology.sites => topology.lattice_space; optional = true)
    parameter_count = max(
        requirements.parameter_count, Int(minimum_parameter_count))
    science_parameters = iszero(parameter_count) ? nothing :
        LocalMath.Field(topology.source_space, NTuple{parameter_count,T})
    publication(field, name, type) = LocalMath.Publication((
        LocalMath.FieldPublication(
            field, topology.identity, LocalMath.PublicationValue(name)),),
        _checkerboard_scratch_unique(type))
    contact_offset_table = descriptor_plan.domain_resources.contact_offsets
    contact_offsets = if iszero(size(contact_offset_table, 2))
        ()
    else
        size(contact_offset_table, 1) == length(checkerboard.shape) || throw(
            ArgumentError(
                "Hamiltonian contact offsets do not match the checkerboard dimensionality"))
        _proposal_offsets_tuple(
            contact_offset_table, length(checkerboard.shape))
    end
    contact_degree = length(contact_offsets)
    contact_ranges = (
        Tuple(descriptor_plan.domain_resources.contact_starts),
        Tuple(descriptor_plan.domain_resources.contact_counts),
    )
    contact = if iszero(contact_degree)
        nothing
    else
        target_selection = LocalMath.IndexRelation(
            topology.target => topology.lattice_space; optional = false)
        affine = LocalMath.AffineRelation(
            topology.lattice_space => topology.lattice_space;
            offsets = contact_offsets)
        boundary = LocalMath.BoundaryRelation(
            affine, LocalMath.PeriodicBoundary(Tuple(checkerboard.periodic)))
        relation = LocalMath.compose(target_selection, boundary)
        reverse_affine = LocalMath.AffineRelation(
            topology.lattice_space => topology.lattice_space;
            offsets = map(offset -> map(-, offset), contact_offsets))
        reverse_boundary = LocalMath.BoundaryRelation(
            reverse_affine,
            LocalMath.PeriodicBoundary(Tuple(checkerboard.periodic)))
        reverse_relation = LocalMath.compose(target_selection, reverse_boundary)
        affected_relation = LocalMath.compose(
            target_selection, reverse_boundary, boundary)
        contact_owners = LocalMath.Field(
            topology.source_space, NTuple{contact_degree,Int32})
        reverse_contact_owners = LocalMath.Field(
            topology.source_space, NTuple{contact_degree,Int32})
        contact_sites = LocalMath.Field(
            topology.source_space, NTuple{contact_degree,Int32})
        contact_kinds = LocalMath.Field(
            topology.source_space, NTuple{contact_degree,Int16})
        reverse_contact_kinds = LocalMath.Field(
            topology.source_space, NTuple{contact_degree,Int16})
        reverse_contact_sites = LocalMath.Field(
            topology.source_space, NTuple{contact_degree,Int32})
        kind_selection = LocalMath.IndexRelation(
            contact_owners => cell_space; optional = true)
        reverse_kind_selection = LocalMath.IndexRelation(
            reverse_contact_owners => cell_space; optional = true)
        owner_stage = LocalMath.Stage(
            topology.source_space,
            (ownership = LocalMath.Access(topology.ownership, relation),),
            (
                publication(contact_owners, :contact_owners,
                    NTuple{contact_degree,Int32}),
                publication(contact_sites, :contact_sites,
                    NTuple{contact_degree,Int32}),
            ),
            LocalMath.Evaluator(
                _CheckerboardContactGatherEvaluator{contact_degree}()),
            LocalMath.Control(; prefix = topology.batch_size),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__;
                label = :checkerboard_contact_ownership),
        )
        reverse_owner_stage = LocalMath.Stage(
            topology.source_space,
            (ownership = LocalMath.Access(
                topology.ownership, reverse_relation),),
            (
                publication(reverse_contact_sites, :reverse_contact_sites,
                    NTuple{contact_degree,Int32}),
                publication(reverse_contact_owners, :reverse_contact_owners,
                    NTuple{contact_degree,Int32}),
            ),
            LocalMath.Evaluator(
                _CheckerboardReverseContactGatherEvaluator{contact_degree}()),
            LocalMath.Control(; prefix = topology.batch_size),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__;
                label = :checkerboard_reverse_contact_ownership),
        )
        kind_stage = LocalMath.Stage(
            topology.source_space,
            (cell_kinds = LocalMath.Access(cell_kinds, kind_selection),),
            (publication(contact_kinds, :contact_kinds,
                NTuple{contact_degree,Int16}),),
            LocalMath.Evaluator(
                _CheckerboardContactKindEvaluator{contact_degree}()),
            LocalMath.Control(; prefix = topology.batch_size),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__;
                label = :checkerboard_contact_kinds),
        )
        reverse_kind_stage = LocalMath.Stage(
            topology.source_space,
            (cell_kinds = LocalMath.Access(
                cell_kinds, reverse_kind_selection),),
            (publication(reverse_contact_kinds, :reverse_contact_kinds,
                NTuple{contact_degree,Int16}),),
            LocalMath.Evaluator(
                _CheckerboardReverseContactKindEvaluator{contact_degree}()),
            LocalMath.Control(; prefix = topology.batch_size),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__;
                label = :checkerboard_reverse_contact_kinds),
        )
        (; relation, reverse_relation, affected_relation,
            owners = contact_owners, sites = contact_sites,
            kinds = contact_kinds, reverse_sites = reverse_contact_sites,
            reverse_owners = reverse_contact_owners,
            reverse_kinds = reverse_contact_kinds,
            kind_selection, reverse_kind_selection,
            law = LocalMath.sequence(
                LocalMath.LocalLaw(owner_stage),
                LocalMath.LocalLaw(reverse_owner_stage),
                LocalMath.LocalLaw(kind_stage),
                LocalMath.LocalLaw(reverse_kind_stage)))
    end
    state_accesses = map(state_fields) do field
        LocalMath.Access(field, proposal_site_relation)
    end
    contact_state_accesses = contact === nothing ? () : map(state_fields) do field
        LocalMath.Access(field, contact.relation)
    end
    reverse_contact_state_accesses = contact === nothing ? () : map(state_fields) do field
        LocalMath.Access(field, contact.reverse_relation)
    end
    affected_contact_state_accesses = contact === nothing ? () : map(state_fields) do field
        LocalMath.Access(field, contact.affected_relation)
    end
    state_names = ntuple(
        index -> Symbol(:proposal_state_, index), length(state_fields))
    contact_state_names = contact === nothing ? () : ntuple(
        index -> Symbol(:contact_state_, index), length(state_fields))
    reverse_contact_state_names = contact === nothing ? () : ntuple(
        index -> Symbol(:reverse_contact_state_, index), length(state_fields))
    affected_contact_state_names = contact === nothing ? () : ntuple(
        index -> Symbol(:affected_contact_state_, index), length(state_fields))
    cell_resource_stage = LocalMath.Stage(
        topology.source_space,
        (
            cell_kinds = LocalMath.Access(cell_kinds, kind_relation),
            cell_volumes = LocalMath.Access(cell_volumes, kind_relation),
        ),
        (
            publication(kinds, :kinds, NTuple{2,Int16}),
            publication(volumes, :volumes, NTuple{2,Int32}),
        ),
        LocalMath.Evaluator(_CheckerboardCellResourceEvaluator()),
        LocalMath.Control(; prefix = topology.batch_size),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_owner_kinds),
    )
    tracker_stage = if isempty(tracker_pair_fields)
        nothing
    else
        tracker_accesses = NamedTuple{tracker_names}(map(
            field -> LocalMath.Access(field, kind_relation),
            tracker_source_fields))
        tracker_publications = map(
            tracker_pair_fields, tracker_names) do field, name
            publication(field, name, eltype(field))
        end
        LocalMath.Stage(
            topology.source_space, tracker_accesses, tracker_publications,
            LocalMath.Evaluator(
                _CheckerboardTrackerResourceEvaluator{
                    tracker_names,Tuple{map(eltype, tracker_source_fields)...}}()),
            LocalMath.Control(; prefix = topology.batch_size),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__;
                label = :checkerboard_tracker_resources))
    end
    accepted_relationship_fields = _accepted_relationship_fields(
        topology.source_space, accepted_relationship_terms)
    accepted_site_fields = _accepted_site_fields(
        topology.source_space, accepted_site_terms, T)
    site_port_names = keys(accepted_site_fields)
    relationship_port_names = keys(accepted_relationship_fields)
    proposal_context = _CheckerboardProposalContextPlan(
        checkerboard.shape,
        _trajectory_seed(seed, replica, repeat),
        state_handles,
        contact_ranges,
        tracker_descriptors,
        moment_descriptor,
        relationship_schemas_compiled,
    )
    scientific_evaluator = _CheckerboardScientificEvaluator{
        T, contact_degree, !iszero(parameter_count),
        typeof(numeric_terms), typeof(accepted_site_terms),
        typeof(accepted_relationship_terms),
        site_port_names,
        relationship_port_names,
        typeof(proposal_context)}(
            proposal_context, numeric_terms,
            accepted_site_terms, accepted_relationship_terms)
    constraint_evaluator = _CheckerboardConstraintEvaluator{
        T, contact_degree, !iszero(parameter_count),
        typeof(constraint_terms), typeof(proposal_context)}(
            proposal_context, constraint_terms)
    core_reads = (
        sites = LocalMath.Access(
            topology.sites, topology.identity; required = true),
        owners = LocalMath.Access(
            topology.owners, topology.identity; required = true),
        kinds = LocalMath.Access(kinds, topology.identity; required = true),
        volumes = LocalMath.Access(volumes, topology.identity; required = true),
        actionable = LocalMath.Access(
            topology.actionable, topology.identity; required = true),
        semantic = LocalMath.Access(
            topology.semantic, topology.identity; required = true),
    )
    parameter_reads = science_parameters === nothing ? NamedTuple() : (
        science_parameters = LocalMath.Access(
            science_parameters, topology.identity; required = true),)
    base_reads = merge(core_reads, parameter_reads)
    contact_reads = contact === nothing ? NamedTuple() : (
        contact_sites = LocalMath.Access(
            contact.sites, topology.identity; required = true),
        contact_owners = LocalMath.Access(
            contact.owners, topology.identity; required = true),
        contact_kinds = LocalMath.Access(
            contact.kinds, topology.identity; required = true),
        reverse_contact_sites = LocalMath.Access(
            contact.reverse_sites, topology.identity; required = true),
        reverse_contact_owners = LocalMath.Access(
            contact.reverse_owners, topology.identity; required = true),
        reverse_contact_kinds = LocalMath.Access(
            contact.reverse_kinds, topology.identity; required = true),
    )
    tracker_reads = NamedTuple{tracker_names}(map(
        field -> LocalMath.Access(
            field, topology.identity; required = true),
        tracker_pair_fields))
    moment_reads = NamedTuple{moment_names}(map(
        field -> LocalMath.Access(field, kind_relation),
        moment_source_fields))
    relationship_reads = _checkerboard_relationship_science_reads(
        relationship_science)
    scientific_reads = NamedTuple{(
        keys(base_reads)..., keys(contact_reads)..., keys(tracker_reads)...,
        keys(moment_reads)..., keys(relationship_reads)...,
        state_names..., contact_state_names..., reverse_contact_state_names...,
        affected_contact_state_names...)}((
            values(base_reads)..., values(contact_reads)...,
            values(tracker_reads)..., values(moment_reads)...,
            values(relationship_reads)...,
            state_accesses..., contact_state_accesses...,
            reverse_contact_state_accesses...,
            affected_contact_state_accesses...))
    base_publications = (
        publication(evaluation.delta_h, :delta_h, T),
        publication(evaluation.drive_energy, :drive_energy, T),
        publication(evaluation.drive_log_bias, :drive_log_bias, T),
        publication(evaluation.kinetic_modifier, :kinetic_modifier, T),
    )
    site_publications = map(
        site_port_names, values(accepted_site_fields)) do name, field
        publication(field, name, eltype(field))
    end
    relationship_publications = map(
        relationship_port_names, values(accepted_relationship_fields)) do name, field
        publication(field, name, eltype(field))
    end
    scientific_publications = (
        base_publications..., site_publications...,
        relationship_publications...)
    scientific_stage = LocalMath.Stage(
        topology.source_space,
        scientific_reads,
        scientific_publications,
        LocalMath.Evaluator(
            scientific_evaluator, (topology.mcs, topology.color)),
        LocalMath.Control(; prefix = topology.batch_size),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_scientific_evaluation),
    )
    constraint_stage = LocalMath.Stage(
        topology.source_space,
        scientific_reads,
        (publication(evaluation.constraints_allowed,
            :constraints_allowed, Bool),),
        LocalMath.Evaluator(
            constraint_evaluator, (topology.mcs, topology.color)),
        LocalMath.Control(; prefix = topology.batch_size),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_constraint_evaluation),
    )
    tracker_laws = tracker_stage === nothing ? () :
        (LocalMath.LocalLaw(tracker_stage),)
    contact_laws = contact === nothing ? () : (contact.law,)
    relationship_geometry_laws = map(relationship_science) do declaration
        LocalMath.sequence(
            LocalMath.LocalLaw(declaration.edge_stage),
            LocalMath.LocalLaw(declaration.endpoint_stage))
    end
    law = LocalMath.sequence(
        topology.law,
        LocalMath.LocalLaw(cell_resource_stage),
        tracker_laws...,
        contact_laws...,
        relationship_geometry_laws...,
        LocalMath.LocalLaw(scientific_stage),
        LocalMath.LocalLaw(constraint_stage),
    )
    return merge(topology, (;
        law, terms, shape = checkerboard.shape,
        cell_space, cell_kinds, cell_generations, cell_volumes,
        kind_relation,
        kinds, volumes,
        evaluation, accepted_site_terms, accepted_site_fields,
        accepted_relationship_terms, accepted_relationship_fields,
        accepted_count = stage_plan.accepted_count,
        scientific_evaluator, constraint_evaluator,
        state_handles, state_fields,
        accepted_state_handles, accepted_state_fields,
        ownership_change_handles,
        proposal_site_relation, science_parameters, parameter_count, contact,
        contact_ranges, tracker_keys, tracker_descriptors,
        tracker_source_fields, tracker_pair_fields,
        moment_descriptor, moment_source_fields,
        relationship_science, relationship_bank_fields))
end
