# Acceptance, validation, tracker, and packed-relationship transaction laws.

struct _AcceptanceTemperature{Index,T}
    default::T
end

_acceptance_temperature(scalar::CompiledScalar{T}) where {T} =
    _AcceptanceTemperature{Int(scalar.parameter_index),T}(scalar.value)

@inline _acceptance_temperature_value(
    temperature::_AcceptanceTemperature{0}, parameters,
) = temperature.default
@inline _acceptance_temperature_value(
    ::_AcceptanceTemperature{Index}, parameters,
) where {Index} = getfield(parameters, Index)

struct _CompiledProposalAcceptanceEvaluator{HasParameters,Constraint,T,F,R}
    trajectory_seed::UInt64
    temperature::T
    forbid_extinction::F
    retire_at_zero::R
end


_compiled_proposal_acceptance_evaluator(
    ::Val{HasParameters}, ::Val{Constraint}, trajectory_seed,
    temperature, forbid, retire,
) where {HasParameters,Constraint} = _CompiledProposalAcceptanceEvaluator{
    HasParameters,Constraint,typeof(temperature),typeof(forbid),typeof(retire)}(
        trajectory_seed, temperature, forbid, retire)

@inline _compiled_acceptance_parameters(reads, ::Val{false}) = ()
@inline _compiled_acceptance_parameters(reads, ::Val{true}) =
    something(@inbounds getfield(reads, 11)[1].value)

@inline _compiled_constraint_value(reads, ::Val{nothing}) = something(
    @inbounds getfield(reads, 10)[1].value)
@inline _compiled_constraint_value(reads, ::Val{Constraint}) where {Constraint} =
    Constraint

@inline function _compiled_extinction_admitted(
        evaluator::_CompiledProposalAcceptanceEvaluator,
        owners::NTuple{2,Int32}, kinds::NTuple{2,Int16},
        volumes::NTuple{2,Int32},
    )
    old_owner, new_owner = owners
    old_owner > 0 && old_owner != new_owner || return true
    volumes[1] == Int32(1) || return true
    kind = kinds[1]
    kind > 0 || return false
    index = Int(kind)
    1 <= index <= length(evaluator.forbid_extinction) || return false
    @inbounds evaluator.forbid_extinction[index] && return false
    return @inbounds evaluator.retire_at_zero[index]
end

@inline function (evaluator::_CompiledProposalAcceptanceEvaluator{
        HasParameters,Constraint})(
        item::Int32, reads, parameters,
    ) where {HasParameters,Constraint}
    actionable = something(@inbounds getfield(reads, 1)[1].value)
    owners = something(@inbounds getfield(reads, 2)[1].value)
    kinds = something(@inbounds getfield(reads, 3)[1].value)
    volumes = something(@inbounds getfield(reads, 4)[1].value)
    semantic = something(@inbounds getfield(reads, 5)[1].value)
    delta_h = something(@inbounds getfield(reads, 6)[1].value)
    drive_energy = something(@inbounds getfield(reads, 7)[1].value)
    drive_log_bias = something(@inbounds getfield(reads, 8)[1].value)
    kinetic_modifier = something(@inbounds getfield(reads, 9)[1].value)
    constraints_allowed = _compiled_constraint_value(
        reads, Val(Constraint))
    science_parameters = _compiled_acceptance_parameters(
        reads, Val(HasParameters))
    disposition = _PROGRAM_CHECKERBOARD_NULL
    failure_code = UInt8(ProposalAcceptanceReady)
    if actionable
        if !_compiled_extinction_admitted(
                evaluator, owners, kinds, volumes)
            disposition = _PROGRAM_CHECKERBOARD_CONSTRAINT
        else
            temperature = _acceptance_temperature_value(
                evaluator.temperature, science_parameters)
            log_ratio, acceptance_code = _proposal_acceptance_values(
                delta_h, drive_energy, drive_log_bias,
                kinetic_modifier, constraints_allowed, temperature)
            if acceptance_code === ProposalAcceptanceConstraintRejected
                disposition = _PROGRAM_CHECKERBOARD_CONSTRAINT
            elseif acceptance_code === ProposalAcceptanceNonfinite
                disposition = _PROGRAM_CHECKERBOARD_NONFINITE
                failure_code = UInt8(acceptance_code)
            elseif acceptance_code === ProposalAcceptanceZeroTemperatureDrive
                disposition = _PROGRAM_CHECKERBOARD_ZERO_T_DRIVE
                failure_code = UInt8(acceptance_code)
            else
                accepted = log_ratio >= zero(temperature)
                if !accepted && isfinite(log_ratio)
                    mcs = getfield(parameters, 1)
                    color = getfield(parameters, 2)
                    address = _program_address(
                        AcceptanceStream, mcs, 3, semantic;
                        subround = color)
                    draw = uniform_open01(
                        typeof(temperature), Philox4x32x10V2(),
                        evaluator.trajectory_seed, address)
                    accepted = log(draw) < log_ratio
                end
                disposition = accepted ? _PROGRAM_CHECKERBOARD_ACCEPTED :
                    _PROGRAM_CHECKERBOARD_ENERGY
            end
        end
    end
    return (
        disposition = LocalMath.UniqueValue(disposition),
        failure_code = LocalMath.UniqueValue(failure_code),
        failure_identity = LocalMath.UniqueValue(
            iszero(failure_code) ? Int32(0) : semantic),
    )
end

function _checkerboard_acceptance_declaration(
        scientific,
        temperature::CompiledScalar{T},
        forbid_extinction::Tuple,
        retire_at_zero::Tuple,
        seed::UInt64,
        replica::UInt32,
        repeat::UInt32,
    ) where {T<:AbstractFloat}
    length(forbid_extinction) == length(retire_at_zero) ||
        throw(ArgumentError(
            "checkerboard extinction policy tuples must share one kind range"))
    all(value -> value isa Bool, forbid_extinction) &&
        all(value -> value isa Bool, retire_at_zero) ||
        throw(ArgumentError(
            "checkerboard extinction policies must be Boolean tuples"))
    temperature.parameter_index <= scientific.parameter_count ||
        throw(ArgumentError(
            "checkerboard temperature parameter is outside the scientific parameter schema"))
    disposition = LocalMath.Field(scientific.source_space, UInt8)
    failure_code = LocalMath.Field(scientific.source_space, UInt8)
    failure_identity = LocalMath.Field(scientific.source_space, Int32)
    evaluator = _compiled_proposal_acceptance_evaluator(
        Val(!iszero(scientific.parameter_count)),
        Val(scientific.literal_constraint === nothing ? nothing :
            something(scientific.literal_constraint)),
        _trajectory_seed(seed, replica, repeat),
        _acceptance_temperature(temperature),
        forbid_extinction,
        retire_at_zero)
    publication(field, name, type) = LocalMath.Publication((
        LocalMath.FieldPublication(
            field, scientific.identity, LocalMath.PublicationValue(name)),),
        _checkerboard_scratch_unique(type))
    core_reads = (
        actionable = LocalMath.Access(
            scientific.actionable, scientific.identity; required = true),
        owners = LocalMath.Access(
            scientific.owners, scientific.identity; required = true),
        kinds = LocalMath.Access(
            scientific.kinds, scientific.identity; required = true),
        volumes = LocalMath.Access(
            scientific.volumes, scientific.identity; required = true),
        semantic = LocalMath.Access(
            scientific.semantic, scientific.identity; required = true),
        delta_h = LocalMath.Access(
            scientific.evaluation.delta_h,
            scientific.identity; required = true),
        drive_energy = LocalMath.Access(
            scientific.evaluation.drive_energy,
            scientific.identity; required = true),
        drive_log_bias = LocalMath.Access(
            scientific.evaluation.drive_log_bias,
            scientific.identity; required = true),
        kinetic_modifier = LocalMath.Access(
            scientific.evaluation.kinetic_modifier,
            scientific.identity; required = true),
        constraints_allowed = LocalMath.Access(
            scientific.evaluation.constraints_allowed,
            scientific.identity; required = true),
    )
    parameter_reads = scientific.science_parameters === nothing ?
        NamedTuple() : (
            science_parameters = LocalMath.Access(
                scientific.science_parameters,
                scientific.identity; required = true),)
    stage = LocalMath.Stage(
        scientific.source_space,
        merge(core_reads, parameter_reads),
        (
            publication(disposition, :disposition, UInt8),
            publication(failure_code, :failure_code, UInt8),
            publication(failure_identity, :failure_identity, Int32),
        ),
        LocalMath.Evaluator(
            evaluator, (scientific.mcs, scientific.color)),
        LocalMath.Control(; prefix = scientific.batch_size),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = :checkerboard_proposal_acceptance),
    )
    law = LocalMath.sequence(
        scientific.law, LocalMath.LocalLaw(stage))
    return merge(scientific, (;
        law, disposition, failure_code, failure_identity,
        acceptance_evaluator = evaluator))
