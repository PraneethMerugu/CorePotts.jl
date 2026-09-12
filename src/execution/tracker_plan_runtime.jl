@inline function copyto_tracker_state!(
        destination::TrackerState,
        source::TrackerState,
        to_host = identity,
    )
    _copyto_tracker_state!(destination.values, source.values, to_host)
    return destination
end

@inline _validate_tracker_updates(
    ::Tuple{}, ::Tuple{}, source, target, old_owner, new_owner, delta_function
) = nothing

@inline _tracker_update_bound(descriptor, source) = tracker_contract(descriptor).update_bound

@inline function _validate_owner_index(values, owner::Int32)
    owner <= 0 && return nothing
    owner <= size(values, ndims(values)) || throw(BoundsError(values, owner))
    return nothing
end

@inline _checked_tracker_add(value::T, delta::T) where {T<:Integer} =
    Base.Checked.checked_add(value, delta)
@inline _checked_tracker_sub(value::T, delta::T) where {T<:Integer} =
    Base.Checked.checked_sub(value, delta)
@inline function _checked_tracker_add(value::T, delta::T) where {T<:AbstractFloat}
    result = value + delta
    isfinite(value) && isfinite(delta) && isfinite(result) || throw(
        ArgumentError("tracker ownership update produced a nonfinite value"))
    return result
end
@inline function _checked_tracker_sub(value::T, delta::T) where {T<:AbstractFloat}
    result = value - delta
    isfinite(value) && isfinite(delta) && isfinite(result) || throw(
        ArgumentError("tracker ownership update produced a nonfinite value"))
    return result
end

@inline function _checked_tracker_add(value::T, delta::T) where {T <: StaticArrays.SArray}
    result = value + delta
    all(isfinite, value) && all(isfinite, delta) && all(isfinite, result) || throw(
        ArgumentError("tracker ownership update produced a nonfinite value")
    )
    return result
end
@inline function _checked_tracker_sub(value::T, delta::T) where {T <: StaticArrays.SArray}
    result = value - delta
    all(isfinite, value) && all(isfinite, delta) && all(isfinite, result) || throw(
        ArgumentError("tracker ownership update produced a nonfinite value")
    )
    return result
end

@inline function _validate_owner_value_delta(values, delta::OwnerValueDelta,
        old_owner::Int32, new_owner::Int32)
    if old_owner > 0
        value = @inbounds values[Int(old_owner)]
        value = _checked_tracker_sub(value, delta.amount)
        if old_owner == new_owner
            _checked_tracker_add(value, delta.amount)
            return nothing
        end
    end
    new_owner > 0 &&
        _checked_tracker_add(@inbounds(values[Int(new_owner)]), delta.amount)
    return nothing
end

@inline function _validate_owner_value_delta(values, delta::OldNewOwnerValueDelta,
        old_owner::Int32, new_owner::Int32)
    if old_owner > 0
        value = @inbounds values[Int(old_owner)]
        value = _checked_tracker_add(value, delta.old_amount)
        if old_owner == new_owner
            _checked_tracker_add(value, delta.new_amount)
            return nothing
        end
    end
    new_owner > 0 &&
        _checked_tracker_add(@inbounds(values[Int(new_owner)]), delta.new_amount)
    return nothing
end

@inline function _validate_tracker_delta(
        values::AbstractVector{T},
        ::Union{DenseOwnerScalarStorage{T}, DenseOwnerValueStorage{T}},
        delta::Union{OwnerValueDelta{T},OldNewOwnerValueDelta{T}},
        old_owner::Int32,
        new_owner::Int32,
    ) where {T}
    _validate_owner_index(values, old_owner)
    _validate_owner_index(values, new_owner)
    _validate_owner_value_delta(values, delta, old_owner, new_owner)
    return nothing
end

@inline function _validate_tracker_delta(
        state::CellMomentsState{T},
        ::DenseOwnerMomentsStorage{N,T},
        delta::OwnerMomentsDelta,
        old_owner::Int32,
        new_owner::Int32,
    ) where {N,T}
    length(delta.first) == N && length(delta.second) == N * N || throw(
        ArgumentError("tracker ownership delta violates its bounded moments contract")
    )
    all(value -> value isa T, delta.first) &&
        all(value -> value isa T, delta.second) || throw(ArgumentError(
            "tracker ownership delta element types differ from tracker storage"
        ))
    _validate_owner_index(state.first, old_owner)
    _validate_owner_index(state.first, new_owner)
    _validate_moment_components(
        state.first, delta.first, old_owner, new_owner)
    _validate_moment_components(
        state.second, delta.second, old_owner, new_owner)
    return nothing
