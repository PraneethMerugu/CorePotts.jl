isdefined(@__MODULE__, :heterogeneous_lifecycle_runtime) || include("lifecycle_value_support.jl")

function test_lifecycle_scalar_retirement(engine; adapt_to = identity)
    @testset "scalar retirement publishes the declared value" begin
        test_lifecycle_value_conversion(
            engine; adapt_to, values = (2.0f0,), invalid = false,
            initial_values = (1.0f0,), expected_values = (2.0f0,),
            rule_indices = (1,),
        )
    end
    @testset "rejected scalar retirement preserves the transaction" begin
        test_lifecycle_value_conversion(
            engine; adapt_to, values = (2.5f0,), invalid = true,
            initial_values = (Int32(1),), expected_values = (Int32(1),),
            rule_indices = (1,),
        )
    end
    return
end