end

struct _CheckerboardAcceptedValidation{S,R,M}
    site_terms::S
    relationship_terms::R
    maximum_batch::M
end

struct _CheckerboardAcceptedStatePublication{N,HasAssignments,H,A,C}
    handles::H
    assignments::A
    clear_handles::C
end

_checkerboard_accepted_state_publication(
        ::Val{Names}, ::Val{HasAssignments}, handles, assignments,
        clear_handles) where {Names,HasAssignments} =
    _CheckerboardAcceptedStatePublication{
        Names,HasAssignments,typeof(handles),typeof(assignments),
        typeof(clear_handles)}(handles, assignments, clear_handles)

@generated function _checkerboard_terminal_state_values(
        reads, ::Val{Count}, ::Val{Offset}) where {Count,Offset}
    return Expr(:tuple, (
        :(something(@inbounds getfield(reads, $(index + Offset))[1].value))
        for index in 1:Count)...)
end

@inline _apply_accepted_site_assignments(
    ::Tuple{}, ::Tuple{}, handle, value) = value
@inline function _apply_accepted_site_assignments(
        assignments::Tuple, evaluations::Tuple, handle, value)
    assignment = first(assignments)
    code = getfield(evaluations, 1)
    evaluation = getfield(evaluations, 2)
    updated = assignment.target == handle && code == _ACCEPTED_SITE_READY ?
        convert(typeof(value), evaluation) : value
    return _apply_accepted_site_assignments(
        Base.tail(assignments), Base.tail(Base.tail(evaluations)),
        handle, updated)
end

@inline _accepted_state_publications(
    ::Tuple{}, ::Tuple{}, assignments, evaluations, clear_handles,
    ownership_changed, accepted) = ()
@inline function _accepted_state_publications(
        handles::Tuple, values::Tuple, assignments, evaluations,
        clear_handles, ownership_changed, accepted)
    handle = first(handles)
    value = first(values)
    baseline = ownership_changed && handle in clear_handles ?
        zero(value) : value
    result = _apply_accepted_site_assignments(
        assignments, evaluations, handle, baseline)
    return (LocalMath.ConditionalUniqueValue(result, accepted),
        _accepted_state_publications(
            Base.tail(handles), Base.tail(values), assignments,
            evaluations, clear_handles, ownership_changed, accepted)...)
end

@inline function _checkerboard_accepted_state_result(
        evaluator::_CheckerboardAcceptedStatePublication{Names},
        reads, evaluations, values) where {Names}
    disposition = something(@inbounds getfield(reads, 1)[1].value)
    owners = something(@inbounds getfield(reads, 2)[1].value)
    accepted = disposition == _PROGRAM_CHECKERBOARD_ACCEPTED
    results = _accepted_state_publications(
        evaluator.handles, values, evaluator.assignments, evaluations,
        evaluator.clear_handles, owners[1] != owners[2], accepted)
    return NamedTuple{Names}((
        LocalMath.ConditionalUniqueValue(owners[2], accepted),
        results...,
    ))
end

@inline function (evaluator::_CheckerboardAcceptedStatePublication{
        Names,true})(item::Int32, reads, parameters) where {Names}
    evaluations = _accepted_site_evaluations(
        reads, evaluator.assignments, Val(3))
    values = _checkerboard_terminal_state_values(
        reads, Val(length(evaluator.handles)),
        Val(2 + 2length(evaluator.assignments)))
    return _checkerboard_accepted_state_result(
        evaluator, reads, evaluations, values)
end

@inline function (evaluator::_CheckerboardAcceptedStatePublication{
        Names,false})(item::Int32, reads, parameters) where {Names}
    values = _checkerboard_terminal_state_values(
        reads, Val(length(evaluator.handles)), Val(2))
    return _checkerboard_accepted_state_result(
        evaluator, reads, (), values)
end

@generated function _accepted_site_evaluations(
        reads, ::Terms, ::Val{Offset}) where {Terms<:Tuple,Offset}
    return Expr(:tuple, (
        :(something(@inbounds getfield(reads, $(Offset + index - 1))[1].value))
        for index in 1:(2fieldcount(Terms)))...)
end

@generated function (evaluator::_CheckerboardAcceptedValidation{S,R})(
        item::Int32, reads, parameters) where {S<:Tuple,R<:Tuple}
    checks = Expr[]
    read_index = 3
    for index in 1:fieldcount(S)
        push!(checks, quote
            local term = getfield(evaluator.site_terms, $index)
            local code = something(
                @inbounds getfield(reads, $read_index)[1].value)
            if (code == _ACCEPTED_SITE_INVALID_CONDITION ||
                    code == _ACCEPTED_SITE_INVALID_VALUE) &&
                    term.descriptor_ordinal < descriptor_ordinal
                invalid = true
                descriptor_ordinal = term.descriptor_ordinal
                source_handle = term.source_handle
                stage = ProgramStageState
                detail = code == _ACCEPTED_SITE_INVALID_CONDITION ?
                    LifecycleDetailTriggerNotBoolean :
                    LifecycleDetailNonfiniteResult
            end
        end)
        read_index += 2
    end
    for (index, term_type) in enumerate(R.parameters)
        push!(checks, quote
            local term = getfield(evaluator.relationship_terms, $index)
            local code = something(
                @inbounds getfield(reads, $read_index)[1].value)
            if (code == _ACCEPTED_RELATIONSHIP_INVALID_CONDITION ||
                    code == _ACCEPTED_RELATIONSHIP_INVALID_VALUE) &&
                    term.descriptor_ordinal < descriptor_ordinal
                invalid = true
                descriptor_ordinal = term.descriptor_ordinal
                source_handle = term.source_handle
                stage = ProgramStageRelationships
                detail = code == _ACCEPTED_RELATIONSHIP_INVALID_CONDITION ?
                    LifecycleDetailTriggerNotBoolean :
                    LifecycleDetailNonfiniteResult
            end
        end)
        read_index += 2 + fieldcount(term_type.parameters[5])
    end
    return quote
        local semantic = something(@inbounds getfield(reads, 1)[1].value)
        local disposition = something(@inbounds getfield(reads, 2)[1].value)
        local invalid = false
        local source_handle = Int32(1)
        local descriptor_ordinal = typemax(Int32)
        local stage = ProgramStageState
        local detail = LifecycleDetailNonfiniteResult
        $(checks...)
        local enabled =
            disposition == _PROGRAM_CHECKERBOARD_ACCEPTED && invalid
        invalid || (descriptor_ordinal = Int32(1))
        local status = ProgramStatus(
            ProgramStatusEvaluator,
            getfield(parameters, 1),
            stage,
            source_handle,
            UInt64(semantic),
            Int32(0),
            item,
            detail,
            Int32(0), Int32(0), Int32(0))
        local rank = (descriptor_ordinal - Int32(1)) *
            evaluator.maximum_batch + item
        (status = LocalMath.RoutedResolutionValue(
            Int32(1), rank, status, enabled),)
    end
