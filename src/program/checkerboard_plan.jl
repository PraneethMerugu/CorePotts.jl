# Deterministic realized-domain coloring for the portable checkerboard engine.

"""Supertype for optional checkerboard geometry plans."""
abstract type AbstractCheckerboardPlan end

"""Marker used by non-checkerboard compiled programs."""
struct NoCheckerboardPlan <: AbstractCheckerboardPlan end

struct _VerifiedCheckerboardPlanToken end

@inline function _validate_checkerboard_site_count(site_count::Integer)
    0 <= site_count < typemax(Int32) || throw(ArgumentError(
        "checkerboard site count leaves no representable Int32 offset sentinel"
    ))
    return Int(site_count)
end

"""Validated color classes, site mappings, and proposal geometry for checkerboard execution."""
struct CheckerboardPlan{
        N,
        S <: AbstractVector{Int32},
        O <: AbstractVector{Int32},
        D <: AbstractMatrix{Int16},
    } <: AbstractCheckerboardPlan
    shape::NTuple{N, Int}
    domain_identity::UInt64
    sites::S
    color_offsets::O
    conflict_displacements::D
    color_count::Int32
    maximum_color_size::Int32
    function CheckerboardPlan(
            shape::NTuple{N, Int},
            domain_identity::UInt64,
            sites::S,
            color_offsets::O,
            conflict_displacements::D,
            color_count::Int32,
            maximum_color_size::Int32,
            ::_VerifiedCheckerboardPlanToken,
        ) where {
            N,
            S <: AbstractVector{Int32},
            O <: AbstractVector{Int32},
            D <: AbstractMatrix{Int16},
        }
        return new{N, S, O, D}(
            shape,
            domain_identity,
            sites,
            color_offsets,
            conflict_displacements,
            color_count,
            maximum_color_size,
        )
    end
end

function _canonical_conflict_displacements(
        displacements::AbstractMatrix{<:Integer},
        dimensions::Integer,
    )
    size(displacements, 1) == dimensions || throw(ArgumentError(
        "checkerboard conflict displacements have the wrong dimensionality"
    ))
    values = NTuple{dimensions, Int}[]
    for column in axes(displacements, 2)
        displacement = ntuple(
            dimension -> Int(displacements[dimension, column]), dimensions
        )
        all(iszero, displacement) && continue
        all(value -> typemin(Int16) <= value <= typemax(Int16), displacement) ||
            throw(ArgumentError(
                "checkerboard conflict displacement exceeds Int16"
            ))
        push!(values, displacement)
        push!(values, ntuple(index -> -displacement[index], dimensions))
    end
    sort!(unique!(values))
    result = Matrix{Int16}(undef, dimensions, length(values))
    for (column, displacement) in enumerate(values)
        for dimension in 1:dimensions
            result[dimension, column] = Int16(displacement[dimension])
        end
    end
    return result
end

@inline function _realized_conflict_site(
        domain::CartesianOwnershipDomain{N},
        indices::CartesianIndices{N},
        site::Int,
        displacements::Matrix{Int16},
        column::Int,
    ) where {N}
    neighbor = realize_cartesian_neighbor(
        domain,
        domain.obstacle_owner_handles,
        indices[site],
        displacements,
        column,
        MutableSiteRelationAccess,
    )
    return neighbor.category === MutableCartesianNeighbor ?
        Int(neighbor.site) : 0
end

