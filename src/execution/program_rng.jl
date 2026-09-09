# Semantic RNG addressing owned by the compiled program runtime.

"""Pack the complete seed/replica/repeat tuple without truncation."""
@inline _trajectory_key(seed::UInt64, replica::UInt32, repeat::UInt32) =
    (seed, UInt64(replica) | (UInt64(repeat) << 32))

const _SCHEDULED_BEFORE_LIFECYCLE = UInt16(0)
const _SCHEDULED_AFTER_LIFECYCLE = UInt16(1)

"""Immutable scientific invocation facts shared by scheduled evaluator contexts."""
struct _ScheduledRNGContext{T}
    trajectory_key::NTuple{2, UInt64}
    mcs::Int64
    boundary::UInt16
    entity_kind::RNGEntityKind
    entity::UInt32
    generation::UInt64
    invocation::UInt32
end

@inline function _scheduled_rng_context(
        ::Type{T}, trajectory_key, mcs, boundary, entity_kind, entity,
        generation, invocation
    ) where {T}
    return _ScheduledRNGContext{T}(
        trajectory_key, Int64(mcs), boundary, entity_kind, UInt32(entity),
        UInt64(generation), UInt32(invocation)
    )
end

@inline function _scheduled_rng_context(
        runtime, boundary::UInt16, entity_kind::RNGEntityKind,
        entity::Integer, generation::Integer, invocation::Integer
    )
    return _scheduled_rng_context(
        eltype(runtime.parameters),
        _trajectory_key(runtime.seed, runtime.replica, runtime.repeat),
        Int64(runtime.mcs + 1), boundary, entity_kind, UInt32(entity),
        UInt64(generation), UInt32(invocation)
    )
end

@inline function _scheduled_draw(arguments, context::_ScheduledRNGContext{T}) where {T}
    address = RNGAddress(
        stream = ScheduledProcessDrawStream, operation = arguments[4],
        mcs = context.mcs, subround = context.boundary,
        entity_kind = context.entity_kind, entity = context.entity,
        generation = context.generation, invocation = context.invocation,
    )
    return _addressed_draw(T, arguments, context.trajectory_key, address)
end

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