end

struct _CheckerboardRelationshipEndpointEvaluator{N} end
struct _CheckerboardRelationshipFoldEvaluator{P,T}
    terms::T
    accepted_count::Int32
end
struct _CheckerboardRelationshipOrderKey{P} end
struct _CheckerboardRelationshipOrderIdentity{P} end

struct _CheckerboardCompiledRelationshipTransition{P,S}
    schema::S
end

struct _CheckerboardScalarTrackerEvaluator{N,D,R,S,A}
    descriptors::D
    contact_ranges::R
    shape::S
    owner_capacity::Int32
    first_column::Int32
end

"""A device-portable signed accumulator for tracker fields of at most 32 bits."""
struct _TrackerWideInteger
    low::UInt32
    high::Int32
end

Base.zero(::Type{_TrackerWideInteger}) =
    _TrackerWideInteger(UInt32(0), Int32(0))
Base.convert(::Type{_TrackerWideInteger}, value::Signed) =
    _TrackerWideInteger(reinterpret(UInt32, Int32(value)),
        value < 0 ? Int32(-1) : Int32(0))
Base.convert(::Type{_TrackerWideInteger}, value::Unsigned) =
    _TrackerWideInteger(UInt32(value), Int32(0))
function Base.:+(left::_TrackerWideInteger, right::_TrackerWideInteger)
    low = left.low + right.low
    carry = Int32(low < left.low)
    return _TrackerWideInteger(low, left.high + right.high + carry)
end
function Base.:-(value::_TrackerWideInteger)
    low = ~value.low + UInt32(1)
    carry = Int32(iszero(low))
    return _TrackerWideInteger(low, ~value.high + carry)
end
Base.convert(::Type{T}, value::_TrackerWideInteger) where {T<:Signed} =
    convert(T, reinterpret(Int32, value.low))
Base.convert(::Type{T}, value::_TrackerWideInteger) where {T<:Unsigned} =
    convert(T, value.low)

@inline function _tracker_wide_less(
        left::_TrackerWideInteger, right::_TrackerWideInteger)
    left.high == right.high || return left.high < right.high
    return left.low < right.low
end
@inline _tracker_wide_in_storage_range(
        value::_TrackerWideInteger, ::Type{T}) where {T<:Integer} =
    !_tracker_wide_less(value, convert(_TrackerWideInteger, typemin(T))) &&
    !_tracker_wide_less(convert(_TrackerWideInteger, typemax(T)), value)

struct _CheckerboardTrackerValueDomain{T} end
@inline (::_CheckerboardTrackerValueDomain{T})(
    value::_TrackerWideInteger) where {T<:Integer} =
    _tracker_wide_in_storage_range(value, T)
@inline (::_CheckerboardTrackerValueDomain{T})(value) where {T<:Integer} =
    typemin(T) <= value <= typemax(T)
@inline (::_CheckerboardTrackerValueDomain{T})(value) where {T<:AbstractFloat} =
    isfinite(value)
@inline _checkerboard_tracker_validation_combine(accumulator, value) = accumulator
@inline _checkerboard_tracker_validation_finish(accumulator, count) = accumulator
@inline _checkerboard_tracker_reduce(left, right) = left + right
@inline _negative_tracker_delta(::Type{T}, value) where {T} =
    -convert(T, value)

struct _CheckerboardTrackerValidationEvaluator{F}
    fold::F
end
@inline function (evaluator::_CheckerboardTrackerValidationEvaluator)(
        item::Int32, reads, parameters)
    value = evaluator.fold(getfield(reads, 1))
    return (validated = LocalMath.UniqueValue(value),)
end

struct _CheckerboardFieldConvertEvaluator{T} end
@inline function (::_CheckerboardFieldConvertEvaluator{T})(
        item::Int32, reads, parameters) where {T}
    value = something(@inbounds getfield(reads, 1)[1].value)
    return (value = LocalMath.UniqueValue(convert(T, value)),)
end

struct _CheckerboardMomentTrackerEvaluator{N,C,T,S}
    shape::S
    owner_capacity::Int32
    component_count::Int32
end

@inline function _checkerboard_tracker_contribution(
        key::Int32, value, participates::Bool)
    return LocalMath.RoutedContribution(
        participates ? key : Int32(1), value, participates)
end

@inline function _checkerboard_surface_tracker_delta(
        descriptor::CellSurfaceTracker,
        contact_sites,
        contact_owners,
        contact_ranges,
        target::Int32,
        old_owner::Int32,
        new_owner::Int32,
    )
    starts, counts = contact_ranges
    handle = Int(descriptor.relation_handle)
    start = Int(@inbounds starts[handle])
    count = Int(@inbounds counts[handle])
    count == Int(descriptor.maximum_neighbors) || throw(ArgumentError(
        "surface tracker relation degree differs from its compiled bound"))
    old_amount = Int32(0)
    new_amount = Int32(0)
    for direction in 1:count
        lane = start + direction - 1
        neighbor = @inbounds contact_sites[lane]
        neighbor > 0 || continue
        neighbor == target && continue
        duplicate = false
        for prior in 1:(direction - 1)
            if @inbounds(contact_sites[start + prior - 1]) == neighbor
                duplicate = true
                break
            end
        end
        duplicate && continue
        neighbor_owner = @inbounds contact_owners[lane]
        old_owner > 0 && (old_amount += neighbor_owner == old_owner ?
            Int32(1) : Int32(-1))
        new_owner > 0 && (new_amount += neighbor_owner == new_owner ?
            Int32(-1) : Int32(1))
    end
    return OldNewOwnerScalarDelta(old_amount, new_amount)
end

@inline _checkerboard_scalar_tracker_delta(
    ::OwnershipCountTracker, contact_sites, contact_owners, contact_ranges,
    target, old_owner, new_owner,
) = OwnerScalarDelta(Int32(1))

@inline _checkerboard_scalar_tracker_delta(
    descriptor::CellSurfaceTracker, contact_sites, contact_owners,
    contact_ranges, target, old_owner, new_owner,
) = _checkerboard_surface_tracker_delta(
    descriptor, contact_sites, contact_owners, contact_ranges,
    target[1], old_owner, new_owner)

@inline _checkerboard_scalar_tracker_delta(
    descriptor::AbstractTrackerDescriptor, contact_sites, contact_owners,
    contact_ranges, target, old_owner, new_owner,
) = tracker_ownership_delta(
    descriptor, target[2], old_owner, new_owner)

@inline function _checkerboard_scalar_tracker_pair(
        delta::OwnerScalarDelta,
        old_owner::Int32,
        new_owner::Int32,
        column::Int32,
        owner_capacity::Int32,
        accepted::Bool,
        ::Type{A},
    ) where {A}
    offset = (column - Int32(1)) * owner_capacity
    return (
        _checkerboard_tracker_contribution(
            offset + old_owner, _negative_tracker_delta(A, delta.amount),
            accepted && old_owner > 0),
        _checkerboard_tracker_contribution(
            offset + new_owner, convert(A, delta.amount),
            accepted && new_owner > 0),
    )
end

