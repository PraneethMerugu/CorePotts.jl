const _ContactPairKey = Tuple{Int32, UInt32, Int32, UInt32}
const _ContactIncidenceKey = Tuple{Int32, UInt32, Int32, UInt32, Int32}
const _ContactSiteKey = Tuple{Int32, UInt32, UInt32, Int32, UInt32}

@inline _contact_pair_key(
        a_owner::Int32, a_generation::UInt32,
        b_owner::Int32, b_generation::UInt32,
    ) = (a_owner < b_owner ||
         (a_owner == b_owner && a_generation <= b_generation)) ?
    (a_owner, a_generation, b_owner, b_generation) :
    (b_owner, b_generation, a_owner, a_generation)

struct _ContactSite end
const _ContactSiteIdentity = Tuple{UInt32, Int32, UInt32}

struct _ContactPairEvaluator{W} end
struct _ContactSiteEvaluator{W} end
struct _ContactIncidenceFold end
struct _ContactSiteFold end

@inline (::_ContactIncidenceFold)(left::Int32, right::Int32) = left + right
@inline (::_ContactSiteFold)(left::Int32, right::Int32) = max(left, right)

@inline function _contact_pair_contribution(
        center::_ContactSiteIdentity,
        neighbor::_ContactSiteIdentity,
        ::Val{L},
    ) where {L}
    participates =
        (center[2] != neighbor[2] || center[3] != neighbor[3]) &&
        center[1] < neighbor[1]
    key = participates ?
        _contact_pair_key(center[2], center[3], neighbor[2], neighbor[3]) :
        (Int32(0), UInt32(0), Int32(0), UInt32(0))
    return LocalMath.KeyedContribution(
        (key..., Int32(L)), Int32(1), participates,
    )
end

@inline function _contact_site_contribution(
        center::_ContactSiteIdentity,
        neighbor::_ContactSiteIdentity,
    )
    participates = center[2] != neighbor[2] || center[3] != neighbor[3]
    key = participates ?
        (center[2], center[3], center[1], neighbor[2], neighbor[3]) :
        (Int32(0), UInt32(0), UInt32(0), Int32(0), UInt32(0))
    return LocalMath.KeyedContribution(key, Int32(1), participates)
end

@inline _missing_contact_site_contribution() = LocalMath.KeyedContribution(
    (Int32(0), UInt32(0), UInt32(0), Int32(0), UInt32(0)), Int32(1), false)

@inline function _missing_contact_pair_contribution(::Val{L}) where {L}
    return LocalMath.KeyedContribution(
        (Int32(0), UInt32(0), Int32(0), UInt32(0),
         Int32(L)),
        Int32(1),
        false,
    )
end

@generated function (evaluator::_ContactSiteEvaluator{W})(
        item::Int32, reads, parameters,
    ) where {W}
    lanes = map(1:W) do lane
        quote
            local neighbor = @inbounds getfield(reads, 2)[$lane].value
            neighbor === nothing ? _missing_contact_site_contribution() :
                _contact_site_contribution(center, neighbor)
        end
    end
    return quote
        local center = something(@inbounds getfield(reads, 1)[1].value)
        (; contribution = ($(lanes...),))
    end
end

@generated function (evaluator::_ContactPairEvaluator{W})(
        item::Int32, reads, parameters,
    ) where {W}
    lanes = map(1:W) do lane
        quote
            local neighbor = @inbounds getfield(reads, 2)[$lane].value
            if neighbor === nothing
                _missing_contact_pair_contribution(Val($lane))
            else
                _contact_pair_contribution(
                    center, neighbor, Val($lane),
                )
            end
        end
    end
    return quote
        local center = something(@inbounds getfield(reads, 1)[1].value)
        (; contribution = ($(lanes...),))
    end
end

function _contact_relation_lanes(
        resources::HamiltonianDomainResources,
        relation_handle::Int32,
        shape::NTuple{N, Int},
        periodic::NTuple{N, Bool},
    ) where {N}
    start, count = _contact_domain_columns(resources, relation_handle)
    count <= 32 || throw(ArgumentError(
        "contact-pair maintenance requires at most 32 relation lanes"
    ))
    site_count = foldl(Base.Checked.checked_mul, shape; init = 1)
    site_count <= div(typemax(Int32), max(Int(count), 1)) || throw(ArgumentError(
        "contact-pair bond multiplicity exceeds the exact Int32 bound"
    ))
    offsets = ntuple(Int(count)) do lane
        ntuple(N) do dimension
            Int(@inbounds resources.contact_offsets[
                dimension, Int(start) + lane - 1
            ])
        end
    end
    return offsets
end

function _contact_relation_measures(
        resources::HamiltonianDomainResources,
        relation_handle::Int32,
    )
    start, count = _contact_domain_columns(resources, relation_handle)
    return ntuple(
        lane -> resources.contact_measures[Int(start) + lane - 1],
        Int(count),
    )
end

function _validate_contact_pair_relation(
        offsets::Tuple,
        measures::Tuple,
        shape::NTuple{N, Int},
        periodic::NTuple{N, Bool},
    ) where {N}
    W = length(offsets)
    length(measures) == W && all(offset -> length(offset) == N, offsets) ||
        throw(ArgumentError("contact-pair lanes and measures have incompatible shapes"))
    for lane in 1:W
        inverse = findfirst(1:W) do candidate
            all(1:N) do dimension
                left = offsets[candidate][dimension]
                right = -offsets[lane][dimension]
                periodic[dimension] ?
                    mod(left, shape[dimension]) == mod(right, shape[dimension]) :
                    left == right
            end
        end
        inverse === nothing && throw(ArgumentError(
            "contact-pair maintenance requires a reciprocal lane for offset " *
            repr(offsets[lane])
        ))
        isequal(measures[inverse], measures[lane]) || throw(ArgumentError(
            "reciprocal contact-pair lanes must carry the same declared measure"
        ))
    end
    return nothing
