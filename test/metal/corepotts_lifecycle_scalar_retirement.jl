using Test
import CorePotts
import Metal

isdefined(@__MODULE__, :test_program) || include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
include(joinpath(@__DIR__, "..", "fixtures", "lifecycle_scalar_retirement_support.jl"))

@testset "full scalar lifecycle retirement on Metal" begin
    Metal.functional() || error("scalar lifecycle retirement requires functional Metal")
    Metal.allowscalar(false)
    test_lifecycle_scalar_retirement(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
end
