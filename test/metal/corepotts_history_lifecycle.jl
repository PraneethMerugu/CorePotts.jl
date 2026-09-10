using Test
import CorePotts
import Metal

include(joinpath(@__DIR__, "..", "fixtures", "history_lifecycle_support.jl"))

@testset "retained history lifecycle transactions on Metal" begin
    Metal.functional() || error("history lifecycle requires functional Metal")
    Metal.allowscalar(false)
    adapt_runtime(runtime) = CorePotts.adapt_program_runtime(Metal.MtlArray, runtime)
    test_history_lifecycle_transactions(
        (CorePotts.CheckerboardProgramEngine(),); adapt_runtime, check_checkpoint = false
    )
end