end

function _validate_spatial_metric_relation(
        resources::HamiltonianDomainResources,
        relation_handle::Int32,
        metric_handle::Int32,
        shape::NTuple{N, Int},
        periodic::NTuple{N, Bool},
    ) where {N}
    relation_start, relation_count = _contact_domain_columns(
        resources, relation_handle)
    metric_start, metric_count = _contact_domain_columns(
        resources, metric_handle)
    relation_count == metric_count || throw(ArgumentError(
        "a spatial-query metric must have the authoritative relation's lane count"))
    for lane in 1:Int(relation_count), dimension in 1:N
        relation_offset = Int(@inbounds resources.contact_offsets[
            dimension, Int(relation_start) + lane - 1])
        metric_offset = Int(@inbounds resources.contact_offsets[
            dimension, Int(metric_start) + lane - 1])
        same = periodic[dimension] ?
            mod(relation_offset, shape[dimension]) ==
                mod(metric_offset, shape[dimension]) :
            relation_offset == metric_offset
        same || throw(ArgumentError(
            "a spatial-query metric must preserve authoritative relation lane order"))
    end
    return nothing
end

"""Maintain reusable contact topology for one compiled spatial relation."""
struct SpatialRelationQueryTracker{Q <: QualifiedTrackerKey} <:
       AbstractTrackerDescriptor
    quantity::Q
    relation_handle::Int32
    maximum_pairs::Int32
    maximum_contacts::Int32
    maximum_sites::Int32

    function SpatialRelationQueryTracker(
            quantity::Q, relation_handle::Integer;
            maximum_pairs::Integer, maximum_contacts::Integer,
            maximum_sites::Integer,
        ) where {Q <: QualifiedTrackerKey}
        relation_handle > 0 && relation_handle <= typemax(Int32) ||
            throw(ArgumentError("spatial-relation source handles must be positive Int32 values"))
        quantity.source_handle == relation_handle || throw(ArgumentError(
            "spatial-query quantity and authoritative relation source must use the same handle"))
        maximum_pairs isa Bool && throw(ArgumentError(
            "spatial-query pair capacity must be an integer, not Bool"))
        maximum_sites isa Bool && throw(ArgumentError(
            "spatial-query site bound must be an integer, not Bool"))
        maximum_contacts isa Bool && throw(ArgumentError(
            "relation contact capacity must be an integer, not Bool"))
        0 <= maximum_pairs <= typemax(Int32) || throw(ArgumentError(
            "spatial-query pair capacity must be a nonnegative Int32 bound"))
        maximum_pairs <= div(typemax(Int32), 32) || throw(ArgumentError(
            "spatial-query pair capacity exceeds the 32-lane backend record bound"))
        0 <= maximum_sites <= typemax(Int32) || throw(ArgumentError(
            "spatial-query site bound must be a nonnegative Int32 bound"))
        0 <= maximum_contacts <= typemax(Int32) || throw(ArgumentError(
            "relation contact capacity must be a nonnegative Int32 bound"))
        return new{Q}(
            quantity, Int32(relation_handle), Int32(maximum_pairs),
            Int32(maximum_contacts), Int32(maximum_sites),
        )
    end
end

# The device law receives only its exact, cold-lowered relation semantics.
struct _BoundSpatialRelationQueryTracker{
        Q <: QualifiedTrackerKey, O <: Tuple,
    } <: AbstractTrackerDescriptor
    quantity::Q
    relation_handle::Int32
    maximum_pairs::Int32
    maximum_contacts::Int32
    maximum_sites::Int32
    offsets::O
end

"""Fixed-capacity exact keyed storage for generation-qualified owner pairs."""
struct SpatialRelationQueryStorage <: AbstractTrackerStorage
    maximum_pairs::Int32
    maximum_incidences::Int32
    maximum_contacts::Int32
end

@inline _maximum_spatial_incidences(maximum_pairs::Int32, lanes::Integer) =
    Base.Checked.checked_mul(maximum_pairs, Int32(lanes))

"""Runtime-owned publication for one maintained spatial-relation source."""
struct SpatialRelationQueryState{P, C}
    pairs::P
    contacts::C
end

"""Category of a settled spatial-query owner."""
@enum SpatialOwnerCategory::UInt8 begin
    FiniteCellOwner = 0x01
    MediumDomainOwner = 0x02
    WallDomainOwner = 0x03
end

@doc "Finite-cell owner category for settled spatial queries." FiniteCellOwner
@doc "Medium-domain owner category for settled spatial queries." MediumDomainOwner
@doc "Wall-domain owner category; wall query admission remains unsupported." WallDomainOwner

"""Selection law for owners read by a settled spatial query."""
@enum SpatialOwnerFilterKind::UInt8 begin
    StableOwnerIdentityFilter = 0x01
    CellKindOwnerFilter = 0x02
    MediumDomainIdentityFilter = 0x03
    OwnerCategoryFilter = 0x04
    PublishedOwnerPredicateFilter = 0x05
    WallDomainIdentityFilter = 0x06
end

@doc "Select one finite cell by its stable identity and generation." StableOwnerIdentityFilter
@doc "Select finite cells by their declared cell kind." CellKindOwnerFilter
@doc "Select a medium domain by its identity." MediumDomainIdentityFilter
@doc "Select owners by their declared category." OwnerCategoryFilter
@doc "Select owners using a maintained published state mask." PublishedOwnerPredicateFilter
@doc "Reserved wall-domain identity selector; admission is not yet supported." WallDomainIdentityFilter

