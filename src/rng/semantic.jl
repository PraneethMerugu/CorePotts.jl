"""Philox4x64-10 with the version-three qualified semantic address contract."""
struct Philox4x64x10V3 end

@enum RNGStream::UInt8 begin
    ProposalRecipientStream = 3
    ProposalDirectionStream = 4
    AcceptanceStream = 5
    ExplicitProposalDrawStream = 6
    InitializationStream = 7
    CheckerboardPriorityStream = 8
    LifecycleTriggerStream = 9
    LifecyclePlacementStream = 10
    LifecyclePartitionStream = 11
    LifecycleStateStream = 12
    CheckerboardColorOrderStream = 13
    ScheduledProcessDrawStream = 14
end

@enum RNGEntityKind::UInt8 begin
    GlobalEntity = 0
    SiteEntity = 1
    ModelEntity = 2
    CellEntity = 3
    DestinationEntity = 4
end

const _RNG_MAX_MCS = UInt64(0x0000ffffffffffff)
const _RNG_MAX_DRAW = typemax(UInt32)
const _PHILOX_M4X64_0 = UInt64(0xd2e7470ee14c6c93)
const _PHILOX_M4X64_1 = UInt64(0xca5a826395121157)
const _PHILOX_W64_0 = UInt64(0x9e3779b97f4a7c15)
const _PHILOX_W64_1 = UInt64(0xbb67ae8584caa73b)

@inline _rng_draw_family(family::Integer) = Int(family)
@inline _rng_draw_family(::Val{Family}) where {Family} = Family

"""
One checked semantic address. Invocation identifies a scientific occurrence or
substep; retry identifies rejection attempts within that occurrence's sampler.
Generation is independently encoded, never mixed into an operation key.
"""
struct RNGAddress
    stream::RNGStream
    mcs::UInt64
    subround::UInt16
    operation::RNGOperationKey
    entity_kind::RNGEntityKind
    entity::UInt32
    generation::UInt64
    invocation::UInt32
    draw::UInt32
    retry::UInt16

    function RNGAddress(
            stream::RNGStream, mcs::UInt64, subround::UInt16,
            operation::RNGOperationKey, entity_kind::RNGEntityKind,
            entity::UInt32, generation::UInt64, invocation::UInt32,
            draw::UInt32, retry::UInt16, ::Val{:unchecked}
        )
        return new(
            stream, mcs, subround, operation, entity_kind, entity,
            generation, invocation, draw, retry
        )
    end
end

function RNGAddress(;
        stream::RNGStream, operation::RNGOperationKey,
        mcs::Integer = 0, subround::Integer = 0,
        entity_kind::RNGEntityKind = GlobalEntity, entity::Integer = 0,
        generation::Integer = 0, invocation::Integer = 0,
        draw::Integer = 0, retry::Integer = 0
    )
    iszero(operation) && throw(ArgumentError("an RNG address requires a present operation key"))
    all(>=(0), (mcs, subround, entity, generation, invocation, draw, retry)) ||
        throw(ArgumentError("RNG address coordinates must be nonnegative"))
    mcs <= _RNG_MAX_MCS && subround <= typemax(UInt16) &&
        entity <= typemax(UInt32) && generation <= typemax(UInt64) &&
        invocation <= typemax(UInt32) && draw <= typemax(UInt32) &&
        retry <= typemax(UInt16) || throw(
        ArgumentError(
            "RNG address coordinate exceeds its version-three domain"
        )
    )
    entity_kind in (SiteEntity, CellEntity, DestinationEntity) ||
        generation == 0 || throw(
        ArgumentError(
            "only site, cell, or destination addresses may carry a generation"
        )
    )
    return _rng_address_unchecked(
        stream, UInt64(mcs), UInt16(subround), operation,
        entity_kind, UInt32(entity), UInt64(generation), UInt32(invocation),
        UInt32(draw), UInt16(retry)
    )
end

@inline _rng_address_unchecked(
    stream, mcs, subround, operation, entity_kind,
    entity, generation, invocation, draw, retry
) = RNGAddress(
    stream, mcs,
    subround, operation, entity_kind, entity, generation, invocation, draw,
    retry, Val(:unchecked)
)

