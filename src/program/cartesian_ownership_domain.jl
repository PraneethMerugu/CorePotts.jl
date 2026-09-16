# Cartesian ownership realization and non-finite owner identity.

"""Durable category of a finite cell or declared non-finite domain owner."""
@enum OwnerCategory::UInt8 begin
    InvalidOwnerCategory = 0x00
    FiniteCellOwnerCategory = 0x01
    MediumDomainOwnerCategory = 0x02
    WallDomainOwnerCategory = 0x03
end
@doc "Category assigned to positive finite-cell owner codes." FiniteCellOwnerCategory
@doc "Category assigned to a declared non-finite medium owner." MediumDomainOwnerCategory
@doc "Category assigned to a declared non-finite wall owner." WallDomainOwnerCategory

"""Boundary realization law for one oriented face of a Cartesian domain."""
@enum CartesianFaceKind::UInt8 begin
    PeriodicCartesianFace = 0x01
    ClosedCartesianFace = 0x02
    FixedExteriorCartesianFace = 0x03
end
@doc "Wrap coordinates crossing this Cartesian face to the opposite face." PeriodicCartesianFace
@doc "Reject owner and mutable-site relations crossing this Cartesian face." ClosedCartesianFace
@doc "Resolve crossings of this Cartesian face to its declared fixed owner." FixedExteriorCartesianFace

@enum CartesianNeighborCategory::UInt8 begin
    MutableCartesianNeighbor = 0x01
    FixedExteriorCartesianNeighbor = 0x02
    FixedObstacleCartesianNeighbor = 0x03
    AbsentCartesianNeighbor = 0x04
    InvalidCartesianNeighbor = 0x05
end

@enum CartesianRelationAccess::UInt8 begin
    MutableSiteRelationAccess = 0x01
    OwnerRelationAccess = 0x02
end

struct _UncheckedDomainOwnerMetadata end

"""Stable scientific identity and type information for one non-finite owner."""
struct DomainOwnerMetadata
    identity::UInt64
    category::OwnerCategory
    kind::Int16
    function DomainOwnerMetadata(
            identity::UInt64,
            category::OwnerCategory,
            kind::Int16,
            ::_UncheckedDomainOwnerMetadata,
        )
        return new(identity, category, kind)
    end
end

function DomainOwnerMetadata(
        identity::Integer, category::OwnerCategory, kind::Integer,
    )
    category in (MediumDomainOwnerCategory, WallDomainOwnerCategory) ||
        throw(ArgumentError(
            "a domain owner must have medium-domain or wall-domain category"
        ))
    identity >= 0 || throw(ArgumentError(
        "a domain-owner identity must be nonnegative"
    ))
    identity <= typemax(UInt64) || throw(ArgumentError(
        "a domain-owner identity exceeds UInt64"
    ))
    1 <= kind <= typemax(Int16) || throw(ArgumentError(
        "a domain-owner kind must be positive and fit Int16"
    ))
    return DomainOwnerMetadata(
        UInt64(identity),
        category,
        Int16(kind),
        _UncheckedDomainOwnerMetadata(),
    )
end

const _INVALID_DOMAIN_OWNER_METADATA =
    DomainOwnerMetadata(
        UInt64(0),
        InvalidOwnerCategory,
        Int16(0),
        _UncheckedDomainOwnerMetadata(),
    )

@inline _domain_owner_code_from_handle(handle::Int32) = -handle

"""Resolved finite or non-finite owner metadata used by compiler extensions."""
struct OwnerMetadata
    identity::UInt64
    category::OwnerCategory
    kind::Int16
    generation::UInt32
end

"""Canonical stable equality key across finite and non-finite owner namespaces."""
struct OwnerKey
    category::OwnerCategory
    identity::UInt64
end
Base.:(==)(left::OwnerKey, right::OwnerKey) =
    left.category === right.category && left.identity == right.identity
Base.isequal(left::OwnerKey, right::OwnerKey) = left == right
Base.hash(key::OwnerKey, seed::UInt) =
    hash(key.identity, hash(UInt8(key.category), seed))

"""Compact dense owner-directory address law for device-reachable routing."""
struct OwnerDirectoryLayout
    cell_capacity::Int32
    domain_owner_count::Int32
end

"""Return the stable category-and-identity key for resolved owner metadata."""
@inline owner_key(metadata::OwnerMetadata) =
    OwnerKey(metadata.category, metadata.identity)

"""One role-filtered Cartesian neighbor and its authoritative owner."""
struct CartesianNeighbor{N}
    category::CartesianNeighborCategory
    site::Int32
    owner::Int32
    lane::Int32
    endpoint::NTuple{N, Int64}
end

struct _SingleCartesianOffset{O}
    value::O
end
@inline Base.getindex(offset::_SingleCartesianOffset, axis::Integer, direction::Integer) =
    offset.value[axis]

