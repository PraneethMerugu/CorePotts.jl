@testset "qualified random operation keys" begin
    namespace = CorePotts.CompilerSPI.RNGNamespace((0xe4c62a4c88894cc8, 0xad3a75efc86c53b9))
    declarations = (
        (namespace = namespace, identity = "component-A/process-one/draw-a"),
        (namespace = namespace, identity = "component-B/process-one/draw-a"),
        (namespace = namespace, identity = "component-A/process-two/draw-a"),
        (namespace = namespace, identity = "component-A/process-one/draw-b"),
    )
    keys = CorePotts.CompilerSPI.rng_operation_keys(declarations)
    # SHA-256 of the specified domain tag, big-endian namespace and UTF-8
    # byte-length framing; independently checked with Python hashlib/struct.
    @test first(keys).words == (0x325ce44bd46c38d7, 0x4084d24c787ec198)
    @test length(unique(keys)) == length(keys)
    @test !any(iszero, keys)
    @test CorePotts.CompilerSPI.rng_operation_keys(reverse(declarations)) == reverse(keys)
    @test CorePotts.CompilerSPI.rng_operation_keys(declarations[1:2]) == keys[1:2]
    @test CorePotts.CompilerSPI.rng_operation_keys(()) === ()
    @test iszero(CorePotts.CompilerSPI.RNGOperationKey())
    @test_throws ArgumentError CorePotts.CompilerSPI.rng_operation_keys(
        (first(declarations), first(declarations))
    )
    @test_throws ArgumentError CorePotts.CompilerSPI.rng_operation_keys(
        ((namespace = namespace, identity = ""),)
    )
    @test_throws ArgumentError CorePotts.CompilerSPI.rng_operation_keys(
        (first(values(CorePotts._CORE_RNG_OPERATION_DECLARATIONS)),)
    )
    other = CorePotts.CompilerSPI.RNGNamespace((0xe4c62a4c88894cc8, 0xad3a75efc86c53b8))
    @test only(
        CorePotts.CompilerSPI.rng_operation_keys(
            ((namespace = other, identity = first(declarations).identity),)
        )
    ) != first(keys)
end
