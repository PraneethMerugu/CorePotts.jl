include("fixtures/lifecycle_value_support.jl")

@testset "heterogeneous lifecycle values convert or roll back" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            test_heterogeneous_lifecycle_values(engine)
            test_different_length_lifecycle_values(engine)
        end
    end
end