struct _ValidatedCartesianOwnershipDomain end

"""
Sole runtime authority for Cartesian faces, non-finite owners, obstacles, and
the mutable recipient population.

Positive owner values address finite-cell slots, zero denotes the declared
default domain owner, and negative values are handles into the domain-owned
non-finite owner directory.
"""
struct CartesianOwnershipDomain{
        N,
        F,
        O <: AbstractVector{DomainOwnerMetadata},
        H <: AbstractArray{Int32, N},
        M <: AbstractArray{Bool, N},
        S <: AbstractVector{Int32},
    }
    shape::NTuple{N, Int}
    face_kinds::NTuple{F, CartesianFaceKind}
    face_owner_handles::NTuple{F, Int32}
    default_owner::DomainOwnerMetadata
    domain_owners::O
    obstacle_owner_handles::H
    mutable_mask::M
    mutable_sites::S
    function CartesianOwnershipDomain(
            shape::NTuple{N, Int},
            face_kinds::NTuple{F, CartesianFaceKind},
            face_owner_handles::NTuple{F, Int32},
            default_owner::DomainOwnerMetadata,
            domain_owners::O,
            obstacle_owner_handles::H,
            mutable_mask::M,
            mutable_sites::S,
            ::_ValidatedCartesianOwnershipDomain,
        ) where {
            N,
            F,
            O <: AbstractVector{DomainOwnerMetadata},
            H <: AbstractArray{Int32, N},
            M <: AbstractArray{Bool, N},
            S <: AbstractVector{Int32},
        }
        return new{N, F, O, H, M, S}(
            shape,
            face_kinds,
            face_owner_handles,
            default_owner,
            domain_owners,
            obstacle_owner_handles,
            mutable_mask,
            mutable_sites,
        )
    end
end

"""Isbits Cartesian face semantics for device geometry evaluators."""
struct CartesianFaceTopology{N, F}
    shape::NTuple{N, Int}
    face_kinds::NTuple{F, CartesianFaceKind}
end

"""Small contact-realization payload; relation width remains runtime data."""
struct CartesianContactTopology{N, F}
    shape::NTuple{N, Int}
    face_kinds::NTuple{F, CartesianFaceKind}
    face_owner_handles::NTuple{F, Int32}
end

"""Lazy site-owner array applying the sole Cartesian obstacle override law."""
struct OwnerAtView{N,O,H,M} <: AbstractArray{Int32,N}
    ownership::O
    obstacle_owner_handles::H
    mutable_mask::M
end

function OwnerAtView(domain::CartesianOwnershipDomain{N}, ownership) where {N}
    size(ownership) == domain.shape || throw(ArgumentError(
        "owner-at view ownership has the wrong shape"
    ))
    return OwnerAtView{N,typeof(ownership),typeof(domain.obstacle_owner_handles),
        typeof(domain.mutable_mask)}(
        ownership, domain.obstacle_owner_handles, domain.mutable_mask,
    )
end

Base.size(view::OwnerAtView) = size(view.ownership)
Base.axes(view::OwnerAtView) = axes(view.ownership)
Base.IndexStyle(::Type{<:OwnerAtView}) = IndexLinear()
Base.strides(view::OwnerAtView) = strides(view.ownership)
Base.dataids(view::OwnerAtView) = (
    Base.dataids(view.ownership)...,
    Base.dataids(view.obstacle_owner_handles)...,
    Base.dataids(view.mutable_mask)...,
)
KernelAbstractions.get_backend(view::OwnerAtView) =
    KernelAbstractions.get_backend(view.ownership)
@inline _owner_at(
    raw_owner::Int32, obstacle_owner_handle::Int32, mutable::Bool,
) = mutable ? raw_owner : _domain_owner_code_from_handle(obstacle_owner_handle)
@inline function Base.getindex(view::OwnerAtView, site::Integer)
    return _owner_at(
        @inbounds(view.ownership[site]),
        @inbounds(view.obstacle_owner_handles[site]),
        @inbounds(view.mutable_mask[site]),
    )
end
function Adapt.adapt_structure(to, view::OwnerAtView)
    ownership = Adapt.adapt(to, view.ownership)
    obstacles = Adapt.adapt(to, view.obstacle_owner_handles)
    mutable = Adapt.adapt(to, view.mutable_mask)
    return OwnerAtView{
        ndims(view),typeof(ownership),typeof(obstacles),typeof(mutable)}(
        ownership, obstacles, mutable,
    )
end

"""Dense finite-plus-domain owner kind directory for indexed device reads."""
struct OwnerDirectoryKindView{K,D} <: AbstractVector{Int16}
    cell_kinds::K
    default_owner::DomainOwnerMetadata
    domain_owners::D
end


"""Lazy semantic site owner and kind for gathered authored-site stages."""
struct SiteOwnerKindView{N,O,K,D,H,M} <:
        AbstractArray{Tuple{Int32,Int16},N}
    ownership::O
    cell_kinds::K
    default_owner::DomainOwnerMetadata
    domain_owners::D
    obstacle_owner_handles::H
    mutable_mask::M