"""Graph-independent owner-filter payload consumed by settled spatial queries."""
struct SpatialOwnerFilterRecipe{P}
    kind::SpatialOwnerFilterKind
    identity_owner::Int32
    identity_generation::UInt32
    kind_id::Int16
    category::SpatialOwnerCategory
    predicate_mask::P

    function SpatialOwnerFilterRecipe(
            kind::SpatialOwnerFilterKind;
            identity_owner::Integer = 0,
            identity_generation::Integer = 0,
            kind_id::Integer = 0,
            category::SpatialOwnerCategory = FiniteCellOwner,
            predicate_mask = nothing,
        )
        typemin(Int32) <= identity_owner <= typemax(Int32) || throw(
            ArgumentError("spatial owner identities must fit Int32"))
        0 <= identity_generation <= typemax(UInt32) || throw(
            ArgumentError("spatial owner generations must fit UInt32"))
        typemin(Int16) <= kind_id <= typemax(Int16) || throw(
            ArgumentError("spatial owner kinds must fit Int16"))
        kind === StableOwnerIdentityFilter &&
            (identity_owner <= 0 || iszero(identity_generation)) && throw(
                ArgumentError("stable finite-cell filters require a positive owner and generation"))
        kind === CellKindOwnerFilter && kind_id <= 0 && throw(
            ArgumentError("cell-kind filters require a positive kind"))
        kind === MediumDomainIdentityFilter && identity_owner > 0 && throw(
            ArgumentError("medium-domain filters require a nonpositive domain identity"))
        kind === PublishedOwnerPredicateFilter &&
            !(predicate_mask isa StateHandle) && throw(ArgumentError(
                "published-predicate filters require a maintained state mask"))
        kind === WallDomainIdentityFilter && throw(ArgumentError(
            "wall-domain filters require the not-yet-admitted fixed-owner topology contract"))
        category === WallDomainOwner && throw(ArgumentError(
            "wall-owner category filters require the not-yet-admitted fixed-owner topology contract"))
        return new{typeof(predicate_mask)}(
            kind, Int32(identity_owner), UInt32(identity_generation),
            Int16(kind_id), category, predicate_mask)
    end
end

"""Return the supplied value when a spatial mean has no contributors."""
struct ReturnEmptySpatialMean{T}
    value::T
end

"""Reject a spatial mean with no contributors."""
struct ErrorOnEmptySpatialMean end

"""Cold query selection with all capacities and identities retained as values."""
struct SpatialQueryRead{F, H, E}
    query_handle::Int32
    filter::F
    metric_handle::Int32
    property_handle::H
    empty::E
end

function SpatialQueryRead(
        query_handle::Integer,
        filter::SpatialOwnerFilterRecipe;
        metric_handle::Integer = 0,
        property_handle = nothing,
        empty = ErrorOnEmptySpatialMean(),
    )
    1 <= query_handle <= typemax(Int32) || throw(
        ArgumentError("spatial query handles must be positive Int32 values"))
    0 <= metric_handle <= typemax(Int32) || throw(
        ArgumentError("spatial metric handles must be nonnegative Int32 values"))
    return SpatialQueryRead{
        typeof(filter), typeof(property_handle), typeof(empty),
    }(
        Int32(query_handle), filter, Int32(metric_handle),
        property_handle, empty)
end

"""Read one settled global pair metric through left and right owner filters."""
struct GlobalSpatialQueryRead{L, R}
    query_handle::Int32
    left::L
    right::R
    metric_handle::Int32
    function GlobalSpatialQueryRead(
            query_handle::Integer,
            left::L,
            right::R,
            metric_handle::Integer,
        ) where {L <: SpatialOwnerFilterRecipe, R <: SpatialOwnerFilterRecipe}
        1 <= query_handle <= typemax(Int32) || throw(
            ArgumentError("spatial query handles must be positive Int32 values"))
        1 <= metric_handle <= typemax(Int32) || throw(
            ArgumentError("global spatial metrics require a positive handle"))
        return new{L, R}(
            Int32(query_handle), left, right, Int32(metric_handle))
    end
end

struct _CheckerboardSpatialRelationQueryGroup{L, F, P, C}
    tracker_index::Int32
    source_fields::Tuple{}
    fields::Tuple{}
    paths::Tuple{}
    initialization_laws::Tuple{}
    laws::L
    validation_laws::Tuple{}
    bindings::Tuple{}
    commit_laws::Tuple{}
    identities::F
    pairs::P
    contacts::C
end

Adapt.@adapt_structure SpatialRelationQueryState

function Base.copy(state::SpatialRelationQueryState)
    return SpatialRelationQueryState(
        _copy_spatial_query_collection(state.pairs),
        _copy_spatial_query_collection(state.contacts),
    )
end

function _copy_spatial_query_collection(source)
    backend = KernelAbstractions.get_backend(source.count)
    destination = LocalMath.CompactedStorage(
        backend, eltype(source.records), length(source.records))
    copyto!(destination.records, source.records)
    copyto!(destination.count, source.count)
    return destination
end

function Base.copyto!(
        destination::SpatialRelationQueryState,
        source::SpatialRelationQueryState,
    )
    _copyto_spatial_query_collection!(destination.pairs, source.pairs)
    _copyto_spatial_query_collection!(destination.contacts, source.contacts)
    return destination
end


