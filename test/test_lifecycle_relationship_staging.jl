using Test
import CorePotts
import KernelAbstractions

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


@testset "relationship staging follows selected request order" begin
    test_lifecycle_relationship_request_order()
end

@testset "backend relationship staging reads the selected request sequence" begin
    test_lifecycle_relationship_selected_sequence()
end


@testset "relationship removal follows lifecycle stage order" begin
    for plan_class in (
            CorePotts._RemoveLifecyclePlan(),
            CorePotts._RetireLifecyclePlan(),
            CorePotts._TransitionLifecyclePlan(),
            CorePotts._DivideLifecyclePlan(),
        )
        test_lifecycle_relationship_stage_order(plan_class)
    end
end