@inline function _checkerboard_scalar_tracker_pair(
        delta::OldNewOwnerScalarDelta,
        old_owner::Int32,
        new_owner::Int32,
        column::Int32,
        owner_capacity::Int32,
        accepted::Bool,
        ::Type{A},
    ) where {A}
    offset = (column - Int32(1)) * owner_capacity
    return (
        _checkerboard_tracker_contribution(
            offset + old_owner, convert(A, delta.old_amount),
            accepted && old_owner > 0),
        _checkerboard_tracker_contribution(
            offset + new_owner, convert(A, delta.new_amount),
            accepted && new_owner > 0),
    )
end

@inline _checkerboard_scalar_tracker_contributions(
    ::Tuple{}, contact_sites, contact_owners, contact_ranges, target,
    old_owner, new_owner, column, owner_capacity, accepted, accumulator_type,
) = ()

@inline function _checkerboard_scalar_tracker_contributions(
        descriptors::Tuple,
        contact_sites,
        contact_owners,
        contact_ranges,
        target,
        old_owner,
        new_owner,
        column,
        owner_capacity,
        accepted,
        accumulator_type,
    )
    delta = _checkerboard_scalar_tracker_delta(
        first(descriptors), contact_sites, contact_owners, contact_ranges,
        target, old_owner, new_owner)
    return (
        _checkerboard_scalar_tracker_pair(
            delta, old_owner, new_owner, column, owner_capacity, accepted,
            accumulator_type)...,
        _checkerboard_scalar_tracker_contributions(
            Base.tail(descriptors), contact_sites, contact_owners,
            contact_ranges, target, old_owner, new_owner, column + Int32(1),
            owner_capacity, accepted, accumulator_type)...,
    )
end

@inline function (evaluator::_CheckerboardScalarTrackerEvaluator{Name,D,R,S,A})(
        item::Int32, reads, parameters) where {Name,D,R,S,A}
    disposition = something(@inbounds getfield(reads, 1)[1].value)
    owners = something(@inbounds getfield(reads, 2)[1].value)
    sites = something(@inbounds getfield(reads, 3)[1].value)
    contact_sites = fieldcount(typeof(reads)) >= 4 ?
        something(@inbounds getfield(reads, 4)[1].value) : ()
    contact_owners = fieldcount(typeof(reads)) >= 5 ?
        something(@inbounds getfield(reads, 5)[1].value) : ()
    accepted = disposition == _PROGRAM_CHECKERBOARD_ACCEPTED
    contributions = _checkerboard_scalar_tracker_contributions(
        evaluator.descriptors, contact_sites, contact_owners,
        evaluator.contact_ranges,
        (sites[1], _checkerboard_cartesian_site(evaluator.shape, sites[1])),
        owners[1], owners[2],
        evaluator.first_column, evaluator.owner_capacity, accepted, A)
    return NamedTuple{(Name,)}((contributions,))
end

@generated function (evaluator::_CheckerboardMomentTrackerEvaluator{
        Name,Components,T})(item::Int32, reads, parameters) where {
        Name,Components,T}
    contributions = Expr[]
    for owner_lane in 1:2, (component, row, column) in Components
        row = Int(row)
        column = Int(column)
        owner = :(getfield(owners, $owner_lane))
        left = :($T(target[$row]) - $T(0.5))
        value = iszero(column) ? left :
            :($left * ($T(target[$column]) - $T(0.5)))
        signed = owner_lane == 1 ? :(-$value) : value
        push!(contributions, :(_checkerboard_tracker_contribution(
            Int32($(Int32(component)) +
                ($owner - Int32(1)) * evaluator.component_count),
            $signed, accepted && $owner > 0)))
    end
    return quote
        local disposition = something(
            @inbounds getfield(reads, 1)[1].value)
        local owners = something(@inbounds getfield(reads, 2)[1].value)
        local sites = something(@inbounds getfield(reads, 3)[1].value)
        local target = _checkerboard_cartesian_site(
            evaluator.shape, getfield(sites, 1))
        local accepted =
            disposition == _PROGRAM_CHECKERBOARD_ACCEPTED
        NamedTuple{$(QuoteNode((Name,)))}((($(contributions...),),))
    end
end

_checkerboard_tracker_contains_surface(::Tuple{}) = false
function _checkerboard_tracker_contains_surface(descriptors::Tuple)
    return first(descriptors) isa CellSurfaceTracker ||
        _checkerboard_tracker_contains_surface(Base.tail(descriptors))
end


function _checkerboard_tracker_reads(accepted, descriptors::Tuple)
    base = (
        disposition = LocalMath.Access(
            accepted.disposition, accepted.identity; required = true),
        owners = LocalMath.Access(
            accepted.owners, accepted.identity; required = true),
        sites = LocalMath.Access(
            accepted.sites, accepted.identity; required = true),
    )
    _checkerboard_tracker_contains_surface(descriptors) || return base
    accepted.contact === nothing && throw(ArgumentError(
        "surface tracker compilation requires a bounded contact relation"))
    return merge(base, (
        contact_sites = LocalMath.Access(
            accepted.contact.sites, accepted.identity; required = true),
        contact_owners = LocalMath.Access(
            accepted.contact.owners, accepted.identity; required = true),
    ))
end

function _checkerboard_tracker_field(array::AbstractArray)
    return LocalMath.Field(LocalMath.Space(size(array)), eltype(array))
end

function _checkerboard_tracker_accumulator_type(::Type{T}) where {T<:Integer}
    sizeof(T) <= 4 || throw(ArgumentError(
        "checkerboard integer tracker storage must be at most 32 bits so " *
        "transactional accumulation can detect overflow"))
    return _TrackerWideInteger
end
_checkerboard_tracker_accumulator_type(::Type{T}) where {T<:AbstractFloat} = T
_checkerboard_tracker_scratch(field::LocalMath.Field) = LocalMath.Field(
    field.space, _checkerboard_tracker_accumulator_type(eltype(field)))

function _checkerboard_tracker_validation(
        field::LocalMath.Field, ::Type{T}, tracker_index, field_index,
    ) where {T}
    source = LocalMath.Space(1)
    relation = LocalMath.FixedRelation(
        source => field.space; degree = length(field.space))
    output = LocalMath.Field(source, eltype(field))
    fold = LocalMath.bounded_fold(
        identity, _checkerboard_tracker_validation_combine,
        zero(eltype(field)), _checkerboard_tracker_validation_finish;
        domain = LocalMath.Where(_CheckerboardTrackerValueDomain{T}()),
        oninvalid = LocalMath.RejectInvalid(),
        onempty = LocalMath.FillEmpty(zero(eltype(field))),
        order = LocalMath.CanonicalLeftFold())
    label = Symbol(:checkerboard_tracker_validate_, tracker_index, :_, field_index)
    stage = LocalMath.Stage(
        source,
        (values = LocalMath.Access(field, relation),),
        (LocalMath.Publication((LocalMath.FieldPublication(
            output, LocalMath.IdentityRelation(source),
            LocalMath.PublicationValue(:validated)),),
            LocalMath.Unique(eltype(output))),),
        LocalMath.Evaluator(_CheckerboardTrackerValidationEvaluator(fold)),
        LocalMath.Control(),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__; label),
    )
    endpoints = reshape(
        Int32.(1:length(field.space)), length(field.space), 1)
    return (;
        law = LocalMath.LocalLaw(stage),
        bindings = (
            relation => LocalMath.Allocate(endpoints),
            output => LocalMath.Allocate(zero(eltype(output))),
        ),
    )
end

