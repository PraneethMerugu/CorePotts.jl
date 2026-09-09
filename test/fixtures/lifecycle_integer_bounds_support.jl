isdefined(@__MODULE__, :test_lifecycle_value_conversion) || include("lifecycle_value_support.jl")

function lifecycle_conversion_inputs(target_type, source_type)
    lower = source_type(typemin(target_type))
    upper = source_type(big(typemax(target_type)) + 1)
    return source_type[
        lower, floor(prevfloat(upper)), prevfloat(lower), upper,
        0, -zero(source_type), nextfloat(zero(source_type)), prevfloat(zero(source_type)),
        0.5, 1, Inf, NaN,
    ]
end

function lifecycle_conversion_oracle(target_type, values)
    return map(values) do value
        try
            convert(target_type, value)
            true
        catch exception
            exception isa InexactError || rethrow()
            false
        end
    end
end

function test_lifecycle_integer_bounds(
        engine; adapt_to = identity, source_type = Float32,
        target_types = (Int8, Int32, UInt32),
    )
    for target_type in target_types
        # Construct the mathematical integer interval on the host, independently
        # of the conversion guard's machine-width/source-precision calculation.
        lower = source_type(typemin(target_type))
        upper = source_type(big(typemax(target_type)) + 1)
        last_integer = floor(prevfloat(upper))
        initial_values = (one(target_type), false)
        cases = (
            ("lower endpoint", lower, typemin(target_type), false),
            ("last source integer", last_integer, convert(target_type, last_integer), false),
            ("below lower endpoint", prevfloat(lower), zero(target_type), true),
            ("upper endpoint", upper, zero(target_type), true),
        )
        @testset "$source_type to $target_type" begin
            for (name, value, expected, invalid) in cases
                @testset "$name" begin
                    test_lifecycle_value_conversion(
                        engine; adapt_to, initial_values, invalid,
                        values = (value, one(source_type)),
                        expected_values = (expected, true),
                    )
                end
            end
        end
    end
    return
end
