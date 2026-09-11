using Test
import CorePotts
import Metal

isdefined(@__MODULE__, :test_program) || include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
include(joinpath(@__DIR__, "..", "fixtures", "lifecycle_value_support.jl"))

@testset "heterogeneous lifecycle value conversion on Metal" begin
    Metal.functional() || error("lifecycle conversion requires functional Metal")
    Metal.allowscalar(false)
    test_heterogeneous_lifecycle_values(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
    test_different_length_lifecycle_values(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
end
