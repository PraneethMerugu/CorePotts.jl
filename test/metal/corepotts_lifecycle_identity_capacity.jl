using Test
import CorePotts
import Metal

isdefined(@__MODULE__, :test_program) || include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
isdefined(@__MODULE__, :CellStageIncrement) || include(joinpath(@__DIR__, "..", "fixtures", "cell_stage_support.jl"))
isdefined(@__MODULE__, :cell_stage_lifecycle_runtime) || include(joinpath(@__DIR__, "..", "fixtures", "cell_stage_lifecycle_support.jl"))

@testset "lifecycle identity capacity on Metal" begin
    Metal.functional() || error("lifecycle identity capacity requires functional Metal")
    Metal.allowscalar(false)
    test_lifecycle_identity_capacity(CorePotts.CheckerboardProgramEngine(); adapt_to = Metal.MtlArray)
end