function _checkerboard_transactional_tracker_group(laws_builder,
        tracker_index, source_fields, paths, terminal_gate)
    fields = map(_checkerboard_tracker_scratch, source_fields)
    # Snapshot live tracker values independently of transaction admission;
    # mutation and publication remain controlled by the terminal gate.
    initialization_laws = Tuple(_checkerboard_field_copy_law(source, scratch,
            nothing, Symbol(:checkerboard_tracker_initialize_,
                tracker_index, :_, index))
        for (index, (source, scratch)) in enumerate(zip(source_fields, fields)))
    commit_laws = Tuple(_checkerboard_field_copy_law(scratch, source,
            terminal_gate, Symbol(:checkerboard_tracker_commit_,
                tracker_index, :_, index))
        for (index, (source, scratch)) in enumerate(zip(source_fields, fields)))
    laws = laws_builder(fields)
    validations = ntuple(length(fields)) do index
        _checkerboard_tracker_validation(
            fields[index], eltype(source_fields[index]), tracker_index, index)
    end
    return (; tracker_index = Int32(tracker_index), source_fields, fields,
        paths, initialization_laws, laws,
        validation_laws = map(validation -> validation.law, validations),
        validation_bindings = Tuple(pair for validation in validations
            for pair in validation.bindings),
        commit_laws)
end

function _checkerboard_scalar_tracker_laws(
        accepted,
        field,
        descriptors::Tuple,
        first_column::Integer,
        owner_capacity::Integer,
        terminal_gate,
        label_prefix::Symbol,
    )
    isempty(descriptors) && return ()
    chunk_count = min(length(descriptors), 16)
    chunk = ntuple(index -> descriptors[index], chunk_count)
    remaining = length(descriptors) == chunk_count ? () :
        ntuple(index -> descriptors[chunk_count + index],
            length(descriptors) - chunk_count)
    name = Symbol(label_prefix, :_, first_column)
    relation = LocalMath.RuntimeRelation(
        accepted.source_space => field.space;
        degree_bound = 2chunk_count, key_type = Int32)
    evaluator = _CheckerboardScalarTrackerEvaluator{
        name,typeof(chunk),typeof(accepted.contact_ranges),
        typeof(accepted.shape),eltype(field)}(
            chunk, accepted.contact_ranges, accepted.shape,
            Int32(owner_capacity), Int32(first_column))
    stage = LocalMath.Stage(
        accepted.source_space,
        _checkerboard_tracker_reads(accepted, chunk),
        (LocalMath.Publication((LocalMath.FieldPublication(
            field, relation, LocalMath.PublicationValue(name)),),
            LocalMath.Reduce(eltype(field), _checkerboard_tracker_reduce;
                maximum = 2chunk_count,
                seed = LocalMath.ExistingSeed(),
                order = LocalMath.CanonicalLeftFold())),),
        LocalMath.Evaluator(evaluator),
        LocalMath.Control(;
            prefix = accepted.batch_size, gate = terminal_gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = Symbol(label_prefix, :_publication)),
    )
    return (
        LocalMath.LocalLaw(stage),
        _checkerboard_scalar_tracker_laws(
            accepted, field, remaining,
            first_column + chunk_count, owner_capacity, terminal_gate,
            label_prefix)...,
    )
end

function _checkerboard_moment_tracker_laws(
        accepted,
        field,
        components::Tuple,
        ::Type{T},
        component_count::Integer,
        owner_capacity::Integer,
        terminal_gate,
        label_prefix::Symbol,
    ) where {T}
    isempty(components) && return ()
    chunk_count = min(length(components), 16)
    chunk = ntuple(index -> components[index], chunk_count)
    remaining = length(components) == chunk_count ? () :
        ntuple(index -> components[chunk_count + index],
            length(components) - chunk_count)
    name = Symbol(label_prefix, :_, first(chunk)[1])
    relation = LocalMath.RuntimeRelation(
        accepted.source_space => field.space;
        degree_bound = 2chunk_count, key_type = Int32)
    evaluator = _CheckerboardMomentTrackerEvaluator{
        name,chunk,T,typeof(accepted.shape)}(
            accepted.shape, Int32(owner_capacity),
            Int32(component_count))
    stage = LocalMath.Stage(
        accepted.source_space,
        _checkerboard_tracker_reads(accepted, ()),
        (LocalMath.Publication((LocalMath.FieldPublication(
            field, relation, LocalMath.PublicationValue(name)),),
            LocalMath.Reduce(T, +;
                maximum = 2chunk_count,
                seed = LocalMath.ExistingSeed(),
                order = LocalMath.CanonicalLeftFold())),),
        LocalMath.Evaluator(evaluator),
        LocalMath.Control(;
            prefix = accepted.batch_size, gate = terminal_gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__;
            label = Symbol(label_prefix, :_publication)),
    )
    return (
        LocalMath.LocalLaw(stage),
        _checkerboard_moment_tracker_laws(
            accepted, field, remaining, T, component_count, owner_capacity,
            terminal_gate, label_prefix)...,
    )
end

function _checkerboard_tracker_group(
        accepted, descriptor, value, tracker_index::Integer,
        owner_capacity::Integer, terminal_gate)
    if descriptor isa DenseScalarTrackerGroup
        descriptors = Tuple(descriptor.descriptors)
        source_fields = map(enumerate(descriptors)) do indexed
            column, instance = indexed
            match = findfirst(==(instance), accepted.tracker_descriptors)
            match === nothing ? _checkerboard_tracker_field(view(value, :, column)) :
                getfield(accepted.tracker_source_fields, match)
        end
        paths = ntuple(length(source_fields)) do column
            findfirst(==(descriptors[column]), accepted.tracker_descriptors) ===
                nothing ? Int32(column) : nothing
        end
        return _checkerboard_transactional_tracker_group(
            tracker_index, source_fields, paths, terminal_gate) do fields
            Tuple(law for (column, field) in enumerate(fields)
                for law in _checkerboard_scalar_tracker_laws(
                    accepted, field, (descriptors[column],), 1,
                    owner_capacity, terminal_gate,
                    Symbol(:checkerboard_tracker_, tracker_index, :_, column)))
        end
    elseif descriptor isa OwnershipCountTracker
        return _checkerboard_transactional_tracker_group(
            tracker_index, (accepted.cell_volumes,), (nothing,),
            terminal_gate) do fields
            _checkerboard_scalar_tracker_laws(
                accepted, only(fields), (descriptor,), 1, owner_capacity,
                terminal_gate, Symbol(:checkerboard_tracker_, tracker_index))
        end
    elseif tracker_storage(descriptor) isa DenseOwnerScalarStorage
        if !(descriptor isa Union{OwnershipCountTracker,CellSurfaceTracker})
            target_type = CartesianIndex{length(accepted.shape)}
            hasmethod(tracker_ownership_delta, Tuple{
                typeof(descriptor),target_type,Int32,Int32}) || throw(
                ArgumentError(
                    "custom checkerboard scalar tracker delta must be " *
                    "computable from its descriptor, target, and owners"))
        end
        match = findfirst(==(descriptor), accepted.tracker_descriptors)
        source = match === nothing ? _checkerboard_tracker_field(value) :
            getfield(accepted.tracker_source_fields, match)
        return _checkerboard_transactional_tracker_group(
            tracker_index, (source,),
            (match === nothing ? :self : nothing,), terminal_gate) do fields
            _checkerboard_scalar_tracker_laws(
                accepted, only(fields), (descriptor,), 1, owner_capacity,
                terminal_gate, Symbol(:checkerboard_tracker_, tracker_index))
        end
    elseif descriptor isa CellMomentsTracker
        if accepted.moment_descriptor == descriptor
            dimensions = typeof(descriptor).parameters[1]
            first_fields = ntuple(
                index -> getfield(accepted.moment_source_fields, index),
                dimensions)
            second_fields = ntuple(
                index -> getfield(
                    accepted.moment_source_fields, dimensions + index),
                dimensions * dimensions)
            paths = ntuple(_ -> nothing, dimensions + dimensions * dimensions)
            return _checkerboard_transactional_tracker_group(
                tracker_index, (first_fields..., second_fields...), paths,
                terminal_gate) do fields
                first_targets = ntuple(index -> fields[index], dimensions)
                second_targets = ntuple(index -> fields[dimensions + index],
                    dimensions * dimensions)
                first_laws = Tuple(law
                    for (row, field) in enumerate(first_targets)
                    for law in _checkerboard_moment_tracker_laws(
                        accepted, field,
                        ((Int32(1), Int32(row), Int32(0)),),
                        eltype(value.first), 1, owner_capacity, terminal_gate,
                        Symbol(:checkerboard_tracker_, tracker_index,
                            :_first_, row)))
                second_laws = Tuple(law
                    for (slot, field) in enumerate(second_targets)
                    for law in _checkerboard_moment_tracker_laws(
                        accepted, field,
                        ((Int32(1), Int32(mod1(slot, dimensions)),
                            Int32(fld(slot - 1, dimensions) + 1)),),
                        eltype(value.second), 1, owner_capacity, terminal_gate,
                        Symbol(:checkerboard_tracker_, tracker_index,
                            :_second_, slot)))
                (first_laws..., second_laws...)
            end
        end
        first_field = _checkerboard_tracker_field(value.first)
        second_field = _checkerboard_tracker_field(value.second)
        dimensions = size(value.first, 1)
        first_components = ntuple(
            row -> (Int32(row), Int32(row), Int32(0)), dimensions)
        second_components = ntuple(dimensions * dimensions) do slot
            row = mod1(slot, dimensions)
            column = fld(slot - 1, dimensions) + 1
            (Int32(slot), Int32(row), Int32(column))
        end
        return _checkerboard_transactional_tracker_group(
            tracker_index, (first_field, second_field), (:first, :second),
            terminal_gate) do fields
            first_laws = _checkerboard_moment_tracker_laws(
                accepted, fields[1], first_components, eltype(value.first),
                dimensions, owner_capacity, terminal_gate,
                Symbol(:checkerboard_tracker_, tracker_index, :_first))
            second_laws = _checkerboard_moment_tracker_laws(
                accepted, fields[2], second_components, eltype(value.second),
                dimensions * dimensions, owner_capacity, terminal_gate,
                Symbol(:checkerboard_tracker_, tracker_index, :_second))
            (first_laws..., second_laws...)
        end
    end
    throw(ArgumentError(
        "checkerboard LocalMath commit does not support tracker entry " *
        string(typeof(descriptor))))