# Random123's Philox4x64 constants and round permutation are used under the
# notice in LICENSE-Random123. Explicit limbs avoid device UInt128 arithmetic.
@inline function _multiply_high_low64(a::UInt64, b::UInt64)
    mask = UInt64(0xffffffff)
    a0, a1 = a & mask, a >> 32
    b0, b1 = b & mask, b >> 32
    p00, p01 = a0 * b0, a0 * b1
    p10, p11 = a1 * b0, a1 * b1
    middle = (p00 >> 32) + (p01 & mask) + (p10 & mask)
    low = (p00 & mask) | (middle << 32)
    high = p11 + (p01 >> 32) + (p10 >> 32) + (middle >> 32)
    return low, high
end

@inline function philox4x64_10(counter::NTuple{4, UInt64}, key::NTuple{2, UInt64})
    value, round_key = counter, key
    for _ in 1:10
        low0, high0 = _multiply_high_low64(_PHILOX_M4X64_0, value[1])
        low1, high1 = _multiply_high_low64(_PHILOX_M4X64_1, value[3])
        value = (
            high1 ⊻ value[2] ⊻ round_key[1], low1,
            high0 ⊻ value[4] ⊻ round_key[2], low0,
        )
        round_key = (round_key[1] + _PHILOX_W64_0, round_key[2] + _PHILOX_W64_1)
    end
    return value
end

@inline function _rng_counter(address::RNGAddress)
    return (
        address.mcs | (UInt64(address.subround) << 48),
        UInt64(address.entity) | (UInt64(address.draw) << 32),
        address.generation,
        UInt64(address.invocation) | (UInt64(address.retry) << 32) |
            (UInt64(address.stream) << 48) | (UInt64(address.entity_kind) << 56),
    )
end

@inline function _rng_key(trajectory::NTuple{2, UInt64}, operation::RNGOperationKey)
    return (trajectory[1] ⊻ operation.words[1], trajectory[2] ⊻ operation.words[2])
end

@inline function _rng_words(::Philox4x64x10V3, trajectory::NTuple{2, UInt64}, address::RNGAddress)
    return philox4x64_10(_rng_counter(address), _rng_key(trajectory, address.operation))
end

@inline function _rng_word(
        contract::Philox4x64x10V3, trajectory::NTuple{2, UInt64},
        address::RNGAddress, lane::Integer = 1
    )
    1 <= lane <= 4 || throw(ArgumentError("Philox output lane must lie in 1:4"))
    return _rng_words(contract, trajectory, address)[lane]
end

@inline function uniform_open01(
        ::Type{T}, contract::Philox4x64x10V3,
        trajectory::NTuple{2, UInt64}, address::RNGAddress
    ) where {T <: AbstractFloat}
    return _uniform_open01_from_words(T, _rng_words(contract, trajectory, address))
end

@inline function _uniform_open01_from_words(::Type{Float32}, words::NTuple{4, UInt64})
    bits = words[1] >> 41
    return Float32(bits) * Float32(0x1.0p-23) + Float32(0x1.0p-24)
end

@inline function _uniform_open01_from_words(::Type{Float64}, words::NTuple{4, UInt64})
    bits = words[1] >> 12
    return Float64(bits) * 0x1.0p-52 + 0x1.0p-53
end

@inline function _with_retry(address::RNGAddress, retry::UInt16)
    return _rng_address_unchecked(
        address.stream, address.mcs, address.subround,
        address.operation, address.entity_kind, address.entity, address.generation,
        address.invocation, address.draw, retry
    )
end

function bounded_uint(
        contract::Philox4x64x10V3, trajectory::NTuple{2, UInt64},
        address::RNGAddress, bound::UInt32
    )
    bound > 0 || throw(ArgumentError("bounded sampling requires a positive bound"))
    threshold = mod(-bound, bound)
    retry = address.retry
    while true
        word = (_rng_word(contract, trajectory, _with_retry(address, retry)) >> 32) % UInt32
        word >= threshold && return mod(word, bound)
        retry == typemax(UInt16) && throw(
            ArgumentError(
                "bounded rejection exhausted the semantic RNG retry domain"
            )
        )
        retry += UInt16(1)
    end
    return
end