end

@inline function _validate_moment_components(
        values,
        delta_values,
        old_owner::Int32,
        new_owner::Int32,
    )
    for row in eachindex(delta_values)
        component = @inbounds delta_values[row]
        if old_owner > 0
            value = _checked_tracker_sub(
                @inbounds(values[row, Int(old_owner)]), component)
            if old_owner == new_owner
                _checked_tracker_add(value, component)
                continue
            end
        end
        new_owner > 0 && _checked_tracker_add(
            @inbounds(values[row, Int(new_owner)]), component)
    end
    return nothing
end

@inline function _validate_tracker_delta(
        values,
        storage,
        delta,
        old_owner::Int32,
        new_owner::Int32,
    )
    throw(ArgumentError(
        "tracker ownership delta does not satisfy its storage contract"
    ))
end

@inline function _validate_group_tracker_delta(
        values::AbstractMatrix{T},
        column::Int,
        delta::Union{OwnerValueDelta{T},OldNewOwnerValueDelta{T}},
        old_owner::Int32,
        new_owner::Int32,
    ) where {T}
    1 <= column <= size(values, 2) || throw(BoundsError(values, (:, column)))
    old_owner <= 0 || old_owner <= size(values, 1) ||
        throw(BoundsError(values, (old_owner, column)))
    new_owner <= 0 || new_owner <= size(values, 1) ||
        throw(BoundsError(values, (new_owner, column)))
    _validate_owner_value_delta(view(values, :, column), delta, old_owner, new_owner)
    return nothing
end

@inline function _validate_group_tracker_delta(
        values,
        column::Int,
        delta,
        old_owner::Int32,
        new_owner::Int32,
    )
    throw(ArgumentError(
        "grouped tracker ownership delta does not satisfy its storage contract"
    ))
end

@inline function _apply_group_tracker_delta!(
        values,
        column::Int,
        delta::OwnerValueDelta,
        old_owner::Int32,
        new_owner::Int32,
    )
    old_owner > 0 && (@inbounds values[Int(old_owner), column] -= delta.amount)
    new_owner > 0 && (@inbounds values[Int(new_owner), column] += delta.amount)
    return nothing
end

@inline function _apply_validated_tracker_delta!(
        values::AbstractVector{T},
        delta::OwnerValueDelta{T},
        old_owner::Int32,
        new_owner::Int32,
    ) where {T}
    old_owner > 0 && (@inbounds values[Int(old_owner)] -= delta.amount)
    new_owner > 0 && (@inbounds values[Int(new_owner)] += delta.amount)
    return nothing
end

@inline function _apply_validated_tracker_delta!(
        values::AbstractVector{T},
        delta::OldNewOwnerValueDelta{T},
        old_owner::Int32,
        new_owner::Int32,
    ) where {T}
    old_owner > 0 &&
        (@inbounds values[Int(old_owner)] += delta.old_amount)
    new_owner > 0 &&
        (@inbounds values[Int(new_owner)] += delta.new_amount)
    return nothing
end

@inline function _apply_validated_tracker_delta!(
        state::CellMomentsState{T},
        delta::OwnerMomentsDelta,
        old_owner::Int32,
        new_owner::Int32,
    ) where {T}
    dimensions = length(delta.first)
    for row in 1:dimensions
        coordinate = delta.first[row]
        old_owner > 0 &&
            (@inbounds state.first[row, Int(old_owner)] -= coordinate)
        new_owner > 0 &&
            (@inbounds state.first[row, Int(new_owner)] += coordinate)
        for column in 1:dimensions
            slot = row + (column - 1) * dimensions
            product = delta.second[slot]
            old_owner > 0 &&
                (@inbounds state.second[slot, Int(old_owner)] -= product)
            new_owner > 0 &&
                (@inbounds state.second[slot, Int(new_owner)] += product)
        end
    end
    return nothing
end

@inline function _apply_group_tracker_delta!(
        values,
        column::Int,
        delta::OldNewOwnerValueDelta,
        old_owner::Int32,
        new_owner::Int32,
    )
    old_owner > 0 &&
        (@inbounds values[Int(old_owner), column] += delta.old_amount)
    new_owner > 0 &&
        (@inbounds values[Int(new_owner), column] += delta.new_amount)
    return nothing