end

function _checkerboard_tracker_groups(
        accepted, tracker_plan, tracker_state, terminal_gate,
        owner_capacity::Integer)
    length(tracker_plan.descriptors) == length(tracker_state.values) ||
        throw(ArgumentError(
            "checkerboard tracker plan and state are misaligned"))
    return map(eachindex(tracker_plan.descriptors)) do index
        _checkerboard_tracker_group(
            accepted, tracker_plan.descriptors[index],
            tracker_state.values[index], index, owner_capacity, terminal_gate)
    end |> Tuple
end

@inline function _checkerboard_optional_pair(read, ::Type{T}) where {T}
    left = @inbounds read[1]
    right = @inbounds read[2]
    return (
        left.present ? convert(T, something(left.value)) : zero(T),
        right.present ? convert(T, something(right.value)) : zero(T),
    )
end

function _checkerboard_relationship_endpoint_fields(
        source::LocalMath.Space, term_count::Integer)
    names = Symbol[]
    fields = Any[]
    for index in 1:term_count
        push!(names, Symbol(:relationship_, index, :_endpoint_status))
        push!(fields, LocalMath.Field(source, Tuple{Int16,Int16}))
        push!(names, Symbol(:relationship_, index, :_endpoint_generations))
        push!(fields, LocalMath.Field(source, Tuple{UInt32,UInt32}))
    end
    return NamedTuple{Tuple(names)}(Tuple(fields))
end

function _checkerboard_relationship_endpoint_accesses(accepted, term_fields)
    names = Symbol[]
    accesses = Any[]
    for (index, fields) in enumerate(term_fields)
        relation = LocalMath.IndexRelation(
            fields.endpoints => accepted.cell_space; optional = true)
        push!(names, Symbol(:relationship_, index, :_status))
        push!(accesses, LocalMath.Access(
            accepted.cell_kinds, relation; required = false))
        push!(names, Symbol(:relationship_, index, :_generations))
        push!(accesses, LocalMath.Access(
            accepted.cell_generations, relation; required = false))
    end
    return NamedTuple{Tuple(names)}(Tuple(accesses))
end

@generated function (::_CheckerboardRelationshipEndpointEvaluator{Names})(
        item::Int32, reads, parameters) where {Names}
    outputs = Expr[]
    for index in 1:(length(Names) ÷ 2)
        push!(outputs, :(LocalMath.UniqueValue(
            _checkerboard_optional_pair(
                getfield(reads, $(2index - 1)), Int16))))
        push!(outputs, :(LocalMath.UniqueValue(
            _checkerboard_optional_pair(
                getfield(reads, $(2index)), UInt32))))
    end
    return :(NamedTuple{$(QuoteNode(Names))}(($(outputs...),)))
end

@generated function (evaluator::_CheckerboardRelationshipFoldEvaluator{
        P,Terms})(item::Int32, reads, parameters) where {P,Terms<:Tuple}
    branches = Expr(:block)
    term_count = fieldcount(Terms)
    for lane in 1:term_count
        offset = 2 + (lane - 1) * (P + 4)
        payload = [:(something(@inbounds getfield(
            reads, $(offset + 1 + index))[1].value)) for index in 1:P]
        status_index = offset + P + 2
        generation_index = status_index + 1
        condition = lane == term_count ? :(true) :
            :(request_lane == $(Int32(lane)))
        push!(branches.args, quote
            if $condition
                local term = getfield(evaluator.terms, $lane)
                local code = something(
                    @inbounds getfield(reads, $offset)[1].value)
                local endpoints = something(
                    @inbounds getfield(reads, $(offset + 1))[1].value)
                local statuses = something(
                    @inbounds getfield(reads, $status_index)[1].value)
                local generations = something(
                    @inbounds getfield(reads, $generation_index)[1].value)
                local disposition = something(
                    @inbounds getfield(reads, 1)[1].value)
                local enabled =
                    disposition == _PROGRAM_CHECKERBOARD_ACCEPTED &&
                    code == _ACCEPTED_RELATIONSHIP_READY
                return (event = LocalMath.FoldValue((
                    term.bank_slot,
                    getfield(endpoints, 1), getfield(endpoints, 2),
                    getfield(generations, 1), getfield(generations, 2),
                    $(payload...),
                    term.relationship_slot,
                    term.priority,
                    UInt32((candidate - Int32(1)) *
                        evaluator.accepted_count +
                        term.descriptor_ordinal),
                    getfield(statuses, 1), getfield(statuses, 2),
                    enabled,
                )),)
            end
        end)
    end
    return quote
        local request_lane = Int32(mod(item - Int32(1), $term_count) + 1)
        local candidate = Int32(fld(item - Int32(1), $term_count) + 1)
        $branches
    end
end

@generated function (::_CheckerboardRelationshipOrderKey{P})(value) where {P}
    logical_slot = 6 + P
    priority = logical_slot + 1
    enabled = logical_slot + 5
    return quote
        getfield(value, $enabled) || return (
            typemax(Int32), typemax(Int32), typemax(Int32), typemax(Int32))
        local a, b = _canonical_endpoints(
            getfield(value, 2), getfield(value, 3))
        return (getfield(value, $logical_slot),
            getfield(value, $priority), a, b)
    end
end

