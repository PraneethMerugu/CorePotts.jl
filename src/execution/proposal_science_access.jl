# Narrow scientific reads shared by concrete and gathered proposal contexts.
# These functions express CorePotts meaning without exposing the complete
# runtime container to the algorithms that consume it.

@inline _proposal_science_parameters(science) = science.parameters
@inline _proposal_science_scalar_type(science) =
    eltype(_proposal_science_parameters(science))
@inline _proposal_science_shape(science) = science.program.domain.shape
@inline _proposal_science_domain(science) = science.program.domain
@inline _proposal_science_periodic(science) =
    cartesian_periodic_axes(_proposal_science_domain(science))

@inline _proposal_science_site_owner(science, site) =
    owner_at(_proposal_science_domain(science), science.ownership, site)

@inline function _proposal_science_owner_kind(science, owner::Int32)
    return owner_kind(
        _proposal_science_domain(science),
        science.cell_kinds,
        owner,
    )
end

@inline _proposal_science_owner_generation(science, owner::Int32) = owner_generation(
    science.cell_generations,
    owner,
)

@inline function _proposal_science_neighbor(
        science,
        site::CartesianIndex{N},
        offsets,
        direction::Integer,
    ) where {N}
    return realize_cartesian_neighbor(
        _proposal_science_domain(science),
        science.ownership,
        site,
        offsets,
        direction,
        OwnerRelationAccess,
    )
end

@inline function _proposal_science_reverse_neighbor(
        science,
        site::CartesianIndex{N},
        offsets,
        direction::Integer,
    ) where {N}
    offset = ntuple(
        axis -> -Int(@inbounds offsets[axis, direction]), N
    )
    neighbor = realize_cartesian_neighbor(
        _proposal_science_domain(science), science.ownership, site, offset,
        MutableSiteRelationAccess,
    )
    return neighbor.category === MutableCartesianNeighbor ?
        CartesianIndices(_proposal_science_shape(science))[Int(neighbor.site)] :
        nothing
end

@inline _proposal_science_linear_site(science, site) =
    LinearIndices(_proposal_science_shape(science))[site]

@inline _proposal_science_state_value(science, handle::StateHandle, site) =
    @inbounds state_block(science.descriptor_state, handle).values[site]

@inline _proposal_science_tracker_value(science, key, owner::Int32) =
    program_tracker_value(science, key, owner)

@inline function _proposal_science_tracker_value_after(
        science,
        key,
        owner::Int32,
        target,
        old_owner::Int32,
        new_owner::Int32,
    )
    source = tracker_source_view(science.program, science.ownership)
    return tracker_value_after(
        science.program.tracker_plan,
        science.trackers,
        source,
        key,
        owner,
        target,
        old_owner,
        new_owner,
    )
end

@inline function _proposal_science_qualified_tracker_value(
        science,
        quantity,
        source_handle::Int32,
        owner::Int32,
    )
    return qualified_tracker_value(
        science.program.tracker_plan,
        science.trackers,
        quantity,
        source_handle,
        owner,
    )
end

@inline function _proposal_science_qualified_tracker_value_after(
        science,
        quantity,
        source_handle::Int32,
        owner::Int32,
        target,
        old_owner::Int32,
        new_owner::Int32,
    )
    source = tracker_source_view(science.program, science.ownership)
    return tracker_value_after(
        science.program.tracker_plan,
        science.trackers,
        source,
        quantity,
        source_handle,
        owner,
        target,
        old_owner,
        new_owner,
    )
end

@inline _proposal_science_cell_center(science, owner::Int32; kwargs...) =
    _cell_center(science, owner; kwargs...)
@inline _proposal_science_cell_length(science, owner::Int32; kwargs...) =
    _cell_length(science, owner; kwargs...)

@inline _proposal_science_relationships(science) = science.relationships

@inline function _proposal_science_relationship_call(
        operation,
        science,
        slot::Integer,
        arguments::Tuple,
    )
    return _call_relationship_slot(
        operation,
        _proposal_science_relationships(science),
        Int32(slot),
        arguments,
    )
end