function _copyto_spatial_query_collection!(destination, source)
    length(destination.records) == length(source.records) || throw(
        ArgumentError("spatial-query publications require matching capacities"))
    copyto!(destination.records, source.records)
    copyto!(destination.count, source.count)
    return destination
end

tracker_quantity(descriptor::SpatialRelationQueryTracker) = descriptor.quantity
tracker_quantity(descriptor::_BoundSpatialRelationQueryTracker) = descriptor.quantity
tracker_contract(descriptor::SpatialRelationQueryTracker) = TrackerContract(
    descriptor.quantity.quantity,
    OwnershipRelationTrackerSource(descriptor.relation_handle),
    SpatialRelationQueryStorage(
        descriptor.maximum_pairs,
        _maximum_spatial_incidences(descriptor.maximum_pairs, 32),
        descriptor.maximum_contacts),
    AcceptedCommitTrackerVisibility(),
    ClaimedOwnerExclusiveTrackerConcurrency(),
    FullLatticeReconstructionUpdateBound(descriptor.maximum_sites),
    ReconstructTrackerCheckpoint(),
    TrackerSupport(true, true, true, true),
    LatticeLinearTrackerCost(),
    LatticeLinearTrackerCost(),
)
tracker_contract(descriptor::_BoundSpatialRelationQueryTracker) =
    TrackerContract(
        descriptor.quantity.quantity,
        OwnershipRelationTrackerSource(descriptor.relation_handle),
        SpatialRelationQueryStorage(
            descriptor.maximum_pairs,
            _maximum_spatial_incidences(
                descriptor.maximum_pairs, length(descriptor.offsets)),
            descriptor.maximum_contacts),
        AcceptedCommitTrackerVisibility(),
        ClaimedOwnerExclusiveTrackerConcurrency(),
        FullLatticeReconstructionUpdateBound(descriptor.maximum_sites),
        ReconstructTrackerCheckpoint(),
        TrackerSupport(true, true, true, true),
        LatticeLinearTrackerCost(),
        LatticeLinearTrackerCost(),
    )
function _validate_tracker_descriptor(descriptor::SpatialRelationQueryTracker)
    isbits(descriptor) || throw(ArgumentError(
        "relation-pair tracker descriptors crossing the execution boundary must be isbits"))
    contract = tracker_contract(descriptor)
    contract.source.relation_handle == descriptor.relation_handle || throw(
        ArgumentError("relation-pair source metadata is inconsistent"))
    contract.visibility isa AcceptedCommitTrackerVisibility || throw(
        ArgumentError("relation-pair visibility must be accepted-commit"))
    contract.concurrency isa ClaimedOwnerExclusiveTrackerConcurrency || throw(
        ArgumentError("relation-pair updates require claimed-owner exclusion"))
    contract.update_bound isa FullLatticeReconstructionUpdateBound || throw(
        ArgumentError("relation-pair updates require bounded lattice reconstruction"))
    contract.checkpoint isa ReconstructTrackerCheckpoint || throw(
        ArgumentError("relation-pair checkpoints must reconstruct from authoritative state"))
    contract.proposal_cost isa LatticeLinearTrackerCost || throw(
        ArgumentError("relation-pair accepted updates must declare lattice-linear cost"))
    contract.rebuild_cost isa LatticeLinearTrackerCost || throw(
        ArgumentError("relation-pair rebuilds must declare lattice-linear cost"))
    return descriptor
end
_validate_tracker_descriptor(descriptor::_BoundSpatialRelationQueryTracker) = descriptor

function _bind_relation_pair_tracker(
        descriptor::SpatialRelationQueryTracker, resources, shape, periodic,
    )
    offsets = _contact_relation_lanes(
        resources, descriptor.relation_handle, shape, periodic)
    measures = _contact_relation_measures(resources, descriptor.relation_handle)
    _validate_contact_pair_relation(offsets, measures, shape, periodic)
    return _BoundSpatialRelationQueryTracker{
        typeof(descriptor.quantity), typeof(offsets),
    }(
        descriptor.quantity, descriptor.relation_handle,
        descriptor.maximum_pairs, descriptor.maximum_contacts,
        descriptor.maximum_sites, offsets,
    )
end

_bind_relation_pair_tracker(descriptor, resources, shape, periodic) = descriptor

function _bind_relation_pair_tracker_plan(plan, resources, shape, periodic)
    return TrackerKernelPlan(map(plan.descriptors) do descriptor
        _bind_relation_pair_tracker(descriptor, resources, shape, periodic)
    end)
end

function _bind_relation_pair_tracker_plan(
        plan::_AcceptedTrackerUpdatePlan, resources, shape, periodic,
    )
    descriptors = map(plan.descriptors) do descriptor
        _bind_relation_pair_tracker(descriptor, resources, shape, periodic)
    end
    return _AcceptedTrackerUpdatePlan(plan.state_indices, descriptors)
end
_tracker_storage_inspection(
    storage::SpatialRelationQueryStorage,
) = (
    storage = :spatial_relation_queries,
    element_type = Int32,
    maximum_pairs = storage.maximum_pairs,
    maximum_incidences = storage.maximum_incidences,
    maximum_contacts = storage.maximum_contacts,
)

function _validate_tracker_state(
        storage::SpatialRelationQueryStorage, state, cell_count,
    )
    state isa SpatialRelationQueryState || throw(ArgumentError(
        "relation-pair rebuild violates its keyed storage contract"))
    pairs = state.pairs
    contacts = state.contacts
    eltype(pairs.records) ===
        LocalMath.KeyedValue{_ContactIncidenceKey, Int32} ||
        throw(ArgumentError("relation-pair records have the wrong key or value type"))
    length(pairs.records) <= storage.maximum_incidences || throw(ArgumentError(
        "relation-pair records exceed the admitted incidence capacity"))
    eltype(contacts.records) === LocalMath.KeyedValue{_ContactSiteKey, Int32} ||
        throw(ArgumentError("relation contact records have the wrong key or value type"))
    length(contacts.records) == storage.maximum_contacts || throw(ArgumentError(
        "relation contact records have the wrong fixed capacity"))
    return state