@generated function (::_CheckerboardRelationshipOrderIdentity{P})(
        value) where {P}
    order_identity = 8 + P
    return :(getfield(value, $order_identity))
end

@generated function (transition::_CheckerboardCompiledRelationshipTransition{P})(
        state, value, item::Int32, reads) where {P}
    payload_names = ntuple(index -> Symbol(:payload_, index), P)
    names = (
        :active,
        :endpoint_a,
        :endpoint_b,
        :generation_a,
        :generation_b,
        payload_names...,
        :degree,
        :incident_edges,
    )
    logical_slot = 6 + P
    priority = logical_slot + 1
    order_identity = priority + 1
    status_a = order_identity + 1
    status_b = status_a + 1
    enabled = status_b + 1
    incident_values = Symbol[]
    incident_initializers = Expr[]
    for lane in 1:_CHECKERBOARD_RELATIONSHIP_INCIDENT_WRITES
        value_name = Symbol(:incident_write_, lane)
        push!(incident_values, value_name)
        push!(incident_initializers, :($value_name = apply ?
            _checkerboard_fold_incident_write(
                state, fold_reads, slot, a, position_a, degree_a,
                b, position_b, degree_b, available_edge, $(Int32(lane))) :
            (Int32(1), Int32(0))))
    end
    incident_keys = Expr(:tuple,
        [:(getfield($value_name, 1)) for value_name in incident_values]...)
    incident_replacements = Expr(:tuple,
        [:(getfield($value_name, 2)) for value_name in incident_values]...)
    payload_updates = map(1:P) do index
        :(LocalMath.BoundedWrites(
            (flat_edge,), (getfield(value, $(5 + index)),), write_count))
    end
    payload_comparisons = map(1:P) do index
        payload_name = QuoteNode(payload_names[index])
        :(isequal(
            @inbounds(getproperty(state, $payload_name)[existing_flat]),
            getfield(value, $(5 + index)),
        ))
    end
    payload_matches = isempty(payload_comparisons) ? :(true) :
        foldl((left, right) -> :($left && $right), payload_comparisons)
    updates = Any[
        :(LocalMath.BoundedWrites(
            (active_key,), (true,), active_write_count)),
        :(LocalMath.BoundedWrites((flat_edge,), (a,), write_count)),
        :(LocalMath.BoundedWrites((flat_edge,), (b,), write_count)),
        :(LocalMath.BoundedWrites(
            (flat_edge,), (generation_a,), write_count)),
        :(LocalMath.BoundedWrites(
            (flat_edge,), (generation_b,), write_count)),
        payload_updates...,
        :(LocalMath.BoundedWrites(
            (
                _checkerboard_fold_degree_index(fold_reads, slot, a),
                _checkerboard_fold_degree_index(fold_reads, slot, b),
            ),
            (Int16(degree_a + Int32(1)), Int16(degree_b + Int32(1))),
            apply ? Int32(2) : Int32(0))),
        :(LocalMath.BoundedWrites(
            $incident_keys, $incident_replacements, incident_count)),
    ]
    update_tuple = Expr(:tuple, updates...)
    return quote
        local endpoint_a = getfield(value, 2)
        local endpoint_b = getfield(value, 3)
        local schema = transition.schema
        local fold_reads = (
            edge_offsets = getfield(schema, 1),
            edge_counts = getfield(schema, 2),
            endpoint_offsets = getfield(schema, 3),
            endpoint_counts = getfield(schema, 4),
            incident_offsets = getfield(schema, 5),
            maximum_degrees = getfield(schema, 6),
        )
        local slot = getfield(value, 1)
        local a, b = _canonical_endpoints(endpoint_a, endpoint_b)
        local generation_a, generation_b = endpoint_a == a ?
            (getfield(value, 4), getfield(value, 5)) :
            (getfield(value, 5), getfield(value, 4))
        local endpoint_status_a, endpoint_status_b = endpoint_a == a ?
            (getfield(value, $status_a), getfield(value, $status_b)) :
            (getfield(value, $status_b), getfield(value, $status_a))
        local admission = !getfield(value, $enabled) ?
            _RELATIONSHIP_CREATE_INACTIVE_ENDPOINT :
            endpoint_a == endpoint_b ?
            _RELATIONSHIP_CREATE_SELF_EDGE : iszero(endpoint_status_a) ||
            iszero(endpoint_status_b) ?
            _RELATIONSHIP_CREATE_INACTIVE_ENDPOINT :
            _RELATIONSHIP_CREATE_APPLY
        local existing = Int32(0)
        if admission == _RELATIONSHIP_CREATE_APPLY
            existing = _checkerboard_fold_relationship_edge(
                state, fold_reads, slot, a, b)
            if existing > 0
                local existing_flat =
                    _checkerboard_fold_edge_offset(fold_reads, slot) +
                    existing - Int32(1)
                admission = @inbounds(
                    state.generation_a[existing_flat] == generation_a &&
                    state.generation_b[existing_flat] == generation_b) &&
                    $payload_matches ?
                    _RELATIONSHIP_CREATE_IDEMPOTENT :
                    _RELATIONSHIP_CREATE_CONTRADICTORY
            end
        end
        local degree_a = admission == _RELATIONSHIP_CREATE_APPLY ?
            Int32(@inbounds state.degree[
                _checkerboard_fold_degree_index(fold_reads, slot, a)]) :
            Int32(0)
        local degree_b = admission == _RELATIONSHIP_CREATE_APPLY ?
            Int32(@inbounds state.degree[
                _checkerboard_fold_degree_index(fold_reads, slot, b)]) :
            Int32(0)
        local maximum_degree =
            _checkerboard_fold_maximum_degree(fold_reads, slot)
        if admission == _RELATIONSHIP_CREATE_APPLY &&
                (degree_a >= maximum_degree || degree_b >= maximum_degree)
            admission = _RELATIONSHIP_CREATE_MAXIMUM_DEGREE
        end
        local available_edge = admission == _RELATIONSHIP_CREATE_APPLY ?
            _checkerboard_fold_available_edge(state, fold_reads, slot) :
            Int32(0)
        if admission == _RELATIONSHIP_CREATE_APPLY && available_edge <= 0
            admission = _RELATIONSHIP_CREATE_CAPACITY
        end
        local apply = admission == _RELATIONSHIP_CREATE_APPLY
        local contradictory =
            admission == _RELATIONSHIP_CREATE_CONTRADICTORY
        local flat_edge = apply ?
            _checkerboard_fold_edge_offset(fold_reads, slot) +
            available_edge - Int32(1) : Int32(1)
        local position_a = apply ?
            _checkerboard_fold_insertion_position(
                state, fold_reads, slot, a, available_edge, degree_a) :
            Int32(1)
        local position_b = apply ?
            _checkerboard_fold_insertion_position(
                state, fold_reads, slot, b, available_edge, degree_b) :
            Int32(1)
        $(incident_initializers...)
        local incident_count = apply ?
            degree_a - position_a + degree_b - position_b + Int32(4) :
            Int32(0)
        local write_count = apply ? Int32(1) : Int32(0)
        # Use the fold protocol's invalid key to reject a contradictory
        # duplicate without publishing any relationship-bank writes.
        local active_key = contradictory ? Int32(0) : flat_edge
        local active_write_count = apply || contradictory ?
            Int32(1) : Int32(0)
        local updates = NamedTuple{$(QuoteNode(names))}($update_tuple)
        return LocalMath.FoldStep(updates)
    end
end

struct _CheckerboardImmutableRelationshipSchema{EO,EC,PO,PC,IO,MD}
    edge_offsets::EO
    edge_counts::EC
    endpoint_offsets::PO
    endpoint_counts::PC
    incident_offsets::IO
    maximum_degrees::MD
end

