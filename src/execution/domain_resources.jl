# Value-level tables for resources selected by conservative-energy domains.

struct _ValidatedDomainResourceAdaptation end

"""Compiler-owned contact offsets/measures and relationship-store bindings by source handle."""
struct HamiltonianDomainResources{
        O <: AbstractMatrix{Int8},
        V <: AbstractVector{Int32},
        M <: AbstractVector{<:AbstractFloat},
    }
    contact_offsets::O
    contact_measures::M
    contact_starts::V
    contact_counts::V
    relationship_slots::V
    function HamiltonianDomainResources{O, V, M}(
            contact_offsets::O,
            contact_measures::M,
            contact_starts::V,
            contact_counts::V,
            relationship_slots::V,
        ) where {
            O <: AbstractMatrix{Int8},
            V <: AbstractVector{Int32},
            M <: AbstractVector{<:AbstractFloat},
        }
        length(contact_measures) == size(contact_offsets, 2) ||
            throw(ArgumentError(
                "contact relation measures must have one value per offset lane"
            ))
        all(measure -> isfinite(measure) && measure >= zero(measure),
            contact_measures) || throw(ArgumentError(
            "contact relation measures must be finite and nonnegative"
        ))
        length(contact_starts) == length(contact_counts) ==
            length(relationship_slots) || throw(ArgumentError(
            "Hamiltonian domain-resource tables must share one source-handle range"
        ))
        for handle in eachindex(contact_starts)
            start = contact_starts[handle]
            count = contact_counts[handle]
            count >= 0 || throw(ArgumentError(
                "a contact-domain offset count cannot be negative"
            ))
            if count == 0
                start == 0 || throw(ArgumentError(
                    "an unused contact-domain handle must have a zero start"
                ))
            else
                start > 0 && start + count - 1 <= size(contact_offsets, 2) ||
                    throw(ArgumentError(
                        "a contact-domain handle addresses offsets outside its table"
                    ))
            end
            relationship_slots[handle] >= 0 || throw(ArgumentError(
                "a relationship-domain slot cannot be negative"
            ))
        end
        return new{O, V, M}(
            contact_offsets,
            contact_measures,
            contact_starts,
            contact_counts,
            relationship_slots,
        )
    end

    function HamiltonianDomainResources{O, V, M}(
            contact_offsets::O,
            contact_measures::M,
            contact_starts::V,
            contact_counts::V,
            relationship_slots::V,
            ::_ValidatedDomainResourceAdaptation,
        ) where {
            O <: AbstractMatrix{Int8},
            V <: AbstractVector{Int32},
            M <: AbstractVector{<:AbstractFloat},
        }
        return new{O, V, M}(
            contact_offsets,
            contact_measures,
            contact_starts,
            contact_counts,
            relationship_slots,
        )
    end
end

function HamiltonianDomainResources(
        contact_offsets::AbstractMatrix{Int8},
        contact_measures::AbstractVector{<:AbstractFloat},
        contact_starts::AbstractVector{<:Integer},
        contact_counts::AbstractVector{<:Integer},
        relationship_slots::AbstractVector{<:Integer},
    )
    starts = Int32.(contact_starts)
    counts = Int32.(contact_counts)
    slots = Int32.(relationship_slots)
    return HamiltonianDomainResources{
        typeof(contact_offsets), typeof(starts), typeof(contact_measures),
    }(contact_offsets, contact_measures, starts, counts, slots)
end

HamiltonianDomainResources(dimensions::Integer, source_count::Integer) =
    HamiltonianDomainResources(
        Matrix{Int8}(undef, dimensions, 0),
        Float32[],
        zeros(Int32, source_count),
        zeros(Int32, source_count),
        zeros(Int32, source_count),
    )

@inline function _contact_domain_columns(
        resources::HamiltonianDomainResources,
        handle::Int32,
    )
    1 <= handle <= length(resources.contact_starts) || throw(ArgumentError(
        "contact energy domain references an unknown resource handle"
    ))
    start = @inbounds resources.contact_starts[handle]
    count = @inbounds resources.contact_counts[handle]
    start > 0 && count > 0 || throw(ArgumentError(
        "contact energy domain does not resolve to a finite offset table"
    ))
    return start, count
end

