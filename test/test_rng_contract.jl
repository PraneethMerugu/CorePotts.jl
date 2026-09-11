include(joinpath(@__DIR__, "fixtures", "philox64_oracle.jl"))

@testset "qualified Philox arithmetic and semantic addresses" begin
    contract = CorePotts.Philox4x64x10V3()
    trajectory = CorePotts._trajectory_key(0x123456789abcdef0, UInt32(7), UInt32(11))
    namespace = CorePotts.RNGNamespace((0xe4c62a4c88894cc8, 0xad3a75efc86c53b9))
    operations = CorePotts.rng_operation_keys(
        (
            (namespace = namespace, identity = "cell/process/noise"),
            (namespace = namespace, identity = "cell/process/other-noise"),
        )
    )
    @testset "independent multiplication and upstream generator answers" begin
        for (a, b) in PhiloxReference.multiplication_inputs()
            @test CorePotts._multiply_high_low64(a, b) == PhiloxReference.multiply_oracle(a, b)
        end
        for (counter, key, expected) in PhiloxReference.KNOWN_ANSWERS
            @test CorePotts.philox4x64_10(counter, key) == expected
            @test PhiloxReference.philox_oracle(counter, key) == expected
        end
        counters, keys = PhiloxReference.generator_inputs()
        for i in eachindex(counters)
            @test CorePotts.philox4x64_10(counters[i], keys[i]) ==
                PhiloxReference.philox_oracle(counters[i], keys[i])
        end
    end
    @testset "all trajectory coordinates remain represented" begin
        @test trajectory == (0x123456789abcdef0, 0x0000000b00000007)
        for seed in (UInt64(0), typemax(UInt64)), replica in (UInt32(0), typemax(UInt32)),
                repeat in (UInt32(0), typemax(UInt32))
            key = CorePotts._trajectory_key(seed, replica, repeat)
            @test key[1] == seed
            @test key[2] % UInt32 == replica
            @test (key[2] >> 32) % UInt32 == repeat
        end
    end
    base = (
        stream = CorePotts.ScheduledProcessDrawStream, operation = operations[1],
        mcs = 9, subround = 3, entity_kind = CorePotts.CellEntity, entity = 7,
        generation = 13, invocation = 2, draw = 5, retry = 1,
    )
    address = CorePotts.RNGAddress(; base...)
    expected_counter = (
        0x0003000000000009, 0x0000000500000007,
        0x000000000000000d, 0x030e000100000002,
    )
    @test CorePotts._rng_counter(address) == expected_counter
    expected_key = (
        trajectory[1] ⊻ operations[1].words[1],
        trajectory[2] ⊻ operations[1].words[2],
    )
    @test CorePotts._rng_key(trajectory, operations[1]) == expected_key
    @test CorePotts._rng_words(contract, trajectory, address) ==
        PhiloxReference.philox_oracle(expected_counter, expected_key)
    @testset "counter coordinates and operation keys do not alias" begin
        encoded = Set()
        for operation in operations, stream in instances(CorePotts.RNGStream),
                kind in (CorePotts.SiteEntity, CorePotts.CellEntity, CorePotts.DestinationEntity),
                mcs in 0:1, subround in 0:1, entity in 1:2, generation in 0:1,
                invocation in 0:1, draw in 0:1, retry in 0:1
            item = CorePotts.RNGAddress(;
                operation, stream, entity_kind = kind,
                mcs, subround, entity, generation, invocation, draw, retry
            )
            push!(encoded, (CorePotts._rng_key(trajectory, operation), CorePotts._rng_counter(item)))
        end
        @test length(encoded) == 2 * length(instances(CorePotts.RNGStream)) * 3 * 2^7
        maximum = CorePotts.RNGAddress(;
            stream = CorePotts.ScheduledProcessDrawStream,
            operation = operations[1], entity_kind = CorePotts.CellEntity,
            mcs = CorePotts._RNG_MAX_MCS, subround = typemax(UInt16),
            entity = typemax(UInt32), generation = typemax(UInt64),
            invocation = typemax(UInt32), draw = typemax(UInt32), retry = typemax(UInt16)
        )
        @test CorePotts._rng_counter(maximum) ==
            (typemax(UInt64), typemax(UInt64), typemax(UInt64), 0x030effffffffffff)
    end
    @testset "checked bounds and absent operations" begin
        @test_throws ArgumentError CorePotts.RNGAddress(; merge(base, (operation = CorePotts.RNGOperationKey(),))...)
        for invalid in (
                (mcs = -1,), (mcs = CorePotts._RNG_MAX_MCS + 1,),
                (subround = 65536,), (entity = UInt64(typemax(UInt32)) + 1,),
                (generation = UInt128(typemax(UInt64)) + 1,),
                (invocation = UInt64(typemax(UInt32)) + 1,),
                (draw = UInt64(typemax(UInt32)) + 1,), (retry = 65536,),
                (entity_kind = CorePotts.ModelEntity,),
            )
            @test_throws ArgumentError CorePotts.RNGAddress(; merge(base, invalid)...)
        end
    end
    @testset "open endpoints and independent rejection retries" begin
        minimum_words = ntuple(_ -> UInt64(0), 4)
        maximum_words = ntuple(_ -> typemax(UInt64), 4)
        for T in (Float32, Float64)
            @test zero(T) < CorePotts._uniform_open01_from_words(T, minimum_words) < one(T)
            @test zero(T) < CorePotts._uniform_open01_from_words(T, maximum_words) < one(T)
        end
        @test CorePotts.bounded_uint(contract, trajectory, address, UInt32(1)) == UInt32(0)
        @test_throws ArgumentError CorePotts.bounded_uint(contract, trajectory, address, UInt32(0))
        bound = UInt32(0x80000001)
        threshold = mod(-bound, bound)
        # Find an ordinary deterministic address with at least one rejected candidate.
        rejecting = first(
            filter(0:100) do draw
                item = CorePotts.RNGAddress(; merge(base, (draw = draw, retry = 0))...)
                (CorePotts._rng_word(contract, trajectory, item) >> 32) < threshold
            end
        )
        item = CorePotts.RNGAddress(; merge(base, (draw = rejecting, retry = 0))...)
        retry = UInt16(0)
        expected = UInt32(0)
        while true
            candidate = CorePotts.RNGAddress(; merge(base, (draw = rejecting, retry = retry))...)
            words = PhiloxReference.philox_oracle(CorePotts._rng_counter(candidate), expected_key)
            word = (words[1] >> 32) % UInt32
            if word >= threshold
                expected = mod(word, bound)
                break
            end
            retry += UInt16(1)
        end
        @test retry > 0
        @test CorePotts.bounded_uint(contract, trajectory, item, bound) == expected
        @test CorePotts._with_retry(item, retry).invocation == item.invocation
        last_rejection = first(
            filter(0:100) do draw
                candidate = CorePotts.RNGAddress(; merge(base, (draw = draw, retry = typemax(UInt16)))...)
                (CorePotts._rng_word(contract, trajectory, candidate) >> 32) < threshold
            end
        )
        exhausted = CorePotts.RNGAddress(; merge(base, (draw = last_rejection, retry = typemax(UInt16)))...)
        @test_throws ArgumentError CorePotts.bounded_uint(contract, trajectory, exhausted, bound)
    end
end