end


function SiteOwnerKindView(
        domain::CartesianOwnershipDomain{N}, ownership, cell_kinds,
    ) where {N}
    size(ownership) == domain.shape || throw(ArgumentError(
        "owner-kind view ownership has the wrong shape"
    ))
    return SiteOwnerKindView{N,typeof(ownership),typeof(cell_kinds),
        typeof(domain.domain_owners),typeof(domain.obstacle_owner_handles),
        typeof(domain.mutable_mask)}(
        ownership, cell_kinds, domain.default_owner, domain.domain_owners,
        domain.obstacle_owner_handles, domain.mutable_mask,
    )
end
Base.size(view::SiteOwnerKindView) = size(view.ownership)
Base.axes(view::SiteOwnerKindView) = axes(view.ownership)
Base.IndexStyle(::Type{<:SiteOwnerKindView}) = IndexLinear()
Base.strides(view::SiteOwnerKindView) = strides(view.ownership)
Base.dataids(view::SiteOwnerKindView) = (
    Base.dataids(view.ownership)..., Base.dataids(view.cell_kinds)...,
    Base.dataids(view.domain_owners)...,
    Base.dataids(view.obstacle_owner_handles)...,
    Base.dataids(view.mutable_mask)...,
)
KernelAbstractions.get_backend(view::SiteOwnerKindView) =
    KernelAbstractions.get_backend(view.ownership)
@inline function Base.getindex(view::SiteOwnerKindView, site::Integer)
    owner = @inbounds(view.mutable_mask[site]) ?
        @inbounds(view.ownership[site]) :
        _domain_owner_code_from_handle(
            @inbounds view.obstacle_owner_handles[site])
    kind = owner > 0 ? @inbounds(view.cell_kinds[owner]) :
        _domain_owner_kind(view.default_owner, view.domain_owners, owner)
    return (owner, kind)
end
function Adapt.adapt_structure(to, view::SiteOwnerKindView)
    ownership = Adapt.adapt(to, view.ownership)
    cell_kinds = Adapt.adapt(to, view.cell_kinds)
    owners = Adapt.adapt(to, view.domain_owners)
    obstacles = Adapt.adapt(to, view.obstacle_owner_handles)
    mutable = Adapt.adapt(to, view.mutable_mask)
    return SiteOwnerKindView{
        ndims(view),typeof(ownership),typeof(cell_kinds),typeof(owners),
        typeof(obstacles),typeof(mutable)}(
        ownership, cell_kinds, view.default_owner, owners, obstacles, mutable)
end
Base.IndexStyle(::Type{<:OwnerDirectoryKindView}) = IndexLinear()
Base.size(view::OwnerDirectoryKindView) = (
    length(view.cell_kinds) + length(view.domain_owners) + 1,
)
Base.length(view::OwnerDirectoryKindView) = first(size(view))
Base.strides(::OwnerDirectoryKindView) = (1,)
Base.dataids(view::OwnerDirectoryKindView) = (
    Base.dataids(view.cell_kinds)..., Base.dataids(view.domain_owners)...,
)
@inline function Base.getindex(view::OwnerDirectoryKindView, index::Integer)
    capacity = length(view.cell_kinds)
    index <= capacity && return @inbounds view.cell_kinds[index]
    index == capacity + 1 && return view.default_owner.kind
    return @inbounds view.domain_owners[index - capacity - 1].kind
end
KernelAbstractions.get_backend(view::OwnerDirectoryKindView) =
    KernelAbstractions.get_backend(view.cell_kinds)
function Adapt.adapt_structure(to, view::OwnerDirectoryKindView)
    kinds = Adapt.adapt(to, view.cell_kinds)
    owners = Adapt.adapt(to, view.domain_owners)
    return OwnerDirectoryKindView(kinds, view.default_owner, owners)
end

@inline cartesian_face_topology(domain::CartesianOwnershipDomain) =
    CartesianFaceTopology(
        domain.shape, domain.face_kinds
    )

function cartesian_contact_topology(
        domain::CartesianOwnershipDomain{N,F},
    ) where {N,F}
    return CartesianContactTopology{N,F}(
        domain.shape, domain.face_kinds, domain.face_owner_handles
    )
end

@inline _cartesian_face_index(axis::Integer, positive::Bool) =
    2 * Int(axis) - (positive ? 0 : 1)

function _cartesian_site_count(shape)
    count = 1
    for extent in shape
        extent > 0 || throw(ArgumentError(
            "Cartesian ownership dimensions must be positive"
        ))
        extent <= div(typemax(Int32), count) || throw(ArgumentError(
            "Cartesian ownership site count exceeds Int32"
        ))
        count *= extent
    end
    return count
end