function _validate_contact_measure_aliases(
        resources::HamiltonianDomainResources,
        shape::NTuple{N, Int},
        periodic::NTuple{N, Bool},
    ) where {N}
    iszero(size(resources.contact_offsets, 2)) && return resources
    size(resources.contact_offsets, 1) == N || throw(ArgumentError(
        "contact relation offsets have the wrong dimensionality"
    ))
    for handle in eachindex(resources.contact_starts)
        start = resources.contact_starts[handle]
        count = resources.contact_counts[handle]
        for lane in 1:count
            column = start + lane - 1
            self_alias = true
            for dimension in 1:N
                offset = Int(resources.contact_offsets[dimension, column])
                self_alias &= periodic[dimension] ?
                    iszero(mod(offset, shape[dimension])) : iszero(offset)
            end
            self_alias && throw(ArgumentError(
                "an ordinary spatial relation lane cannot resolve to its " *
                "own anchor under the compiled geometry"
            ))
            for prior_lane in 1:(lane - 1)
                prior = start + prior_lane - 1
                aliases = true
                for dimension in 1:N
                    left = Int(resources.contact_offsets[dimension, column])
                    right = Int(resources.contact_offsets[dimension, prior])
                    aliases &= periodic[dimension] ?
                        mod(left, shape[dimension]) == mod(right, shape[dimension]) :
                        left == right
                end
                aliases || continue
                throw(ArgumentError(
                    "an ordinary spatial relation cannot declare lanes that " *
                    "alias one realized contact under the compiled periodic geometry"
                ))
            end
        end
    end
    return resources
end

"""Return a host-owned copy of one compiled spatial relation's offsets."""
function relation_offsets(
        resources::HamiltonianDomainResources,
        handle::Int32,
    )
    start, count = _contact_domain_columns(resources, handle)
    return resources.contact_offsets[:, start:(start + count - 1)]
end

"""Return a host-owned copy of one compiled spatial relation's lane measures."""
function relation_measures(
        resources::HamiltonianDomainResources,
        handle::Int32,
    )
    start, count = _contact_domain_columns(resources, handle)
    return resources.contact_measures[start:(start + count - 1)]
end

"""Return the declared measure carried by one compiled relation lane."""
@inline function relation_measure(
        resources::HamiltonianDomainResources,
        handle::Int32,
        direction::Integer,
    )
    start, count = _contact_domain_columns(resources, handle)
    1 <= direction <= count || throw(BoundsError(1:count, direction))
    return @inbounds resources.contact_measures[start + direction - 1]
end

@inline function _relationship_domain_slot(
        resources::HamiltonianDomainResources,
        handle::Int32,
    )
    1 <= handle <= length(resources.relationship_slots) || throw(ArgumentError(
        "relationship energy domain references an unknown resource handle"
    ))
    slot = @inbounds resources.relationship_slots[handle]
    slot > 0 || throw(ArgumentError(
        "relationship energy domain does not resolve to runtime storage"
    ))
    return slot
end

function Adapt.adapt_structure(to, resources::HamiltonianDomainResources)
    offsets = Adapt.adapt(to, resources.contact_offsets)
    measures = Adapt.adapt(to, resources.contact_measures)
    starts = Adapt.adapt(to, resources.contact_starts)
    counts = Adapt.adapt(to, resources.contact_counts)
    slots = Adapt.adapt(to, resources.relationship_slots)
    return HamiltonianDomainResources{
        typeof(offsets), typeof(starts), typeof(measures),
    }(
        offsets,
        measures,
        starts,
        counts,
        slots,
        _ValidatedDomainResourceAdaptation(),
    )
end

"""Resolve one finite relation neighbor under the compiled boundary topology."""
@inline function relation_neighbor_index(
        shape::NTuple{N, Int},
        periodic::NTuple{N, Bool},
        index::CartesianIndex{N},
        offsets::AbstractMatrix{Int8},
        direction::Int,
    ) where {N}
    coordinates = Tuple(index)
    candidate = ntuple(N) do dimension
        value = coordinates[dimension] + Int(offsets[dimension, direction])
        if periodic[dimension]
            extent = shape[dimension]
            while value < 1
                value += extent
            end
            while value > extent
                value -= extent
            end
            value
        elseif 1 <= value <= shape[dimension]
            value
        else
            0
        end
    end
    any(iszero, candidate) && return nothing
    return CartesianIndex(candidate)
end

"""Resolve the source whose declared relation lane reaches `index`."""
@inline function reverse_relation_neighbor_index(
        shape::NTuple{N, Int},
        periodic::NTuple{N, Bool},
        index::CartesianIndex{N},
        offsets::AbstractMatrix{Int8},
        direction::Int,
    ) where {N}
    coordinates = Tuple(index)
    candidate = ntuple(N) do dimension
        coordinate = coordinates[dimension] - Int(@inbounds offsets[dimension, direction])
        periodic[dimension] ? mod1(coordinate, shape[dimension]) : coordinate
    end
    all(dimension -> 1 <= candidate[dimension] <= shape[dimension], 1:N) ||
        return nothing
    return CartesianIndex(candidate)
end
