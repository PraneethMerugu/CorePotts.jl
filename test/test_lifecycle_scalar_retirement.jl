using Test
import CorePotts

isdefined(@__MODULE__, :test_program) || include("fixtures/compiled_program_support.jl")
include("fixtures/lifecycle_scalar_retirement_support.jl")

@testset "full scalar lifecycle retirement" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            test_lifecycle_scalar_retirement(engine)
        end
    end
end
