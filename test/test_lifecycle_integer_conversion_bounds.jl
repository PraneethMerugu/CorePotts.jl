include("fixtures/lifecycle_integer_bounds_support.jl")

@testset "lifecycle conversion guard agrees with ordinary conversion" begin
    for (source_type, target_types) in ((Float32, (Int8, Int32, UInt32, Bool)), (Float64, (Int64, UInt64, Bool)))
        for target_type in target_types
            values = lifecycle_conversion_inputs(target_type, source_type)
            @test map(value -> CorePotts._lifecycle_value_convertible(target_type, value), values) ==
                lifecycle_conversion_oracle(target_type, values)
        end
    end
end

@testset "lifecycle integer conversion bounds preserve exact endpoints" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            test_lifecycle_integer_bounds(engine; target_types = (Int32, UInt32))
            # These storage banks are not admitted by the checkerboard backend;
            # their conversion boundaries remain covered by the host executor.
            if engine isa CorePotts.SequentialProgramEngine
                test_lifecycle_integer_bounds(engine; target_types = (Int8,))
                test_lifecycle_integer_bounds(engine; source_type = Float64, target_types = (Int64,))
            end
        end
    end
end