function _canonical_checkerboard_fields(
        domain::CartesianOwnershipDomain{N},
        displacements::AbstractMatrix{<:Integer},
    ) where {N}
    shape = domain.shape
    all(>(0), shape) || throw(ArgumentError(
        "checkerboard dimensions must be positive"
    ))
    canonical = _canonical_conflict_displacements(displacements, N)
    site_count = _validate_checkerboard_site_count(
        _cartesian_site_count(shape)
    )
    indices = CartesianIndices(shape)
    colors = zeros(Int32, site_count)
    forbidden = falses(size(canonical, 2) + 1)
    maximum_color = 0
    for site32 in domain.mutable_sites
        site = Int(site32)
        fill!(forbidden, false)
        for column in axes(canonical, 2)
            neighbor = _realized_conflict_site(
                domain, indices, site, canonical, column
            )
            (neighbor == 0 || neighbor >= site) && continue
            color = Int(@inbounds colors[neighbor])
            color > 0 && (forbidden[color] = true)
        end
        color = something(findfirst(!, forbidden), length(forbidden) + 1)
        color <= typemax(Int32) || throw(ArgumentError(
            "checkerboard coloring exceeds Int32"
        ))
        colors[site] = Int32(color)
        maximum_color = max(maximum_color, color)
    end

    for site32 in domain.mutable_sites, column in axes(canonical, 2)
        site = Int(site32)
        neighbor = _realized_conflict_site(
            domain, indices, site, canonical, column
        )
        (neighbor == 0 || neighbor == site) && continue
        @inbounds colors[neighbor] != colors[site] || error(
            "checkerboard realized-domain coloring verification failed"
        )
    end

    sites = Int32[]
    offsets = Int32[1]
    maximum_color_size = 0
    for color in 1:maximum_color
        first_index = length(sites) + 1
        for site32 in domain.mutable_sites
            site = Int(site32)
            @inbounds colors[site] == color && push!(sites, Int32(site))
        end
        push!(offsets, Int32(length(sites) + 1))
        maximum_color_size = max(
            maximum_color_size, length(sites) - first_index + 1
        )
    end
    length(sites) == length(domain.mutable_sites) || error(
        "checkerboard coloring did not schedule every mutable site exactly once"
    )
    return (
        sites,
        offsets,
        canonical,
        Int32(maximum_color),
        Int32(maximum_color_size),
    )
end

function CheckerboardPlan(
        domain::CartesianOwnershipDomain{N},
        displacements::AbstractMatrix{<:Integer},
    ) where {N}
    fields = _canonical_checkerboard_fields(domain, displacements)
    return CheckerboardPlan(
        domain.shape,
        cartesian_domain_identity(domain),
        fields...,
        _VerifiedCheckerboardPlanToken(),
    )
end

function CheckerboardPlan(
        domain::CartesianOwnershipDomain{N},
        sites::AbstractVector{Int32},
        color_offsets::AbstractVector{Int32},
        conflict_displacements::AbstractMatrix{Int16},
        color_count::Integer,
        maximum_color_size::Integer,
    ) where {N}
    fields = _canonical_checkerboard_fields(
        domain, conflict_displacements
    )
    supplied = (
        collect(sites),
        collect(color_offsets),
        Matrix(conflict_displacements),
        Int32(color_count),
        Int32(maximum_color_size),
    )
    all(map(isequal, supplied, fields)) || throw(ArgumentError(
        "checkerboard plan fields are not the canonical verified coloring"
    ))
    return CheckerboardPlan(
        domain.shape,
        cartesian_domain_identity(domain),
        fields...,
        _VerifiedCheckerboardPlanToken(),
    )
end

"""Return immutable geometry and coloring facts for a checkerboard plan."""
function checkerboard_plan_report(plan::CheckerboardPlan)
    return (
        algorithm = :canonical_realized_greedy_v1,
        shape = plan.shape,
        domain_identity = plan.domain_identity,
        color_count = Int(plan.color_count),
        maximum_color_size = Int(plan.maximum_color_size),
        site_count = length(plan.sites),
        conflict_displacements = Tuple(
            Tuple(plan.conflict_displacements[:, column])
            for column in axes(plan.conflict_displacements, 2)
        ),
        site_order = Tuple(plan.sites),
    )
end

checkerboard_plan_report(::NoCheckerboardPlan) = nothing

function Adapt.adapt_structure(to, plan::CheckerboardPlan)
    return CheckerboardPlan(
        plan.shape,
        plan.domain_identity,
        Adapt.adapt(to, plan.sites),
        Adapt.adapt(to, plan.color_offsets),
        Adapt.adapt(to, plan.conflict_displacements),
        plan.color_count,
        plan.maximum_color_size,
        _VerifiedCheckerboardPlanToken(),
    )
end
