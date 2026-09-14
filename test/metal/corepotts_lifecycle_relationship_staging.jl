using Test
import CorePotts
import Metal

include(joinpath(
    @__DIR__, "..", "fixtures", "compiled_program_support.jl",
))
include(joinpath(
    @__DIR__, "..", "fixtures", "lifecycle_relationship_staging_support.jl",
))

@testset "lifecycle relationship staging on Metal" begin
    Metal.functional() ||
        error("lifecycle relationship staging requires functional Metal")
    Metal.allowscalar(false)
    engine = CorePotts.CheckerboardProgramEngine()
    backend = CorePotts.AdaptedProgramBackend{:MetalBackend}()
    for action in (
            CorePotts.RemoveIncidentLifecycleRelationship,
            CorePotts.RemoveIncompatibleLifecycleRelationship,
        )
        test_lifecycle_relationship_staging(
            engine, action; adapt_to = Metal.MtlArray, backend,
        )
    end
end