end

@inline function _validate_tracker_updates(
        descriptors::Tuple{G, Vararg},
        values::Tuple,
        source,
        target,
        old_owner,
        new_owner,
        delta_function,
    ) where {G <: Union{DenseScalarTrackerGroup, _DenseScalarTrackerKernelGroup}}
    group = first(descriptors)
    group_values = first(values)
    for index in eachindex(group.descriptors)
        descriptor = @inbounds group.descriptors[index]
        _tracker_update_bound(descriptor, source) isa OldNewOwnerUpdateBound || continue
        delta = delta_function(
            descriptor, source, target, old_owner, new_owner
        )
        _validate_group_tracker_delta(
            group_values, index, delta, old_owner, new_owner
        )
    end
    return _validate_tracker_updates(
        Base.tail(descriptors),
        Base.tail(values),
        source,
        target,
        old_owner,
        new_owner,
        delta_function,
    )
end

@inline function _validate_tracker_updates(
        descriptors::Tuple,
        values::Tuple,
        source,
        target,
        old_owner,
        new_owner,
        delta_function,
    )
    descriptor = first(descriptors)
    contract = tracker_contract(descriptor)
    if _tracker_update_bound(descriptor, source) isa OldNewOwnerUpdateBound
        delta = delta_function(descriptor, source, target, old_owner, new_owner)
        delta isa AbstractTrackerDelta || throw(
            ArgumentError(
                "tracker ownership delta must satisfy the closed delta protocol"
            )
        )
        _validate_tracker_delta(first(values), contract.storage, delta, old_owner, new_owner)
    end
    return _validate_tracker_updates(
        Base.tail(descriptors),
        Base.tail(values),
        source,
        target,
        old_owner,
        new_owner,
        delta_function,
    )
end

@inline _apply_tracker_updates!(
    ::Tuple{}, ::Tuple{}, source, target, old_owner, new_owner, delta_function
) = nothing

@inline function _apply_tracker_updates!(
        descriptors::Tuple{G, Vararg},
        values::Tuple,
        source,
        target,
        old_owner,
        new_owner,
        delta_function,
    ) where {G <: Union{DenseScalarTrackerGroup, _DenseScalarTrackerKernelGroup}}
    group = first(descriptors)
    group_values = first(values)
    for index in eachindex(group.descriptors)
        descriptor = @inbounds group.descriptors[index]
        _tracker_update_bound(descriptor, source) isa OldNewOwnerUpdateBound || continue
        delta = delta_function(
            descriptor, source, target, old_owner, new_owner
        )
        _apply_group_tracker_delta!(
            group_values, index, delta, old_owner, new_owner
        )
    end
    return _apply_tracker_updates!(
        Base.tail(descriptors), Base.tail(values), source, target,
        old_owner, new_owner, delta_function,
    )
end


@inline function _apply_tracker_updates!(
        descriptors::Tuple,
        values::Tuple,
        source,
        target,
        old_owner,
        new_owner,
        delta_function,
    )
    descriptor = first(descriptors)
    if _tracker_update_bound(descriptor, source) isa OldNewOwnerUpdateBound
        delta = delta_function(descriptor, source, target, old_owner, new_owner)
        _apply_validated_tracker_delta!(first(values), delta, old_owner, new_owner)
    end
    return _apply_tracker_updates!(
        Base.tail(descriptors), Base.tail(values), source, target,
        old_owner, new_owner, delta_function,
    )
end

@inline function commit_tracker_updates!(
        state::TrackerState,
        plan::AbstractTrackerPlan,
        source::AbstractTrackerCommitSource,
        target,
        old_owner::Int32,
        new_owner::Int32,
        delta_function = _source_dependent_tracker_ownership_delta,
    )
    _validate_tracker_updates(
        plan.descriptors, state.values, source, target, old_owner, new_owner, delta_function
    )
    _apply_tracker_updates!(
        plan.descriptors, state.values, source, target, old_owner, new_owner, delta_function
    )
    return nothing
end

@inline _finish_tracker_source_change!(::AbstractTrackerDescriptor, values, source, target, old_owner, owner, cell_kinds) = nothing
@inline function _finish_tracker_source_change!(descriptor::SiteSumTracker, values, source, target, old_owner, owner, cell_kinds)
    owner > 0 || return nothing
    amount = _site_tracker_contribution(descriptor, source, target)
    _validate_owner_index(values, owner)
    @inbounds values[Int(owner)] = _checked_tracker_add(values[Int(owner)], amount)
    return nothing