end

@inline _tracker_state_to_host(to_host, value::SpatialRelationQueryState) =
    SpatialRelationQueryState(
        Adapt.adapt(Array, value.pairs), Adapt.adapt(Array, value.contacts))

function _tracker_recomputation_matches(
        ::SpatialRelationQueryTracker,
    actual::SpatialRelationQueryState,
    expected::SpatialRelationQueryState,
    )
    return _spatial_query_collections_match(actual.pairs, expected.pairs) &&
        _spatial_query_collections_match(actual.contacts, expected.contacts)
end

function _spatial_query_collections_match(actual, expected)
    left = Adapt.adapt(Array, actual)
    right = Adapt.adapt(Array, expected)
    left.count == right.count || return false
    count = Int(only(left.count))
    for left_index in 1:count
        left_record = @inbounds left.records[left_index]
        right_index = findfirst(1:count) do candidate
            @inbounds(right.records.key[candidate]) == left_record.key
        end
        right_index === nothing && return false
        @inbounds(right.records.value[right_index]) == left_record.value ||
            return false
    end
    return true
end

function _require_tracker_value_copy_compatible(
        destination::SpatialRelationQueryState,
        source::SpatialRelationQueryState,
    )
    eltype(destination.pairs.records) === eltype(source.pairs.records) &&
        length(destination.pairs.records) == length(source.pairs.records) &&
        eltype(destination.contacts.records) === eltype(source.contacts.records) &&
        length(destination.contacts.records) == length(source.contacts.records) ||
        throw(ArgumentError(
            "relation-pair publication requires matching key, value, and capacity"))
    return nothing
end

struct _ContactSiteIdentityEvaluator end

@inline function (::_ContactSiteIdentityEvaluator)(item::Int32, reads, parameters)
    owner = something(@inbounds getfield(reads, 1)[1].value)
    generation = owner > 0 ?
        something(@inbounds getfield(reads, 2)[1].value) : UInt32(0)
    return (; value = LocalMath.UniqueValue((
        UInt32(item), owner, generation,
    )))
end

function _spatial_relation_query_declaration(
        descriptor::Union{
            SpatialRelationQueryTracker,
            _BoundSpatialRelationQueryTracker,
        },
        resources::HamiltonianDomainResources,
        shape::NTuple{N, Int},
        periodic::NTuple{N, Bool},
        owner_capacity::Integer;
        ownership_field = nothing,
        generation_field = nothing,
        pair_destination = nothing,
        contact_destination = nothing,
        gate = nothing,
    ) where {N}
    prod(shape) <= descriptor.maximum_sites || throw(ArgumentError(
        "relation-pair tracker $(descriptor.quantity) requires at most " *
        "$(descriptor.maximum_sites) sites; lattice has $(prod(shape))"
    ))
    owner_capacity >= 0 || throw(ArgumentError(
        "relation-pair owner capacity cannot be negative"))
    offsets = if descriptor isa _BoundSpatialRelationQueryTracker
        descriptor.offsets
    else
        _validate_contact_measure_aliases(resources, shape, periodic)
        relation_offsets = _contact_relation_lanes(
            resources, descriptor.relation_handle, shape, periodic)
        measures = _contact_relation_measures(resources, descriptor.relation_handle)
        _validate_contact_pair_relation(
            relation_offsets, measures, shape, periodic)
        relation_offsets
    end

    domain = ownership_field === nothing ?
        LocalMath.Space(_ContactSite, shape) : ownership_field.space
    owners = generation_field === nothing ?
        LocalMath.Space(owner_capacity) : generation_field.space
    ownership = ownership_field === nothing ? LocalMath.Field(domain, Int32) : ownership_field
    generations = generation_field === nothing ? LocalMath.Field(owners, UInt32) : generation_field
    identities = LocalMath.Field(domain, _ContactSiteIdentity)
    identity = LocalMath.IdentityRelation(domain)
    owner_relation = LocalMath.IndexRelation(ownership => owners; optional = true)
    materialize = LocalMath.Stage(
        domain,
        (
            owner = LocalMath.Access(ownership, identity; required = true),
            generation = LocalMath.Access(generations, owner_relation; required = false),
        ),
        (LocalMath.Publication((LocalMath.FieldPublication(
            identities, identity, LocalMath.PublicationValue(:value)),),
            LocalMath.Unique(_ContactSiteIdentity)),),
        LocalMath.Evaluator(_ContactSiteIdentityEvaluator()),
        LocalMath.Control(; gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__; label = :contact_pair_identity),
    )
    affine = LocalMath.AffineRelation(domain => domain; offsets)
    neighbors = LocalMath.BoundaryRelation(
        affine, LocalMath.PeriodicBoundary(periodic))
    maximum_incidences = _maximum_spatial_incidences(
        descriptor.maximum_pairs, length(offsets))
    pairs = pair_destination === nothing ? LocalMath.Collection(
        LocalMath.KeyedValue{_ContactIncidenceKey, Int32},
        Int(maximum_incidences),
    ) : pair_destination
    pair_reduction = LocalMath.Stage(
        domain,
        (
            center = LocalMath.Access(identities, identity; required = true),
            neighbors = LocalMath.Access(identities, neighbors; required = false),
        ),
        (LocalMath.Publication(pairs, LocalMath.KeyedReduce(
            _ContactIncidenceKey, Int32, _ContactIncidenceFold();
            maximum = length(offsets),
            seed = LocalMath.RebuildFromIdentity(Int32(0)),
            retention = LocalMath.DropIdentityKeys(),
        ); value = :contribution),),
        LocalMath.Evaluator(_ContactPairEvaluator{length(offsets)}()),
        LocalMath.Control(; gate),
        LocalMath.SourceOrigin(@__FILE__, @__LINE__; label = :contact_pair_measure),
    )
    contacts = contact_destination === nothing ? LocalMath.Collection(
        LocalMath.KeyedValue{_ContactSiteKey, Int32},
        Int(descriptor.maximum_contacts),
    ) : contact_destination
    contact_reduction = LocalMath.Stage(
        domain,
        (
            center = LocalMath.Access(identities, identity; required = true),
            neighbors = LocalMath.Access(identities, neighbors; required = false),
        ),
        (LocalMath.Publication(contacts, LocalMath.KeyedReduce(
            _ContactSiteKey, Int32, _ContactSiteFold();
            maximum = length(offsets),
            seed = LocalMath.RebuildFromIdentity(Int32(0)),
            retention = LocalMath.DropIdentityKeys(),
        ); value = :contribution),),
        LocalMath.Evaluator(_ContactSiteEvaluator{length(offsets)}()),
        LocalMath.Control(; gate),
        LocalMath.SourceOrigin(
            @__FILE__, @__LINE__; label = :spatial_relation_contact_sites),
    )
    return (;
        law = LocalMath.sequence(
            LocalMath.LocalLaw(materialize),
            LocalMath.LocalLaw(pair_reduction),
            LocalMath.LocalLaw(contact_reduction),
        ),
        ownership, generations, identities, pairs, contacts, owner_relation,
    )