function _validate_domain_owner_handle(
        owners::AbstractVector{DomainOwnerMetadata}, handle::Integer, context,
    )
    1 <= handle <= length(owners) || throw(ArgumentError(
        "$context references an unknown domain-owner handle"
    ))
    metadata = @inbounds owners[handle]
    metadata.category !== InvalidOwnerCategory || throw(ArgumentError(
        "$context references a non-domain kind through a negative owner code"
    ))
    return Int32(handle)
end

function CartesianOwnershipDomain(
        shape::NTuple{N, Int},
        default_owner::DomainOwnerMetadata,
        domain_owners::AbstractVector{DomainOwnerMetadata};
        face_kinds = ntuple(_ -> PeriodicCartesianFace, 2N),
        face_owner_handles = ntuple(_ -> Int32(0), 2N),
        obstacle_owner_handles = nothing,
        obstacle_mask = nothing,
    ) where {N}
    _cartesian_site_count(shape)
    default_owner.category === MediumDomainOwnerCategory || throw(ArgumentError(
        "the default Cartesian domain owner must be a medium-domain owner"))
    kinds = NTuple{2N, CartesianFaceKind}(face_kinds)
    handles = NTuple{2N, Int32}(face_owner_handles)
    owners = Vector{DomainOwnerMetadata}(domain_owners)
    identities = Set{UInt64}((default_owner.identity,))
    for metadata in owners
        metadata.category === InvalidOwnerCategory && continue
        metadata.identity in identities && throw(ArgumentError(
            "domain-owner identities, including the default owner, must be unique"
        ))
        push!(identities, metadata.identity)
    end
    obstacle_owner_handles === nothing &&
        (obstacle_owner_handles = zeros(Int32, shape))
    size(obstacle_owner_handles) == shape || throw(ArgumentError(
        "Cartesian obstacle-owner storage has the wrong shape"
    ))
    obstacles = Array{Int32, N}(obstacle_owner_handles)
    presence = obstacle_mask === nothing ?
        map(value -> !iszero(value), obstacles) : begin
        obstacle_mask isa AbstractArray{Bool} || throw(ArgumentError(
            "Cartesian obstacle mask must contain Bool values"))
        size(obstacle_mask) == shape || throw(ArgumentError(
            "Cartesian obstacle mask has the wrong shape"))
        Array{Bool,N}(obstacle_mask)
    end

    for axis in 1:N
        negative = kinds[_cartesian_face_index(axis, false)]
        positive = kinds[_cartesian_face_index(axis, true)]
        (negative === PeriodicCartesianFace) ==
            (positive === PeriodicCartesianFace) || throw(ArgumentError(
            "periodic Cartesian faces must occur as a paired axis"
        ))
    end
    for face in eachindex(kinds)
        kind = kinds[face]
        handle = handles[face]
        if kind === FixedExteriorCartesianFace
            iszero(handle) || _validate_domain_owner_handle(
                owners, handle, "a fixed Cartesian exterior")
        else
            iszero(handle) || throw(ArgumentError(
                "periodic and closed Cartesian faces cannot carry an owner"
            ))
        end
    end

    mutable_mask = .!presence
    mutable_sites = Int32[]
    for site in eachindex(obstacles)
        handle = @inbounds obstacles[site]
        handle >= 0 || throw(ArgumentError(
            "Cartesian obstacle handles must be nonnegative"
        ))
        if @inbounds mutable_mask[site]
            iszero(handle) || throw(ArgumentError(
                "a mutable Cartesian site cannot carry an obstacle owner"))
            push!(mutable_sites, Int32(site))
        else
            iszero(handle) || _validate_domain_owner_handle(
                owners, handle, "a Cartesian obstacle")
        end
    end
    isempty(mutable_sites) && throw(ArgumentError(
        "a Cartesian ownership domain requires at least one mutable site"
    ))
    return CartesianOwnershipDomain(
        shape,
        kinds,
        handles,
        default_owner,
        owners,
        obstacles,
        mutable_mask,
        mutable_sites,
        _ValidatedCartesianOwnershipDomain(),
    )
end

"""Build the ordinary periodic/closed medium-only Core domain."""
function _standard_cartesian_ownership_domain(
        shape::NTuple{N, Int},
        periodic::NTuple{N, Bool},
        kind_count::Integer,
        default_kind::Integer,
        domain_kind_mask,
    ) where {N}
    1 <= default_kind <= kind_count || throw(ArgumentError(
        "the default medium kind must be declared"
    ))
    mask = BitVector(domain_kind_mask)
    length(mask) == kind_count || throw(ArgumentError(
        "the medium-kind table has the wrong size"
    ))
    mask[default_kind] || throw(ArgumentError(
        "the default medium must be a declared medium kind"
    ))
    owners = map(1:Int(kind_count)) do kind
        mask[kind] ? DomainOwnerMetadata(
            UInt64(kind), MediumDomainOwnerCategory, kind
        ) : _INVALID_DOMAIN_OWNER_METADATA
    end
    default_owner = DomainOwnerMetadata(
        UInt64(0), MediumDomainOwnerCategory, default_kind
    )
    faces = ntuple(2N) do face
        periodic[div(face + 1, 2)] ?
            PeriodicCartesianFace : ClosedCartesianFace
    end
    return CartesianOwnershipDomain(
        shape, default_owner, owners; face_kinds = faces
    )