end
@inline function _finish_tracker_source_change!(group::DenseScalarTrackerGroup, values, source, target, old_owner, owner, cell_kinds)
    for index in eachindex(group.descriptors)
        _finish_tracker_source_change!(group.descriptors[index], view(values, :, index), source, target, old_owner, owner, cell_kinds)
    end
    return nothing
end
@inline function _finish_tracker_source_change!(group::_DenseScalarTrackerKernelGroup, values, source, target, old_owner, owner, cell_kinds)
    for index in eachindex(group.descriptors)
        _finish_tracker_source_change!(getfield(group.descriptors, index), view(values, :, index), source, target, old_owner, owner, cell_kinds)
    end
    return nothing
end
@inline _finish_tracker_source_change!(::Tuple{}, ::Tuple{}, source, target, old_owner, owner, cell_kinds) = nothing
@inline function _finish_tracker_source_change!(descriptors::Tuple, values::Tuple, source, target, old_owner, owner, cell_kinds)
    _finish_tracker_source_change!(first(descriptors), first(values), source, target, old_owner, owner, cell_kinds)
    return _finish_tracker_source_change!(Base.tail(descriptors), Base.tail(values), source, target, old_owner, owner, cell_kinds)
end


@inline function _owner_value_after(
        value,
        delta::OwnerValueDelta,
        owner::Int32,
        old_owner::Int32,
        new_owner::Int32,
    )
    owner == old_owner && (value -= delta.amount)
    owner == new_owner && (value += delta.amount)
    return value
end

@inline function _owner_value_after(
        value,
        delta::OldNewOwnerValueDelta,
        owner::Int32,
        old_owner::Int32,
        new_owner::Int32,
    )
    owner == old_owner && (value += delta.old_amount)
    owner == new_owner && (value += delta.new_amount)
    return value
end

@inline function _tracker_value_after(
        quantity,
        descriptors::Tuple,
        values::Tuple,
        source::TrackerSourceView,
        owner::Int32,
        target,
        old_owner::Int32,
        new_owner::Int32,
    )
    descriptor = first(descriptors)
    if isequal(tracker_quantity(descriptor), quantity)
        owner <= 0 && return zero(eltype(first(values)))
        value = @inbounds first(values)[Int(owner)]
        delta = _source_dependent_tracker_ownership_delta(
            descriptor, source, target, old_owner, new_owner
        )
        return _owner_value_after(
            value, delta, owner, old_owner, new_owner
        )
    end
    return _tracker_value_after(
        quantity,
        Base.tail(descriptors),
        Base.tail(values),
        source,
        owner,
        target,
        old_owner,
        new_owner,
    )
end


@inline function _tracker_value_after(
        quantity,
        ::Tuple{},
        ::Tuple{},
        source::TrackerSourceView,
        owner::Int32,
        target,
        old_owner::Int32,
        new_owner::Int32,
    )
    throw(ArgumentError("compiled tracker quantity $(repr(quantity)) is unavailable"))
end

@inline tracker_value_after(
    plan::AbstractTrackerPlan,
    state::TrackerState,
    source::TrackerSourceView,
    quantity,
    owner::Int32,
    target,
    old_owner::Int32,
    new_owner::Int32,
) = _tracker_value_after(
    quantity,
    plan.descriptors,
    state.values,
    source,
    owner,
    target,
    old_owner,
    new_owner,
)

