"""
Stable 128-bit owner namespace for declared random operations.

The two UInt64 words follow textual UUID order: the first sixteen hexadecimal
digits form the first word. Component instances and process identities belong
in the operation's canonical identity, not in an execution-order counter.
"""
struct RNGNamespace
    words::NTuple{2, UInt64}
end

"""
Concrete 128-bit key derived by `rng_operation_keys` for one random operation.

`RNGOperationKey()` denotes absence in a descriptor whose policy does not draw.
The absent key is never a valid executable RNG address.
"""
struct RNGOperationKey
    words::NTuple{2, UInt64}
end
RNGOperationKey() = RNGOperationKey((UInt64(0), UInt64(0)))

@inline Base.iszero(key::RNGOperationKey) =
    iszero(key.words[1]) && iszero(key.words[2])

function _append_rng_word!(bytes, word::UInt64)
    for shift in 56:-8:0
        push!(bytes, (word >> shift) % UInt8)
    end
    return bytes
end

function _derive_rng_operation_key(namespace::RNGNamespace, identity::AbstractString)
    isempty(identity) && throw(ArgumentError("a random operation identity cannot be empty"))
    # Fixed domain tag, two big-endian namespace words, then a big-endian byte
    # count and UTF-8 identity bytes. Host hashing never enters device evaluation.
    bytes = collect(codeunits("CorePotts/RNGOperationKey/3\0"))
    for word in namespace.words
        _append_rng_word!(bytes, word)
    end
    identity_bytes = codeunits(String(identity))
    _append_rng_word!(bytes, UInt64(length(identity_bytes)))
    append!(bytes, identity_bytes)
    digest = SHA.sha256(bytes)
    words = ntuple(2) do word
        value = UInt64(0)
        for byte in 1:8
            value = (value << 8) | UInt64(digest[(word - 1) * 8 + byte])
        end
        value
    end
    key = RNGOperationKey(words)
    iszero(key) && throw(ArgumentError("random operation identity derives the reserved absent key"))
    return key
end

function _rng_operation_keys(declarations, reserved)
    identities = Set{Tuple{RNGNamespace, String}}()
    owners = Dict{RNGOperationKey, Tuple{RNGNamespace, String}}()
    for declaration in reserved
        identity = (declaration.namespace, String(declaration.identity))
        key = _derive_rng_operation_key(identity...)
        push!(identities, identity)
        owners[key] = identity
    end
    return map(Tuple(declarations)) do declaration
        declaration.namespace isa RNGNamespace || throw(
            ArgumentError(
                "a random operation declaration requires an RNGNamespace"
            )
        )
        declaration.identity isa AbstractString || throw(
            ArgumentError(
                "a random operation declaration requires a canonical string identity"
            )
        )
        identity = (declaration.namespace, String(declaration.identity))
        identity in identities && throw(
            ArgumentError(
                "duplicate or reserved random operation identity $(repr(identity))"
            )
        )
        key = _derive_rng_operation_key(identity...)
        haskey(owners, key) && throw(
            ArgumentError(
                "random operation key collision between $(repr(owners[key])) and $(repr(identity))"
            )
        )
        push!(identities, identity)
        owners[key] = identity
        key
    end
end

const _CORE_RNG_NAMESPACE = RNGNamespace((0x047998c13edd4edf, 0xb561cee99549c5a6))
const _CORE_RNG_OPERATION_DECLARATIONS = (
    proposal_recipient = (namespace = _CORE_RNG_NAMESPACE, identity = "proposal-recipient"),
    proposal_direction = (namespace = _CORE_RNG_NAMESPACE, identity = "proposal-direction"),
    acceptance = (namespace = _CORE_RNG_NAMESPACE, identity = "acceptance"),
    checkerboard_priority = (namespace = _CORE_RNG_NAMESPACE, identity = "checkerboard-priority"),
    checkerboard_color_order = (namespace = _CORE_RNG_NAMESPACE, identity = "checkerboard-color-order"),
)
const _CORE_RNG_OPERATIONS = NamedTuple{keys(_CORE_RNG_OPERATION_DECLARATIONS)}(
    _rng_operation_keys(values(_CORE_RNG_OPERATION_DECLARATIONS), ())
)

"""
    rng_operation_keys(declarations) -> Tuple

Derive keys for a complete batch of `(namespace=RNGNamespace(...), identity=... )`
declarations. The identity is a compiler-owned canonical string describing the
qualified component instance, process/boundary and lexical draw label. Order
does not affect a key. Duplicate identities, collisions and the absent key are
rejected, including collisions with Core's reserved built-in operations.

The returned keys follow declaration order. No registry is retained. A compiler
must submit its complete declared operation set together and retain the resolved
mapping in its existing executable/provenance authority. Hashing alone is not
an injectivity claim; collision checking closes the accepted model domain.
"""
rng_operation_keys(declarations) =
    _rng_operation_keys(declarations, values(_CORE_RNG_OPERATION_DECLARATIONS))
