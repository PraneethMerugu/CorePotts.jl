using Test
import CorePotts
import Metal

isdefined(@__MODULE__, :test_program) || include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
include(joinpath(@__DIR__, "..", "fixtures", "lifecycle_product_conversion_support.jl"))

@testset "nested lifecycle product conversion on Metal" begin
    Metal.functional() || error("lifecycle product conversion requires functional Metal")
    Metal.allowscalar(false)
    test_lifecycle_product_conversions(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
end