@generated function _qualified_owner_value_after(
        quantity::Val{Q},
        source_handle::Int32,
        descriptors::D,
        values::V,
        source::TrackerSourceView,
        owner::Int32,
        target,
        old_owner::Int32,
        new_owner::Int32,
    ) where {Q, D <: Tuple, V <: Tuple}
    indices = findall(
        descriptor_type -> descriptor_type <: AbstractTrackerDescriptor,
        D.parameters,
    )
    group_indices = findall(
        descriptor_type -> descriptor_type <: Union{
            DenseScalarTrackerGroup{Val{Q}},
            _DenseScalarTrackerKernelGroup{Val{Q}},
        },
        D.parameters,
    )
    result = :(throw(ArgumentError(
        "compiled qualified tracker source is unavailable"
    )))
    for index in reverse(indices)
        result = quote
            key = tracker_quantity(descriptors[$index])
            if key isa QualifiedTrackerKey{Val{$(QuoteNode(Q))}} &&
                    key.source_handle == source_handle
                owner <= 0 && return zero(eltype(values[$index]))
                value = @inbounds values[$index][Int(owner)]
                delta = _source_dependent_tracker_ownership_delta(
                    descriptors[$index],
                    source,
                    target,
                    old_owner,
                    new_owner,
                )
                return _owner_value_after(
                    value, delta, owner, old_owner, new_owner
                )
            end
            $result
        end
    end
    for index in reverse(group_indices)
        result = quote
            group = descriptors[$index]
            group_values = values[$index]
            for column in eachindex(group.descriptors)
                descriptor = @inbounds group.descriptors[column]
                if @inbounds(group.source_handles[column]) == source_handle
                    owner <= 0 && return zero(eltype(group_values))
                    value = @inbounds group_values[Int(owner), column]
                    delta = _source_dependent_tracker_ownership_delta(
                        descriptor,
                        source,
                        target,
                        old_owner,
                        new_owner,
                    )
                    return _owner_value_after(
                        value, delta, owner, old_owner, new_owner
                    )
                end
            end
            $result
        end
    end
    return result
end

@generated function _qualified_owner_value(
        quantity::Val{Q},
        source_handle::Int32,
        descriptors::D,
        values::V,
        owner::Int32,
    ) where {Q, D <: Tuple, V <: Tuple}
    indices = findall(
        descriptor_type -> descriptor_type <: AbstractTrackerDescriptor,
        D.parameters,
    )
    group_indices = findall(
        descriptor_type -> descriptor_type <: Union{
            DenseScalarTrackerGroup{Val{Q}},
            _DenseScalarTrackerKernelGroup{Val{Q}},
        },
        D.parameters,
    )
    result = :(throw(ArgumentError(
        "compiled qualified tracker source is unavailable"
    )))
    for index in reverse(indices)
        result = quote
            key = tracker_quantity(descriptors[$index])
            if key isa QualifiedTrackerKey{Val{$(QuoteNode(Q))}} &&
                    key.source_handle == source_handle
                owner <= 0 && return zero(eltype(values[$index]))
                return @inbounds values[$index][Int(owner)]
            end
            $result
        end
    end
    for index in reverse(group_indices)
        result = quote
            group = descriptors[$index]
            group_values = values[$index]
            for column in eachindex(group.source_handles)
                if @inbounds(group.source_handles[column]) == source_handle
                    owner <= 0 && return zero(eltype(group_values))
                    return @inbounds group_values[Int(owner), column]
                end
            end
            $result
        end
    end
    return result
end

@inline qualified_tracker_value(
    plan::AbstractTrackerPlan,
    state::TrackerState,
    quantity::Val,
    source_handle::Int32,
    owner::Int32,
) = _qualified_owner_value(
    quantity, source_handle, plan.descriptors, state.values, owner
)

@inline tracker_value_after(
    plan::AbstractTrackerPlan,
    state::TrackerState,
    source::TrackerSourceView,
    key::QualifiedTrackerKey,
    owner::Int32,
    target,
    old_owner::Int32,
    new_owner::Int32,
) = _qualified_owner_value_after(
    key.quantity,
    key.source_handle,
    plan.descriptors,
    state.values,
    source,
    owner,
    target,
    old_owner,
    new_owner,
)

@inline tracker_value_after(
    plan::AbstractTrackerPlan,
    state::TrackerState,
    source::TrackerSourceView,
    quantity::Val,
    source_handle::Int32,
    owner::Int32,
    target,
    old_owner::Int32,
    new_owner::Int32,
) = _qualified_owner_value_after(
    quantity,
    source_handle,
    plan.descriptors,
    state.values,
    source,
    owner,
    target,
    old_owner,
    new_owner,
)

@inline function _tracker_values(
        quantity, descriptors::Tuple, values::Tuple
    )
    isequal(tracker_quantity(first(descriptors)), quantity) &&
        return first(values)
    return _tracker_values(quantity, Base.tail(descriptors), Base.tail(values))
end

