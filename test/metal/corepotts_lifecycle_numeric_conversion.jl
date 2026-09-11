using Test
import CorePotts
import Metal

isdefined(@__MODULE__, :test_program) || include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
isdefined(@__MODULE__, :test_numeric_lifecycle_values) || include(joinpath(@__DIR__, "..", "fixtures", "lifecycle_value_support.jl"))

@testset "lifecycle numeric conversions on Metal" begin
    Metal.functional() || error("lifecycle numeric conversion requires functional Metal")
    Metal.allowscalar(false)
    test_numeric_lifecycle_values(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
    test_lifecycle_small_numeric_values(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
end