end

"""Return the dense domain-owner handle encoded by a non-positive owner code."""
@inline function domain_owner_handle(
        domain::CartesianOwnershipDomain, owner::Int32,
    )
    owner == 0 && return Int32(0)
    owner < 0 || throw(ArgumentError(
        "a finite-cell owner has no domain-owner handle"
    ))
    return -owner
end

"""Resolve one declared stable domain-owner identity to Core's raw owner code."""
function domain_owner_code(
        domain::CartesianOwnershipDomain, identity::UInt64,
    )
    domain.default_owner.identity == identity && return Int32(0)
    for (handle, metadata) in pairs(domain.domain_owners)
        metadata.category === InvalidOwnerCategory && continue
        metadata.identity == identity && return -Int32(handle)
    end
    throw(ArgumentError("unknown Cartesian domain-owner identity"))
end

function domain_owner_code(
        domain::CartesianOwnershipDomain, metadata::DomainOwnerMetadata,
    )
    code = domain_owner_code(domain, metadata.identity)
    registered = _domain_owner_metadata(domain, code)
    registered.category === metadata.category &&
        registered.kind == metadata.kind || throw(ArgumentError(
            "Cartesian domain-owner metadata does not match its registered identity"
        ))
    return code
end

@inline function _domain_owner_metadata(
        domain::CartesianOwnershipDomain, owner::Int32,
    )
    owner == 0 && return domain.default_owner
    handle = domain_owner_handle(domain, owner)
    1 <= handle <= length(domain.domain_owners) || throw(ArgumentError(
        "owner references an unknown domain-owner handle"
    ))
    metadata = @inbounds domain.domain_owners[handle]
    metadata.category !== InvalidOwnerCategory || throw(ArgumentError(
        "owner references a non-domain kind through a negative code"
    ))
    return metadata
end

@inline function _domain_owner_kind(default_owner, domain_owners, owner::Int32)
    owner == 0 && return default_owner.kind
    return @inbounds domain_owners[-owner].kind
end

"""Resolve one owner code to its finite or declared non-finite metadata."""
@inline function owner_metadata(
        domain::CartesianOwnershipDomain,
        cell_kinds,
        cell_generations,
        owner::Integer,
    )
    code = Int32(owner)
    if code > 0
        1 <= code <= length(cell_kinds) || throw(BoundsError(cell_kinds, code))
        generation = @inbounds cell_generations[code]
        identity = (UInt64(generation) << 32) | UInt64(UInt32(code))
        return OwnerMetadata(
            identity,
            FiniteCellOwnerCategory,
            @inbounds(cell_kinds[code]),
            generation,
        )
    end
    metadata = _domain_owner_metadata(domain, code)
    return OwnerMetadata(
        metadata.identity, metadata.category, metadata.kind, UInt32(0)
    )
end

"""Return the stable identity of a finite generation or declared domain owner."""
@inline function owner_identity(domain, cell_generations, owner)
    code = Int32(owner)
    code > 0 || return _domain_owner_metadata(domain, code).identity
    1 <= code <= length(cell_generations) ||
        throw(BoundsError(cell_generations, code))
    generation = @inbounds cell_generations[code]
    return (UInt64(generation) << 32) | UInt64(UInt32(code))
end
@inline owner_key(domain, cell_generations, owner) = OwnerKey(
    owner_category(domain, owner),
    owner_identity(domain, cell_generations, owner),
)
"""Return the durable owner category associated with one owner code."""
@inline function owner_category(domain, owner)
    code = Int32(owner)
    return code > 0 ? FiniteCellOwnerCategory :
        _domain_owner_metadata(domain, code).category
end
@inline function owner_kind(domain, cell_kinds, owner)
    code = Int32(owner)
    if code > 0
        1 <= code <= length(cell_kinds) || throw(BoundsError(cell_kinds, code))
        return @inbounds cell_kinds[code]
    end
    return _domain_owner_metadata(domain, code).kind
end
"""Return a finite owner's generation, or zero for a non-finite owner."""
@inline function owner_generation(cell_generations, owner)
    code = Int32(owner)
    code > 0 || return UInt32(0)
    1 <= code <= length(cell_generations) ||
        throw(BoundsError(cell_generations, code))
    return @inbounds cell_generations[code]
end

