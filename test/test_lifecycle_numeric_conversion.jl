isdefined(@__MODULE__, :test_numeric_lifecycle_values) || include("fixtures/lifecycle_value_support.jl")

@testset "lifecycle numeric conversions preserve values or roll back" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            test_numeric_lifecycle_values(engine)
            test_lifecycle_small_numeric_values(engine)
        end
    end
end