end

function _execute_spatial_relation_query_rebuild(
        descriptor::SpatialRelationQueryTracker,
        source::TrackerSourceView,
        cell_kinds;
        backend = KernelAbstractions.CPU(),
    )
    length(source.cell_generations) == length(cell_kinds) || throw(ArgumentError(
        "relation-pair reconstruction requires the complete cell-generation table"))
    shape = source.domain.shape
    periodic = cartesian_periodic_axes(source.domain)
    declaration = _spatial_relation_query_declaration(
        descriptor, source.domain_resources, shape, periodic,
        length(cell_kinds),
    )
    prepared = LocalMath.prepare(
        declaration.law,
        declaration.ownership => source.ownership,
        declaration.generations => source.cell_generations,
        declaration.identities => LocalMath.Allocate(
            (UInt32(0), Int32(0), UInt32(0))),
        declaration.pairs => LocalMath.Allocate(),
        declaration.contacts => LocalMath.Allocate();
        backend,
    )
    wait(LocalMath.execute!(prepared))
    return (
        LocalMath.storage(prepared, declaration.pairs),
        LocalMath.storage(prepared, declaration.contacts),
    )
end

tracker_rebuild(
    descriptor::SpatialRelationQueryTracker,
    source::TrackerSourceView,
    cell_kinds,
) = SpatialRelationQueryState(
    _execute_spatial_relation_query_rebuild(descriptor, source, cell_kinds)...)

tracker_recompute(
    descriptor::SpatialRelationQueryTracker,
    source::TrackerSourceView,
    cell_kinds,
) = begin
    ownership = Adapt.adapt(Array, source.ownership)
    generations = Adapt.adapt(Array, source.cell_generations)
    length(generations) == length(cell_kinds) || throw(ArgumentError(
        "relation-pair recomputation requires the complete cell-generation table"))
    shape = source.domain.shape
    periodic = cartesian_periodic_axes(source.domain)
    offsets = _contact_relation_lanes(
        source.domain_resources, descriptor.relation_handle,
        shape, periodic)
    measures = _contact_relation_measures(
        source.domain_resources, descriptor.relation_handle)
    _validate_contact_pair_relation(
        offsets, measures, shape, periodic)
    totals = Dict{_ContactIncidenceKey, Int32}()
    owner_pairs = Set{_ContactPairKey}()
    contact_sites = Set{_ContactSiteKey}()
    indices = CartesianIndices(ownership)
    relation_start, _ = _contact_domain_columns(
        source.domain_resources, descriptor.relation_handle)
    for linear in eachindex(ownership)
        owner = @inbounds ownership[linear]
        generation = owner > 0 ? @inbounds(generations[Int(owner)]) : UInt32(0)
        site = indices[linear]
        for lane in eachindex(offsets)
            offset = ntuple(length(shape)) do axis
                @inbounds source.domain_resources.contact_offsets[
                    axis, Int(relation_start) + lane - 1]
            end
            neighbor_linear = cartesian_lattice_neighbor_site(
                cartesian_face_topology(source.domain), site, offset)
            iszero(neighbor_linear) && continue
            other = @inbounds ownership[neighbor_linear]
            other_generation = other > 0 ?
                @inbounds(generations[Int(other)]) : UInt32(0)
            owner == other && generation == other_generation && continue
            push!(contact_sites, (
                owner, generation, UInt32(linear), other, other_generation))
            key = _contact_pair_key(
                owner, generation, other, other_generation)
            linear < neighbor_linear || continue
            push!(owner_pairs, key)
            incidence_key = (key..., Int32(lane))
            totals[incidence_key] = Base.Checked.checked_add(
                get(totals, incidence_key, Int32(0)), Int32(1))
        end
    end
    length(owner_pairs) <= descriptor.maximum_pairs || throw(ArgumentError(
        "relation-pair recomputation exceeds its fixed pair capacity"))
    length(contact_sites) <= descriptor.maximum_contacts || throw(ArgumentError(
        "relation contact recomputation exceeds its fixed contact capacity"))
    record_type = LocalMath.KeyedValue{_ContactIncidenceKey, Int32}
    pairs = LocalMath.CompactedStorage(
        KernelAbstractions.CPU(), record_type,
        Int(_maximum_spatial_incidences(
            descriptor.maximum_pairs, length(offsets))))
    for (index, key) in enumerate(sort!(collect(keys(totals))))
        @inbounds pairs.records.key[index] = key
        @inbounds pairs.records.value[index] = totals[key]
    end
    pairs.count[1] = Int32(length(totals))
    contacts = LocalMath.CompactedStorage(
        KernelAbstractions.CPU(),
        LocalMath.KeyedValue{_ContactSiteKey, Int32},
        Int(descriptor.maximum_contacts),
    )
    for (index, key) in enumerate(sort!(collect(contact_sites)))
        @inbounds contacts.records.key[index] = key
        @inbounds contacts.records.value[index] = Int32(1)
    end
    contacts.count[1] = Int32(length(contact_sites))
    SpatialRelationQueryState(pairs, contacts)
