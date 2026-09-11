using Test
import CorePotts
import Metal

isdefined(@__MODULE__, :test_site_minimum_removal) ||
    include(joinpath(@__DIR__, "..", "fixtures", "site_minimum_support.jl"))

@testset "bounded site minimum on Metal" begin
    Metal.functional() || error("bounded site minimum requires functional Metal")
    Metal.allowscalar(false)
    engine = CorePotts.CheckerboardProgramEngine()
    backend = CorePotts.AdaptedProgramBackend{:MetalBackend}()
    for test in (
            test_site_minimum_empty_value,
            test_site_minimum_removal, test_site_minimum_inputs,
            test_site_minimum_scheduled, test_site_minimum_accepted_sources,
            test_site_minimum_history,
        )
        test(engine; adapt_to = Metal.MtlArray, backend)
    end
end