@inline function _owner_directory_capacity(
        domain::CartesianOwnershipDomain, cell_capacity::Integer,
    )
    cell_capacity >= 0 || throw(ArgumentError(
        "owner-directory cell capacity must be nonnegative"
    ))
    maximum = Int(typemax(Int32)) - length(domain.domain_owners) - 1
    cell_capacity <= maximum || throw(ArgumentError(
        "owner-directory size exceeds Int32"
    ))
    return Int32(cell_capacity)
end

"""Construct the compact dense address layout for finite and domain owners."""
@inline function owner_directory_layout(
        domain::CartesianOwnershipDomain, cell_capacity::Integer,
    )
    capacity = _owner_directory_capacity(domain, cell_capacity)
    return OwnerDirectoryLayout(capacity, Int32(length(domain.domain_owners)))
end

"""Map an owner code to its validated dense owner-directory index."""
@inline function owner_directory_index(
        layout::OwnerDirectoryLayout, owner::Int32,
    )
    @boundscheck begin
        valid = owner > 0 ? owner <= layout.cell_capacity :
            -Int64(owner) <= layout.domain_owner_count
        valid || throw(ArgumentError(
            "owner is outside the dense owner-directory layout"))
    end
    return owner > 0 ? owner : layout.cell_capacity - owner + Int32(1)
end

@inline function owner_directory_index(
        domain::CartesianOwnershipDomain,
        cell_capacity::Integer,
        owner::Integer,
    )
    layout = owner_directory_layout(domain, cell_capacity)
    typemin(Int32) <= owner <= typemax(Int32) || throw(ArgumentError(
        "owner code does not fit Int32"
    ))
    code = Int32(owner)
    if code > 0
        code <= layout.cell_capacity || throw(ArgumentError(
            "finite owner exceeds owner-directory cell capacity"
        ))
        return owner_directory_index(layout, code)
    end
    handle = domain_owner_handle(domain, code)
    _domain_owner_metadata(domain, code)
    return owner_directory_index(layout, code)
end

"""Return the storage length required by the dense owner directory."""
@inline owner_directory_count(
    domain::CartesianOwnershipDomain, cell_capacity::Integer,
) = let layout = owner_directory_layout(domain, cell_capacity)
    layout.cell_capacity + layout.domain_owner_count + Int32(1)
end

"""Resolve the authoritative owner at a Cartesian site, including obstacles."""
@inline function owner_at(
        domain::CartesianOwnershipDomain, ownership, site,
    )
    return _owner_at(
        @inbounds(ownership[site]),
        @inbounds(domain.obstacle_owner_handles[site]),
        @inbounds(domain.mutable_mask[site]),
    )
end

@inline cartesian_periodic_axes(domain::CartesianOwnershipDomain{N}) where {N} =
    ntuple(N) do axis
        @inbounds domain.face_kinds[_cartesian_face_index(axis, false)] ===
            PeriodicCartesianFace
    end

@inline cartesian_mutable_site_count(domain::CartesianOwnershipDomain) =
    length(domain.mutable_sites)

@inline validate_lifecycle_domain_owners(domain, plan) = plan

@inline function domain_owner_kind(
        domain::CartesianOwnershipDomain, kind::Integer,
    )
    domain.default_owner.kind == kind && return true
    for metadata in domain.domain_owners
        metadata.category !== InvalidOwnerCategory && metadata.kind == kind &&
            return true
    end
    return false
end

function domain_kind_mask(
        domain::CartesianOwnershipDomain, kind_count::Integer,
        category::OwnerCategory,
    )
    mask = falses(kind_count)
    domain.default_owner.category === category &&
        (mask[domain.default_owner.kind] = true)
    for metadata in domain.domain_owners
        metadata.category === category && (mask[metadata.kind] = true)
    end
    return mask
end

"""Return an immutable inspection report derived from a Cartesian domain."""
function cartesian_domain_report(domain::CartesianOwnershipDomain)
    return (
        shape = domain.shape,
        faces = ntuple(length(domain.face_kinds)) do face
            (
                kind = domain.face_kinds[face],
                owner_handle = domain.face_owner_handles[face],
            )
        end,
        default_owner = domain.default_owner,
        domain_owners = Tuple(domain.domain_owners),
        obstacles = Tuple(
            (site = Int32(site), owner_handle = domain.obstacle_owner_handles[site])
            for site in eachindex(domain.obstacle_owner_handles)
            if !domain.mutable_mask[site]
        ),
        mutable_site_count = length(domain.mutable_sites),
    )
end

@inline _write_cartesian_identity(io, value::UInt8) = write(io, value)
@inline _write_cartesian_identity(io, value::Int16) = write(io, htol(value))
@inline _write_cartesian_identity(io, value::Int32) = write(io, htol(value))
@inline _write_cartesian_identity(io, value::Int64) = write(io, htol(value))
@inline _write_cartesian_identity(io, value::UInt64) = write(io, htol(value))

