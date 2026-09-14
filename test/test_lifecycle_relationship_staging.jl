using Test
import CorePotts

include("fixtures/lifecycle_relationship_staging_support.jl")

@testset "lifecycle relationship staging follows declared removal rules" begin
    for engine in (
            CorePotts.SequentialProgramEngine(),
            CorePotts.CheckerboardProgramEngine(),
        )
        for action in (
                CorePotts.RemoveIncidentLifecycleRelationship,
                CorePotts.RemoveIncompatibleLifecycleRelationship,
            )
            test_lifecycle_relationship_staging(engine, action)
        end
    end
end
