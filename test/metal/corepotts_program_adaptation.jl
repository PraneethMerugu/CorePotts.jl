using Test
import CorePotts
import Metal
include(joinpath(@__DIR__, "..", "fixtures", "program_adaptation_support.jl"))

@testset "Metal adaptation retains independent trajectories" begin
    Metal.functional() || error("runtime adaptation requires functional Metal")
    Metal.allowscalar(false)
    _test_program_adaptation_independence(Metal.MtlArray)
    _test_lifecycle_adaptation_independence(Metal.MtlArray)
end