function _write_cartesian_owner_identity(io, metadata::DomainOwnerMetadata)
    _write_cartesian_identity(io, metadata.identity)
    _write_cartesian_identity(io, UInt8(metadata.category))
    _write_cartesian_identity(io, metadata.kind)
    return io
end

function cartesian_domain_identity(domain::CartesianOwnershipDomain)
    io = IOBuffer()
    _write_cartesian_identity(io, Int32(length(domain.shape)))
    for extent in domain.shape
        _write_cartesian_identity(io, Int64(extent))
    end
    _write_cartesian_identity(io, Int32(length(domain.face_kinds)))
    for face in eachindex(domain.face_kinds)
        _write_cartesian_identity(io, UInt8(domain.face_kinds[face]))
        _write_cartesian_identity(io, domain.face_owner_handles[face])
    end
    _write_cartesian_owner_identity(io, domain.default_owner)
    _write_cartesian_identity(io, Int32(length(domain.domain_owners)))
    for metadata in domain.domain_owners
        _write_cartesian_owner_identity(io, metadata)
    end
    for site in eachindex(domain.obstacle_owner_handles)
        _write_cartesian_identity(io, UInt8(!domain.mutable_mask[site]))
        _write_cartesian_identity(io, domain.obstacle_owner_handles[site])
    end
    digest = SHA.sha256(take!(io))
    return foldl(@view(digest[1:8]); init = zero(UInt64)) do value, byte
        (value << 8) | UInt64(byte)
    end
end

function validate_cartesian_relation_realization(
        domain::CartesianOwnershipDomain{N}, offsets,
        access::CartesianRelationAccess,
    ) where {N}
    isempty(offsets) && return offsets
    size(offsets, 1) == N || throw(ArgumentError(
        "Cartesian relation offsets have the wrong dimensionality"
    ))
    indices = CartesianIndices(domain.shape)
    ownership = zeros(Int32, domain.shape)
    for linear in domain.mutable_sites, direction in axes(offsets, 2)
        neighbor = realize_cartesian_neighbor(
            domain,
            ownership,
            indices[Int(linear)],
            offsets,
            direction,
            access,
        )
        neighbor.category === InvalidCartesianNeighbor && throw(ArgumentError(
            "a Cartesian relation crosses incompatible boundary faces"
        ))
    end
    return offsets
end

@inline function _cartesian_linear_site(
        shape::NTuple{N, Int}, coordinates::NTuple{N, Int},
    ) where {N}
    index = 1
    stride = 1
    for axis in 1:N
        index += (coordinates[axis] - 1) * stride
        stride *= shape[axis]
    end
    return Int32(index)
end

@inline function _cartesian_lattice_neighbor_site(
        topology,
        site::CartesianIndex{N},
        offset::NTuple{N, <:Integer},
    ) where {N}
    origin = Tuple(site)
    resolved = map(+, origin, map(Int, offset))
    for axis in 1:N
        value = resolved[axis]
        1 <= value <= topology.shape[axis] && continue
        face = _cartesian_face_index(axis, value > topology.shape[axis])
        @inbounds(topology.face_kinds[face]) === PeriodicCartesianFace ||
            return Int32(0)
        resolved = Base.setindex(
            resolved, mod1(value, topology.shape[axis]), axis
        )
    end
    return _cartesian_linear_site(topology.shape, resolved)
end

@inline cartesian_lattice_neighbor_site(
    topology::CartesianFaceTopology{N}, site::CartesianIndex{N},
    offset::NTuple{N,<:Integer},
) where {N} = _cartesian_lattice_neighbor_site(topology, site, offset)

@inline cartesian_lattice_neighbor_site(
    topology::CartesianContactTopology{N}, site::CartesianIndex{N},
    offset::NTuple{N,<:Integer},
) where {N} = _cartesian_lattice_neighbor_site(topology, site, offset)

@inline function realize_cartesian_contact_geometry(
        topology::CartesianContactTopology{N},
        site::CartesianIndex{N},
        offset::NTuple{N, <:Integer},
        lane::Integer,
        access::CartesianRelationAccess,
    ) where {N}
    origin = Tuple(site)
    resolved = map(+, origin, map(Int, offset))
    fixed_handle = Int32(0)
    fixed_present = false
    closed = false
    invalid = false
    for axis in 1:N
        value = resolved[axis]
        1 <= value <= topology.shape[axis] && continue
        face = _cartesian_face_index(axis, value > topology.shape[axis])
        kind = @inbounds topology.face_kinds[face]
        if kind === PeriodicCartesianFace
            resolved = Base.setindex(
                resolved, mod1(value, topology.shape[axis]), axis
            )
        elseif kind === ClosedCartesianFace
            invalid |= fixed_present
            closed = true
        else
            handle = @inbounds topology.face_owner_handles[face]
            invalid |= closed || (fixed_present && fixed_handle != handle)
            fixed_handle = handle
            fixed_present = true
        end
    end
    endpoint = map(Int64, resolved)
    access === MutableSiteRelationAccess &&
        (closed || fixed_present || invalid) && return CartesianNeighbor(
            AbsentCartesianNeighbor, Int32(0), Int32(0), Int32(lane), endpoint
        )
    invalid && return CartesianNeighbor(
        InvalidCartesianNeighbor, Int32(0), Int32(0), Int32(lane), endpoint
    )
    closed && return CartesianNeighbor(
        AbsentCartesianNeighbor, Int32(0), Int32(0), Int32(lane), endpoint
    )
    fixed_present && return CartesianNeighbor(
        FixedExteriorCartesianNeighbor, Int32(0),
        _domain_owner_code_from_handle(fixed_handle),
        Int32(lane), endpoint,
    )
    return CartesianNeighbor(
        MutableCartesianNeighbor,
        _cartesian_linear_site(topology.shape, resolved),
        Int32(0), Int32(lane), endpoint,
    )
