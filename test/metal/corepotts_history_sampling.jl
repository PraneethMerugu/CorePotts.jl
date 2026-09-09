using Test
import CorePotts
import Metal

include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
include(joinpath(@__DIR__, "..", "fixtures", "history_sample_support.jl"))

@testset "initial capture and lag feedback on Metal" begin
    Metal.functional() || error("history sampling requires functional Metal")
    Metal.allowscalar(false)
    engines = (CorePotts.CheckerboardProgramEngine(),)
    backend = CorePotts.AdaptedProgramBackend{:MetalBackend}()
    adapt_runtime(runtime) = CorePotts.adapt_program_runtime(Metal.MtlArray, runtime)
    test_initial_history_capture(engines; backend, adapt_runtime)
    test_history_initialization_failure(; backend, adapt_runtime)
    test_history_feedback(engines; backend, adapt_runtime)
end
