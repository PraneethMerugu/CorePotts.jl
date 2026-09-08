# Semantic RNG addressing owned by the compiled program runtime.

"""Pack the complete seed/replica/repeat tuple without truncation."""
@inline _trajectory_key(seed::UInt64, replica::UInt32, repeat::UInt32) =
    (seed, UInt64(replica) | (UInt64(repeat) << 32))

@inline function _lifecycle_address(
        stream::RNGStream, runtime,
        operation::RNGOperationKey, anchor::Integer, generation::Integer,
        occurrence::Integer; destination::Bool = false, draw::Integer = 0
    )
    entity_kind = destination ? DestinationEntity :
        anchor > 0 ? CellEntity : ModelEntity
    return RNGAddress(
        stream = stream, mcs = runtime.mcs + 1,
        operation = operation, entity_kind = entity_kind, entity = max(anchor, 0),
        generation = generation, invocation = occurrence, draw = draw
    )
end

@inline function _lifecycle_uniform(
        ::Type{T}, runtime, stream::RNGStream,
        operation, anchor, generation, occurrence;
        destination = false, draw = 0
    ) where {T}
    address = _lifecycle_address(
        stream, runtime, operation, anchor, generation,
        occurrence; destination, draw
    )
    return uniform_open01(
        T, Philox4x64x10V3(),
        _trajectory_key(runtime.seed, runtime.replica, runtime.repeat), address
    )
end

"""Draw a deterministic initialization sample bounded by the supplied limits."""
function initialization_bounded(
        seed::UInt64, replica::UInt32, repeat::UInt32,
        operation::RNGOperationKey, invocation::Integer, bound::Integer
    )
    0 <= invocation <= typemax(UInt32) || throw(
        ArgumentError(
            "initialization invocation is outside the RNG address domain"
        )
    )
    0 < bound <= typemax(UInt32) || throw(
        ArgumentError(
            "initialization draw bound is outside UInt32"
        )
    )
    address = RNGAddress(
        stream = InitializationStream, mcs = 0,
        operation = operation, entity_kind = GlobalEntity, invocation = invocation
    )
    return Int(
        bounded_uint(
            Philox4x64x10V3(),
            _trajectory_key(seed, replica, repeat), address, UInt32(bound)
        )
    ) + 1
end

@inline function _program_address(
        stream::RNGStream, mcs::Int,
        operation::RNGOperationKey, entity::Integer;
        subround::Integer = 0, draw::Integer = 0
    )
    return RNGAddress(
        stream = stream, mcs = mcs, subround = subround,
        operation = operation, entity_kind = SiteEntity, entity = entity, draw = draw
    )
end

@inline function _program_bounded(
        runtime, stream::RNGStream, operation,
        entity, bound; subround = 0, draw = 0
    )
    address = _program_address(stream, runtime.mcs + 1, operation, entity; subround, draw)
    return Int(
        bounded_uint(
            Philox4x64x10V3(),
            _trajectory_key(runtime.seed, runtime.replica, runtime.repeat),
            address, UInt32(bound)
        )
    ) + 1
end

@inline function _program_uniform(
        ::Type{T}, runtime, stream::RNGStream,
        operation, entity; subround = 0, draw = 0
    ) where {T}
    address = _program_address(stream, runtime.mcs + 1, operation, entity; subround, draw)
    return uniform_open01(
        T, Philox4x64x10V3(),
        _trajectory_key(runtime.seed, runtime.replica, runtime.repeat), address
    )
end