end

@inline function realize_cartesian_neighbor(
        domain::CartesianOwnershipDomain{N},
        ownership,
        site::CartesianIndex{N},
        offsets,
        direction::Integer,
        access::CartesianRelationAccess,
    ) where {N}
    origin = Tuple(site)
    coordinates = ntuple(
        axis -> origin[axis] + Int(@inbounds offsets[axis, direction]), N
    )
    resolved = coordinates
    fixed_handle = Int32(0)
    fixed_present = false
    closed = false
    invalid = false
    for axis in 1:N
        value = resolved[axis]
        1 <= value <= domain.shape[axis] && continue
        positive = value > domain.shape[axis]
        face = _cartesian_face_index(axis, positive)
        kind = @inbounds domain.face_kinds[face]
        if kind === PeriodicCartesianFace
            wrapped = mod1(value, domain.shape[axis])
            resolved = Base.setindex(resolved, wrapped, axis)
        elseif kind === ClosedCartesianFace
            invalid |= fixed_present
            closed = true
        else
            handle = @inbounds domain.face_owner_handles[face]
            invalid |= closed || (fixed_present && fixed_handle != handle)
            fixed_handle = handle
            fixed_present = true
        end
    end
    endpoint = ntuple(axis -> Int64(resolved[axis]), N)
    access === MutableSiteRelationAccess &&
        (closed || fixed_present || invalid) && return CartesianNeighbor(
            AbsentCartesianNeighbor, Int32(0), Int32(0), Int32(direction), endpoint
        )
    invalid && return CartesianNeighbor(
        InvalidCartesianNeighbor, Int32(0), Int32(0), Int32(direction), endpoint
    )
    closed && return CartesianNeighbor(
        AbsentCartesianNeighbor, Int32(0), Int32(0), Int32(direction), endpoint
    )
    if fixed_present
        access === OwnerRelationAccess || return CartesianNeighbor(
            AbsentCartesianNeighbor, Int32(0), Int32(0), Int32(direction), endpoint
        )
        return CartesianNeighbor(
            FixedExteriorCartesianNeighbor, Int32(0),
            _domain_owner_code_from_handle(fixed_handle),
            Int32(direction), endpoint
        )
    end
    linear = _cartesian_linear_site(domain.shape, resolved)
    if !(@inbounds domain.mutable_mask[linear])
        access === OwnerRelationAccess || return CartesianNeighbor(
            AbsentCartesianNeighbor, Int32(0), Int32(0), Int32(direction), endpoint
        )
        return CartesianNeighbor(
            FixedObstacleCartesianNeighbor,
            linear,
            owner_at(domain, ownership, linear),
            Int32(direction),
            ntuple(axis -> Int64(resolved[axis]), N),
        )
    end
    return CartesianNeighbor(
        MutableCartesianNeighbor,
        linear,
        owner_at(domain, ownership, linear),
        Int32(direction),
        ntuple(axis -> Int64(resolved[axis]), N),
    )
end


@inline realize_cartesian_neighbor(
    domain::CartesianOwnershipDomain{N}, ownership, site::CartesianIndex{N},
    offset::NTuple{N, <:Integer}, access::CartesianRelationAccess,
) where {N} = realize_cartesian_neighbor(
    domain, ownership, site, _SingleCartesianOffset(offset), 1, access
)

function Adapt.adapt_structure(to, domain::CartesianOwnershipDomain)
    owners = Adapt.adapt(to, domain.domain_owners)
    obstacles = Adapt.adapt(to, domain.obstacle_owner_handles)
    mask = Adapt.adapt(to, domain.mutable_mask)
    sites = Adapt.adapt(to, domain.mutable_sites)
    return CartesianOwnershipDomain(
        domain.shape,
        domain.face_kinds,
        domain.face_owner_handles,
        domain.default_owner,
        owners,
        obstacles,
        mask,
        sites,
        _ValidatedCartesianOwnershipDomain(),
    )
end
