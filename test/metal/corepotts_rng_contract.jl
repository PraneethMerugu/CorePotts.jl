using Test
import CorePotts, Metal, KernelAbstractions
using KernelAbstractions: @kernel, @index
include(joinpath(@__DIR__, "..", "fixtures", "philox64_oracle.jl"))

@kernel function philox_product_words!(outputs, pairs)
    i = @index(Global, Linear)
    @inbounds outputs[i] = CorePotts._multiply_high_low64(pairs[i]...)
end

@kernel function philox_generator_words!(outputs, counters, keys)
    i = @index(Global, Linear)
    @inbounds outputs[i] = CorePotts.philox4x64_10(counters[i], keys[i])
end

@kernel function philox_address_words!(outputs, addresses, trajectory)
    i = @index(Global, Linear)
    @inbounds outputs[i] = CorePotts._rng_words(CorePotts.Philox4x64x10V3(), trajectory, addresses[i])
end

@testset "qualified RNG arithmetic and addresses on Metal" begin
    Metal.functional() || error("qualified RNG tests require functional Metal")
    Metal.allowscalar(false)
    pairs = PhiloxReference.multiplication_inputs()
    counters, keys = PhiloxReference.generator_inputs()
    device_pairs = Metal.MtlArray(pairs)
    device_counters, device_keys = Metal.MtlArray(counters), Metal.MtlArray(keys)
    products = Metal.MtlArray{NTuple{2, UInt64}}(undef, length(pairs))
    words = Metal.MtlArray{NTuple{4, UInt64}}(undef, length(counters))
    backend = KernelAbstractions.get_backend(words)
    expected_products = [PhiloxReference.multiply_oracle(pair...) for pair in pairs]
    expected_words = [PhiloxReference.philox_oracle(counters[i], keys[i]) for i in eachindex(counters)]
    namespace = CorePotts.RNGNamespace((0xe4c62a4c88894cc8, 0xad3a75efc86c53b9))
    operations = CorePotts.rng_operation_keys(
        (
            (namespace = namespace, identity = "cell/scheduled/noise"),
            (namespace = namespace, identity = "cell/scheduled/other-noise"),
        )
    )
    trajectory = CorePotts._trajectory_key(0x123456789abcdef0, UInt32(7), UInt32(11))
    addresses = [
        CorePotts.RNGAddress(
                stream = CorePotts.ScheduledProcessDrawStream,
                operation = operation, mcs = mcs, subround = 3, entity_kind = CorePotts.CellEntity,
                entity = entity, generation = generation, invocation = invocation, draw = 5, retry = 1
            )
            for operation in operations for mcs in (0, 7) for entity in (1, 19)
            for generation in (UInt64(1), typemax(UInt64)) for invocation in (UInt32(0), typemax(UInt32))
    ]
    device_addresses = Metal.MtlArray(addresses)
    addressed = Metal.MtlArray{NTuple{4, UInt64}}(undef, length(addresses))
    expected_addressed = map(addresses) do address
        # Independent word assembly, not a second call to Core's packing helper.
        counter = (
            UInt64(address.mcs) + (UInt64(address.subround) << 48),
            UInt64(address.entity) + (UInt64(address.draw) << 32), address.generation,
            UInt64(address.invocation) + (UInt64(address.retry) << 32) +
                (UInt64(address.stream) << 48) + (UInt64(address.entity_kind) << 56),
        )
        key = (trajectory[1] ⊻ address.operation.words[1], trajectory[2] ⊻ address.operation.words[2])
        PhiloxReference.philox_oracle(counter, key)
    end
    for workgroup_size in (64, 128, 256)
        philox_product_words!(backend, workgroup_size)(products, device_pairs; ndrange = length(pairs))
        philox_generator_words!(backend, workgroup_size)(
            words, device_counters, device_keys;
            ndrange = length(counters)
        )
        philox_address_words!(backend, workgroup_size)(
            addressed, device_addresses, trajectory;
            ndrange = length(addresses)
        )
        KernelAbstractions.synchronize(backend)
        @test Array(products) == expected_products
        actual = Array(words)
        @test actual == expected_words
        @test Array(addressed) == expected_addressed
        for i in eachindex(PhiloxReference.KNOWN_ANSWERS)
            @test actual[i] == PhiloxReference.KNOWN_ANSWERS[i][3]
        end
    end
end