@inline function _tracker_values(
        key::QualifiedTrackerKey,
        descriptors::Tuple{G, Vararg},
        values::Tuple,
    ) where {G <: Union{DenseScalarTrackerGroup, _DenseScalarTrackerKernelGroup}}
    group = first(descriptors)
    isequal(group.quantity, key.quantity) || return _tracker_values(
        key, Base.tail(descriptors), Base.tail(values)
    )
    index = findfirst(==(key.source_handle), group.source_handles)
    index === nothing || return view(first(values), :, index)
    return _tracker_values(key, Base.tail(descriptors), Base.tail(values))
end

@inline function _tracker_values(
        quantity,
        descriptors::Tuple{G, Vararg},
        values::Tuple,
    ) where {G <: Union{DenseScalarTrackerGroup, _DenseScalarTrackerKernelGroup}}
    return _tracker_values(quantity, Base.tail(descriptors), Base.tail(values))
end

@inline function _tracker_values(quantity, ::Tuple{}, ::Tuple{})
    throw(ArgumentError("compiled tracker quantity $(repr(quantity)) is unavailable"))
end

@inline tracker_values(
    plan::AbstractTrackerPlan, state::TrackerState, quantity
) = _tracker_values(quantity, plan.descriptors, state.values)

@inline function tracker_value(
        plan::AbstractTrackerPlan,
        state::TrackerState,
        quantity,
        index::Integer,
    )
    return @inbounds tracker_values(plan, state, quantity)[Int(index)]
end

"""Return the runtime storage associated with a qualified tracker quantity."""
@inline program_tracker_values(runtime, quantity) = tracker_values(
    runtime.program.tracker_plan, runtime.trackers, quantity
)

@inline program_tracker_values(program, snapshot, quantity) = tracker_values(
    program.tracker_plan, snapshot.trackers, quantity
)

@inline program_tracker_value(runtime, quantity, index::Integer) =
    tracker_value(runtime.program.tracker_plan, runtime.trackers, quantity, index)

_tracker_recomputation_matches(::AbstractTrackerDescriptor, actual, expected) = actual == expected
function _site_sum_values_match(descriptor::SiteSumTracker, cached, recomputed)
    isfinite(cached) && isfinite(recomputed) || return false
    cached == recomputed && return true
    difference = abs(cached - recomputed)
    difference <= descriptor.absolute_tolerance && return true
    iszero(descriptor.relative_tolerance) && return false
    scale = max(abs(cached), abs(recomputed))
    # Opposite finite extremes may overflow subtraction. Compare scaled values
    # in that case instead of accepting a spurious Inf <= Inf tolerance test.
    relative_difference = isfinite(difference) ? difference / scale :
        abs(cached / scale - recomputed / scale)
    return relative_difference <= descriptor.relative_tolerance
end
function _site_sum_values_match(
        descriptor::SiteSumTracker,
        cached::StaticArrays.SArray,
        recomputed::StaticArrays.SArray,
    )
    axes(cached) == axes(recomputed) || return false
    return all(zip(cached, recomputed)) do (cached_component, recomputed_component)
        _site_sum_values_match(descriptor, cached_component, recomputed_component)
    end
end
function _tracker_recomputation_matches(descriptor::SiteSumTracker, actual, expected)
    axes(actual) == axes(expected) || return false
    return all(zip(actual, expected)) do (cached, recomputed)
        _site_sum_values_match(descriptor, cached, recomputed)
    end
end
function _tracker_recomputation_matches(group::DenseScalarTrackerGroup, actual, expected)
    axes(actual) == axes(expected) || return false
    return all(eachindex(group.descriptors)) do index
        _tracker_recomputation_matches(group.descriptors[index],
            view(actual, :, index), view(expected, :, index))
    end
end

function validate_tracker_state!(
        plan::AbstractTrackerPlan,
        state::TrackerState,
        ownership,
        cell_kinds,
        program;
        parameters = (), descriptor_state = nothing,
    )
    length(plan.descriptors) == length(state.values) || throw(ArgumentError(
        "tracker plan and runtime state are misaligned"
    ))
    source = tracker_source_view(program, ownership; parameters, descriptor_state)
    for index in eachindex(state.values)
        descriptor = plan.descriptors[index]
        expected = tracker_recompute(descriptor, source, cell_kinds)
        _validate_tracker_state(
            tracker_storage(descriptor),
            expected,
            length(cell_kinds),
        )
        _tracker_recomputation_matches(descriptor, state.values[index], expected) || throw(ArgumentError(
            "tracker $(tracker_quantities(plan.descriptors[index])) " *
            "differs from its independent recomputation oracle"
        ))
    end
    return state