end

function _checkerboard_tracker_group(
        accepted,
        descriptor::Union{
            SpatialRelationQueryTracker, _BoundSpatialRelationQueryTracker,
        },
        value::SpatialRelationQueryState,
        tracker_index::Integer,
        owner_capacity::Integer,
        terminal_gate,
    )
    declaration = _spatial_relation_query_declaration(
        descriptor, accepted.domain_resources, Tuple(accepted.shape),
        Tuple(accepted.periodic), owner_capacity;
        ownership_field = accepted.ownership_scratch,
        generation_field = accepted.cell_generations,
        gate = terminal_gate,
    )
    return _CheckerboardSpatialRelationQueryGroup(
        Int32(tracker_index), (), (), (), (), (declaration.law,), (), (), (),
        declaration.identities, declaration.pairs, declaration.contacts,
    )
end

function _checkerboard_tracker_group_bindings(
        groups::Tuple{G, Vararg}, state,
    ) where {G <: _CheckerboardSpatialRelationQueryGroup}
    group = first(groups)
    value = state.trackers.values[Int(group.tracker_index)]
    return (
        group.identities => LocalMath.Allocate(
            (UInt32(0), Int32(0), UInt32(0))),
        group.pairs => value.pairs,
        group.contacts => value.contacts,
        _checkerboard_tracker_group_bindings(Base.tail(groups), state)...,
    )
end

"""Non-owning settled owner data required by one spatial-query filter."""
struct _SpatialOwnerMatchView{G, K, D, M}
    cell_generations::G
    cell_kinds::K
    domain::D
    predicate_values::M
end

@inline _spatial_predicate_values(runtime, ::Nothing) = nothing
@inline _spatial_predicate_values(runtime, handle::StateHandle) =
    state_block(runtime.descriptor_state, handle).values

@inline _spatial_owner_match_view(runtime, filter::SpatialOwnerFilterRecipe) =
    _SpatialOwnerMatchView(
    runtime.cell_generations,
    runtime.cell_kinds,
    runtime.program.domain,
    _spatial_predicate_values(runtime, filter.predicate_mask),
)

struct _SpatialMetricView{W}
    weights::W
    start::Int32
    count::Int32
end

@inline function _spatial_metric_view(runtime, metric_handle::Int32)
    resources = runtime.program.descriptor_plan.domain_resources
    start, count = _contact_domain_columns(resources, metric_handle)
    return _SpatialMetricView(resources.contact_measures, start, count)
end

@inline _spatial_owner_generation(view::_SpatialOwnerMatchView, owner::Int32) =
    owner > 0 ? @inbounds(view.cell_generations[Int(owner)]) : UInt32(0)

@inline function _spatial_owner_kind(view::_SpatialOwnerMatchView, owner::Int32)
    owner > 0 && return @inbounds view.cell_kinds[Int(owner)]
    return _domain_owner_metadata(view.domain, owner).kind
end

@inline function _spatial_owner_matches(
        filter::SpatialOwnerFilterRecipe,
        owner::Int32,
        generation::UInt32,
        view::_SpatialOwnerMatchView,
    )
    kind = filter.kind
    kind === StableOwnerIdentityFilter && return owner == filter.identity_owner &&
        generation == filter.identity_generation
    kind === CellKindOwnerFilter && return owner > 0 &&
        _spatial_owner_kind(view, owner) == filter.kind_id
    kind === MediumDomainIdentityFilter && return owner <= 0 &&
        _domain_owner_metadata(view.domain, owner).category ===
            MediumDomainOwnerCategory && owner == filter.identity_owner
    kind === OwnerCategoryFilter && return filter.category === FiniteCellOwner ?
        owner > 0 : filter.category === MediumDomainOwner && owner <= 0 &&
            _domain_owner_metadata(view.domain, owner).category ===
                MediumDomainOwnerCategory
    if kind === PublishedOwnerPredicateFilter
        owner > 0 || return false
        mask = view.predicate_values
        mask === nothing && return false
        return Bool(@inbounds mask[Int(owner)])
    end
    return false
end

@inline function _spatial_query_pair_other(key, owner::Int32, generation::UInt32)
    key[1] == owner && key[2] == generation && return (key[3], key[4], true)
    key[3] == owner && key[4] == generation && return (key[1], key[2], true)
    return (Int32(0), UInt32(0), false)
end

