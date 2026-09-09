isdefined(@__MODULE__, :test_lifecycle_value_conversion) || include("lifecycle_value_support.jl")

function test_lifecycle_product_conversions(engine; adapt_to = identity)
    for named in (false, true)
        product = named ?
            ((count, enabled, offsets) -> (; count, flags = (; enabled, offsets))) :
            ((count, enabled, offsets) -> (count, (enabled, offsets)))
        initial = product(Int32(1), false, StaticArrays.SVector(Int32(1), Int32(2)))
        expected = product(Int32(2), true, StaticArrays.SVector(Int32(3), Int32(4)))
        cases = (
            ("matched leaves", expected, false),
            ("exact numeric leaves", product(2.0f0, 1.0f0, StaticArrays.SVector(3.0f0, 4.0f0)), false),
            ("fractional count", product(2.5f0, 1.0f0, StaticArrays.SVector(3.0f0, 4.0f0)), true),
            ("Boolean range", product(2.0f0, 2.0f0, StaticArrays.SVector(3.0f0, 4.0f0)), true),
            ("Boolean subnormal", product(2.0f0, nextfloat(0.0f0), StaticArrays.SVector(3.0f0, 4.0f0)), true),
            ("nonfinite count", product(Inf32, 1.0f0, StaticArrays.SVector(3.0f0, 4.0f0)), true),
            ("vector integer range", product(2.0f0, 1.0f0, StaticArrays.SVector(3.0f0, Float32(2^31))), true),
            ("vector integer subnormal", product(2.0f0, 1.0f0, StaticArrays.SVector(3.0f0, prevfloat(0.0f0))), true),
        )
        if named
            positional = Tuple(product(2.0f0, 1.0f0, StaticArrays.SVector(3.0f0, 4.0f0)))
            cases = (cases..., ("positional initialization", positional, false))
        end
        @testset "$(named ? "named" : "positional") nested product" begin
            for (name, value, invalid) in cases
                @testset "$name" begin
                    test_lifecycle_value_conversion(
                        engine; adapt_to, invalid, initial_values = (1.0f0, initial),
                        values = (2.0f0, value), expected_values = (2.0f0, expected),
                    )
                end
            end
        end
    end
    return
end
