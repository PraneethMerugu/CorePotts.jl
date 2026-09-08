# Independent host arithmetic oracle and upstream Philox4x64 known answers.
# Constants, round permutation and known-answer vectors: D. E. Shaw Research,
# Random123/include/Random123/philox.h and tests/kat_vectors (accessed 2026-09-08).
# https://github.com/DEShawResearch/random123/blob/main/include/Random123/philox.h
# https://github.com/DEShawResearch/random123/blob/main/tests/kat_vectors
# See LICENSE-Random123 for the upstream redistribution notice.

module PhiloxReference

const MULTIPLIERS = (0xd2e7470ee14c6c93, 0xca5a826395121157)
const INCREMENTS = (0x9e3779b97f4a7c15, 0xbb67ae8584caa73b)

# Independent host arithmetic uses Julia's full product rather than limb carries.
function multiply_oracle(a::UInt64, b::UInt64)
    product = UInt128(a) * UInt128(b)
    return product % UInt64, (product >> 64) % UInt64
end

function philox_oracle(counter::NTuple{4, UInt64}, key::NTuple{2, UInt64})
    value, round_key = counter, key
    for round in 1:10
        product0 = UInt128(MULTIPLIERS[1]) * UInt128(value[1])
        product1 = UInt128(MULTIPLIERS[2]) * UInt128(value[3])
        value = (
            ((product1 >> 64) % UInt64) ⊻ value[2] ⊻ round_key[1],
            product1 % UInt64,
            ((product0 >> 64) % UInt64) ⊻ value[4] ⊻ round_key[2],
            product0 % UInt64,
        )
        round_key = (round_key[1] + INCREMENTS[1], round_key[2] + INCREMENTS[2])
    end
    return value
end

const KNOWN_ANSWERS = (
    (
        (0x0000000000000000, 0x0000000000000000, 0x0000000000000000, 0x0000000000000000),
        (0x0000000000000000, 0x0000000000000000),
        (0x16554d9eca36314c, 0xdb20fe9d672d0fdc, 0xd7e772cee186176b, 0x7e68b68aec7ba23b),
    ),
    (
        (0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff, 0xffffffffffffffff),
        (0xffffffffffffffff, 0xffffffffffffffff),
        (0x87b092c3013fe90b, 0x438c3c67be8d0224, 0x9cc7d7c69cd777b6, 0xa09caebf594f0ba0),
    ),
    (
        (0x243f6a8885a308d3, 0x13198a2e03707344, 0xa4093822299f31d0, 0x082efa98ec4e6c89),
        (0x452821e638d01377, 0xbe5466cf34e90c6c),
        (0xa528f45403e61d95, 0x38c72dbd566e9788, 0xa5a1610e72fd18b5, 0x57bd43b5e52b7fe6),
    ),
)

# Deterministic test inputs, not a proposed random-stream derivation.
input_word(i::Integer) = (UInt64(i) * 0x9e3779b97f4a7c15) ⊻
    ((UInt64(i) * 0xd2e7470ee14c6c93) >> 17)

function multiplication_inputs()
    edges = UInt64[
        0, 1, 2, 0xffffffff, 0x0000000100000000, 0x0000000100000001,
        0x7fffffffffffffff, 0x8000000000000000, 0xffffffff00000000,
        0xfffffffffffffffe, 0xffffffffffffffff,
    ]
    pairs = [(a, b) for a in edges for b in edges]
    append!(pairs, [(input_word(i), input_word(i + 7919)) for i in 1:4096])
    return pairs
end

function generator_inputs()
    counters = [case[1] for case in KNOWN_ANSWERS]
    keys = [case[2] for case in KNOWN_ANSWERS]
    for i in 1:4096
        push!(counters, ntuple(j -> input_word(6i + j), 4))
        push!(keys, ntuple(j -> input_word(6i + 4 + j), 2))
    end
    return counters, keys
end

end