end

_tracker_uses_inputs(descriptor::AbstractTrackerDescriptor) =
    tracker_contract(descriptor).source isa SiteExpressionTrackerSource
_tracker_uses_inputs(group::DenseScalarTrackerGroup) = any(_tracker_uses_inputs, group.descriptors)

_rebuild_input_tracker(descriptor::_SiteExpressionTracker, source, cell_kinds; backend, copy_source) =
    _execute_site_tracker_rebuild(descriptor, source, cell_kinds; backend, copy_source)

function _rebuild_input_tracker(group::DenseScalarTrackerGroup, source, cell_kinds; backend, copy_source)
    columns = map(group.descriptors) do descriptor
        _rebuild_input_tracker(descriptor, source, cell_kinds; backend, copy_source)
    end
    first_values = first(columns)
    values = similar(first_values, eltype(first_values), length(cell_kinds), length(columns))
    for (index, column) in enumerate(columns)
        copyto!(view(values, :, index), column)
    end
    return values
end

function _input_tracker_candidate(plan, trackers, source, cell_kinds;
        backend = KernelAbstractions.CPU(), copy_source = false)
    return TrackerState(map(plan.descriptors, trackers.values) do descriptor, current
        _tracker_uses_inputs(descriptor) || return current
        replacement = _rebuild_input_tracker(descriptor, source, cell_kinds; backend, copy_source)
        return _validate_tracker_state(tracker_storage(descriptor), replacement, length(cell_kinds))
    end)
end

function _require_tracker_value_copy_compatible(destination::AbstractArray, source::AbstractArray)
    eltype(destination) === eltype(source) && size(destination) == size(source) ||
        throw(ArgumentError("tracker publication requires matching logical value types and shapes"))
    return nothing
end
function _require_tracker_value_copy_compatible(destination::CellMomentsState, source::CellMomentsState)
    _require_tracker_value_copy_compatible(destination.first, source.first)
    _require_tracker_value_copy_compatible(destination.second, source.second)
    return nothing
end
function _require_tracker_copy_compatible(destination::TrackerState, source::TrackerState)
    length(destination.values) == length(source.values) || throw(ArgumentError("tracker publication requires matching quantity inventories"))
    foreach(_require_tracker_value_copy_compatible, destination.values, source.values)
    return nothing
end

function _copy_input_tracker_state!(destination, candidate, plan, to_host = identity)
    for (descriptor, target, source) in zip(plan.descriptors, destination.values, candidate.values)
        _tracker_uses_inputs(descriptor) || continue
        target === source || copyto!(target, _tracker_state_to_host(to_host, source))
    end
    return destination
end

_tracker_instances(::Tuple{}) = ()
_tracker_instances(descriptors::Tuple{D, Vararg}) where {D} =
    (first(descriptors), _tracker_instances(Base.tail(descriptors))...)
_tracker_instances(
    descriptors::Tuple{G, Vararg},
) where {G <: Union{DenseScalarTrackerGroup, _DenseScalarTrackerKernelGroup}} = (
    Tuple(first(descriptors).descriptors)...,
    _tracker_instances(Base.tail(descriptors))...,
)

"""Flatten a tracker plan into its ordered concrete descriptor instances."""
function tracker_instances(plan::AbstractTrackerPlan)
    return _tracker_instances(plan.descriptors)
end

function tracker_plan_report(plan::TrackerExecutionPlan)
    instances = tracker_instances(plan)
    return (
        count = length(instances),
        groups = length(plan.descriptors),
        quantities = map(
            descriptor -> _tracker_quantity_symbol(
                tracker_quantity(descriptor)
            ),
            instances,
        ),
        descriptors = map(tracker_inspection, instances),
        checkpoint = map(tracker_checkpoint_policy, instances),
        fingerprint = plan.fingerprint,
    )
end

Adapt.@adapt_structure OwnershipCountTracker
Adapt.@adapt_structure CellSurfaceTracker
Adapt.@adapt_structure DenseScalarTrackerGroup
Adapt.adapt_structure(to, descriptor::CellMomentsTracker) = descriptor
Adapt.@adapt_structure CellMomentsState
Adapt.@adapt_structure TrackerExecutionPlan
Adapt.@adapt_structure TrackerKernelPlan
Adapt.@adapt_structure TrackerState
Adapt.@adapt_structure TrackerCheckpointState