function _checkerboard_immutable_relationship_schema(bank)
    schema = _packed_relationship_schema(bank)
    schema_values = map(Base.values(schema)) do array
        Tuple(Int32.(Adapt.adapt(Array, array)))
    end
    return _CheckerboardImmutableRelationshipSchema(schema_values...)
end

function _checkerboard_relationship_state_fields(bank)
    science = _packed_relationship_science(bank)
    spaces = Dict{Int,Any}()
    fields = map(values(science)) do array
        space = get!(spaces, length(array)) do
            LocalMath.Space(length(array))
        end
        LocalMath.Field(space, eltype(array))
    end
    return NamedTuple{keys(science)}(fields)
end

function _checkerboard_relationship_groups(
        accepted, relationships, bank_field_authorities, terminal_gate)
    isempty(accepted.accepted_relationship_terms) && return ()
    field_groups = _accepted_relationship_field_groups(
        accepted.accepted_relationship_fields,
        accepted.accepted_relationship_terms)
    bank_indices = Int32[]
    for term in accepted.accepted_relationship_terms
        term.bank_index in bank_indices || push!(bank_indices, term.bank_index)
    end
    groups = map(bank_indices) do bank_index
        term_indices = Tuple(index for index in eachindex(
            accepted.accepted_relationship_terms)
            if accepted.accepted_relationship_terms[index].bank_index ==
                bank_index)
        terms = map(index -> accepted.accepted_relationship_terms[index],
            term_indices)
        term_fields = map(index -> field_groups[index], term_indices)
        payload_zero = first(terms).payload_zero
        all(term -> map(typeof, term.payload_zero) == map(typeof, payload_zero),
            terms) || throw(ArgumentError(
                "relationship terms sharing a packed bank have inconsistent payload schemas"))
        request_count = Base.Checked.checked_mul(
            length(accepted.source_space), length(terms))
        request_space = LocalMath.Space(request_count)
        endpoint_fields = _checkerboard_relationship_endpoint_fields(
            accepted.source_space, length(terms))
        endpoint_accesses = _checkerboard_relationship_endpoint_accesses(
            accepted, term_fields)
        endpoint_identity = LocalMath.IdentityRelation(accepted.source_space)
        endpoint_publications = map(
                keys(endpoint_fields), values(endpoint_fields)) do name, field
            LocalMath.Publication((LocalMath.FieldPublication(
                field, endpoint_identity, LocalMath.PublicationValue(name)),),
                _checkerboard_scratch_unique(eltype(field)))
        end
        endpoint_stage = LocalMath.Stage(
            accepted.source_space,
            endpoint_accesses,
            endpoint_publications,
            LocalMath.Evaluator(
                _CheckerboardRelationshipEndpointEvaluator{
                    keys(endpoint_fields)}()),
            LocalMath.Control(;
                prefix = accepted.batch_size, gate = terminal_gate),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__;
                label = :checkerboard_relationship_endpoints),
        )
        bank = relationships.banks[Int(bank_index)]
        bank isa PackedRelationshipBank || throw(ArgumentError(
            "checkerboard relationship compilation requires packed banks"))
        live_fields = bank_field_authorities[Int(bank_index)]
        shadow_fields = NamedTuple{keys(live_fields)}(map(values(live_fields)) do field
            LocalMath.Field(field.space, eltype(field))
        end)
        state = LocalMath.InitializedState(; map(
            (shadow, live) -> LocalMath.FoldComponent(shadow; from = live),
            shadow_fields, live_fields)...)
        payload_count = length(payload_zero)
        fold_value_type = Tuple{
            Int32,Int32,Int32,UInt32,UInt32,
            map(typeof, payload_zero)...,
            Int32,Int32,UInt32,Int16,Int16,Bool,
        }
        transition = _CheckerboardCompiledRelationshipTransition{
            payload_count,
            typeof(_checkerboard_immutable_relationship_schema(bank))}(
                _checkerboard_immutable_relationship_schema(bank))
        fold = LocalMath.OrderedFold(
            fold_value_type, state, transition;
            order = LocalMath.canonical_by(
                _CheckerboardRelationshipOrderKey{payload_count}(),
                _CheckerboardRelationshipOrderIdentity{payload_count}()))
        candidate_relation = LocalMath.FixedRelation(
            request_space => accepted.source_space; degree = 1)
        access_names = Symbol[:disposition]
        access_values = Any[LocalMath.Access(
            accepted.disposition, candidate_relation; required = true)]
        for (index, fields) in enumerate(term_fields)
            prefix = Symbol(:relationship_, index)
            push!(access_names, Symbol(prefix, :_code))
            push!(access_values, LocalMath.Access(
                fields.code, candidate_relation; required = true))
            push!(access_names, Symbol(prefix, :_endpoints))
            push!(access_values, LocalMath.Access(
                fields.endpoints, candidate_relation; required = true))
            for (payload_index, field) in enumerate(fields.payload)
                push!(access_names, Symbol(prefix, :_payload_, payload_index))
                push!(access_values, LocalMath.Access(
                    field, candidate_relation; required = true))
            end
            push!(access_names, Symbol(prefix, :_status))
            push!(access_values, LocalMath.Access(
                getfield(endpoint_fields, 2index - 1),
                candidate_relation; required = true))
            push!(access_names, Symbol(prefix, :_generations))
            push!(access_values, LocalMath.Access(
                getfield(endpoint_fields, 2index),
                candidate_relation; required = true))
        end
        fold_accesses = NamedTuple{Tuple(access_names)}(Tuple(access_values))
        fold_stage = LocalMath.Stage(
            request_space,
            fold_accesses,
            (LocalMath.Publication((LocalMath.FoldPublication(
                LocalMath.PublicationValue(:event)),), fold),),
            LocalMath.Evaluator(
                _CheckerboardRelationshipFoldEvaluator{
                    payload_count,typeof(terms)}(
                        terms, Int32(accepted.accepted_count))),
            LocalMath.Control(; gate = terminal_gate),
            LocalMath.SourceOrigin(@__FILE__, @__LINE__;
                label = :checkerboard_relationship_settlement),
        )
        return (;
            bank_index, terms, request_space, endpoint_fields,
            candidate_relation, live_fields, shadow_fields,
            law = LocalMath.sequence(
                LocalMath.LocalLaw(endpoint_stage),
                LocalMath.LocalLaw(fold_stage)))
    end
    return Tuple(groups)
end


function _checkerboard_field_copy_law(source::LocalMath.Field,
        destination::LocalMath.Field, gate, label::Symbol)
    source.space == destination.space ||
        throw(ArgumentError(
            "checkerboard transactional field copies require identical spaces"))
    identity = LocalMath.IdentityRelation(source.space)
    evaluator = eltype(source) === eltype(destination) ?
        _ProgramStateCopyEvaluator() :
        _CheckerboardFieldConvertEvaluator{eltype(destination)}()
    stage = LocalMath.Stage(
        source.space,
        (source = LocalMath.Access(source, identity; required = true),),
        (LocalMath.Publication((LocalMath.FieldPublication(
            destination, identity, LocalMath.PublicationValue(:value)),),
            LocalMath.Unique(eltype(destination))),),
        LocalMath.Evaluator(evaluator),
        gate === nothing ? LocalMath.Control() : LocalMath.Control(; gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__; label),
    )
    return LocalMath.LocalLaw(stage)
end

function _checkerboard_relationship_commit_laws(groups, gate)
    return Tuple(_checkerboard_field_copy_law(shadow, live, gate,
            Symbol(:checkerboard_relationship_commit_, group.bank_index,
                :_, name))
        for group in groups
        for (name, shadow, live) in zip(keys(group.shadow_fields),
            values(group.shadow_fields), values(group.live_fields)))
end
