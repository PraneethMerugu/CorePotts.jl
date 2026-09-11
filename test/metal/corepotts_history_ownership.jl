using Test
import CorePotts
import Metal

include(joinpath(@__DIR__, "..", "fixtures", "history_ownership_support.jl"))

@testset "retained site ownership transactions on Metal" begin
    Metal.functional() || error("history ownership requires functional Metal")
    Metal.allowscalar(false)
    engines = (CorePotts.CheckerboardProgramEngine(),)
    adapt_runtime(runtime) = CorePotts.adapt_program_runtime(Metal.MtlArray, runtime)
    test_history_ownership_failure(engines; adapt_runtime)
    test_history_ownership_change(engines; adapt_runtime)
end