@inline function spatial_contact_edge_count(
        state::SpatialRelationQueryState,
        view::_SpatialOwnerMatchView,
        owner::Int32,
        filter::SpatialOwnerFilterRecipe,
    )
    generation = _spatial_owner_generation(view, owner)
    total = Int32(0)
    count = Int(@inbounds state.pairs.count[1])
    records = state.pairs.records
    for index in 1:count
        key = @inbounds records.key[index]
        other, other_generation, participates =
            _spatial_query_pair_other(key, owner, generation)
        participates && _spatial_owner_matches(
            filter, other, other_generation, view) || continue
        total = Base.Checked.checked_add(total, @inbounds records.value[index])
    end
    return total
end

@inline function spatial_contact_measure(
        state::SpatialRelationQueryState,
        view::_SpatialOwnerMatchView,
        owner::Int32,
        filter::SpatialOwnerFilterRecipe,
        metric::_SpatialMetricView,
    )
    generation = _spatial_owner_generation(view, owner)
    T = eltype(metric.weights)
    total = zero(T)
    count = Int(@inbounds state.pairs.count[1])
    records = state.pairs.records
    for index in 1:count
        key = @inbounds records.key[index]
        other, other_generation, participates =
            _spatial_query_pair_other(key, owner, generation)
        participates && _spatial_owner_matches(
            filter, other, other_generation, view) || continue
        lane = Int(key[5])
        weight = @inbounds metric.weights[Int(metric.start) + lane - 1]
        incidence = @inbounds records.value[index]
        total += T(incidence) * weight
    end
    return total
end

@inline function spatial_neighbor_cell_count(
        state::SpatialRelationQueryState,
        view::_SpatialOwnerMatchView,
        owner::Int32,
        filter::SpatialOwnerFilterRecipe,
    )
    generation = _spatial_owner_generation(view, owner)
    total = Int32(0)
    count = Int(@inbounds state.pairs.count[1])
    records = state.pairs.records
    for index in 1:count
        key = @inbounds records.key[index]
        if index > 1
            prior = @inbounds records.key[index - 1]
            key[1] == prior[1] && key[2] == prior[2] &&
                key[3] == prior[3] && key[4] == prior[4] && continue
        end
        other, other_generation, participates =
            _spatial_query_pair_other(key, owner, generation)
        participates && other > 0 && _spatial_owner_matches(
            filter, other, other_generation, view) || continue
        total = Base.Checked.checked_add(total, Int32(1))
    end
    return total
end

@inline function spatial_neighbor_property_sum(
        state::SpatialRelationQueryState,
        view::_SpatialOwnerMatchView,
        owner::Int32,
        filter::SpatialOwnerFilterRecipe,
        values,
    )
    generation = _spatial_owner_generation(view, owner)
    total = zero(eltype(values))
    count = Int(@inbounds state.pairs.count[1])
    records = state.pairs.records
    for index in 1:count
        key = @inbounds records.key[index]
        if index > 1
            prior = @inbounds records.key[index - 1]
            key[1] == prior[1] && key[2] == prior[2] &&
                key[3] == prior[3] && key[4] == prior[4] && continue
        end
        other, other_generation, participates =
            _spatial_query_pair_other(key, owner, generation)
        participates && other > 0 && _spatial_owner_matches(
            filter, other, other_generation, view) || continue
        total += @inbounds values[Int(other)]
    end
    return total
end

@inline function spatial_boundary_site_count(
        state::SpatialRelationQueryState,
        view::_SpatialOwnerMatchView,
        owner::Int32,
        filter::SpatialOwnerFilterRecipe,
    )
    generation = _spatial_owner_generation(view, owner)
    total = Int32(0)
    count = Int(@inbounds state.contacts.count[1])
    for index in 1:count
        key = @inbounds state.contacts.records.key[index]
        key[1] == owner && key[2] == generation && _spatial_owner_matches(
            filter, key[4], key[5], view) || continue
        already_counted = false
        # KeyedReduce publishes lexicographically ordered keys. Only the bounded
        # run for this owner/site can contain another matching neighbor.
        for prior_index in (index - 1):-1:1
            prior_key = @inbounds state.contacts.records.key[prior_index]
            (prior_key[1] == owner && prior_key[2] == generation &&
             prior_key[3] == key[3]) || break
            if prior_key[1] == owner && prior_key[2] == generation &&
                    prior_key[3] == key[3] && _spatial_owner_matches(
                        filter, prior_key[4], prior_key[5], view)
                already_counted = true
                break
            end
        end
        already_counted || (total = Base.Checked.checked_add(total, Int32(1)))
    end
    return total
end

@inline function spatial_global_interface_measure(
        state::SpatialRelationQueryState,
        left_view::_SpatialOwnerMatchView,
        right_view::_SpatialOwnerMatchView,
        left::SpatialOwnerFilterRecipe,
        right::SpatialOwnerFilterRecipe,
        metric::_SpatialMetricView,
    )
    T = eltype(metric.weights)
    total = zero(T)
    count = Int(@inbounds state.pairs.count[1])
    records = state.pairs.records
    for index in 1:count
        key = @inbounds records.key[index]
        selected = (_spatial_owner_matches(left, key[1], key[2], left_view) &&
            _spatial_owner_matches(right, key[3], key[4], right_view)) ||
            (_spatial_owner_matches(left, key[3], key[4], left_view) &&
             _spatial_owner_matches(right, key[1], key[2], right_view))
        selected || continue
        lane = Int(key[5])
        weight = @inbounds metric.weights[Int(metric.start) + lane - 1]
        incidence = @inbounds records.value[index]
        total += T(incidence) * weight
    end
    return total
end
