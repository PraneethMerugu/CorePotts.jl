using Test
import CorePotts
include("fixtures/lifecycle_descriptor_support.jl")

@testset "completed-MCS cadence separates initialization from lifecycle boundaries" begin
    C = CorePotts
    @test [C._completed_mcs_due(C.EveryMCSCadence, 1, mcs) for mcs in 0:4] == [false, true, true, true, true]
    @test [C._completed_mcs_due(C.PeriodicMCSCadence, 2, mcs) for mcs in 0:4] == [false, false, true, false, true]
    @test [C._completed_mcs_due(C.AtMCSCadence, 0, mcs) for mcs in 0:4] == [true, false, false, false, false]
    function plan(descriptor, requests)
        C.LifecycleExecutionPlan(
            [descriptor], C.LifecycleEvaluatorStorage([C.StaticEvaluator(C.LiteralExpression(true))], [:lifecycle_trigger]),
            C.LifecycleStateRuleStorage(Any[]), C.LifecycleRelationshipRule[], (), NTuple{2, Int16}[],
            C.LifecycleRelationStorage((), Val(2)), C.RejectLifecycleConflicts, 1, requests, 1, 0, falses(1),
        )
    end
    for (cadence, value) in ((C.AtMCSCadence, 0), (C.AtMCSCadence, -1), (C.PeriodicMCSCadence, 0), (C.PeriodicMCSCadence, -1))
        descriptor = receipt_descriptor(1, C.RemoveCellLifecycleEffect; domain_kind = 1, cadence, cadence_value = value)
        for requests in (0, 1)
            @test_throws r"completed-MCS cadence" plan(descriptor, requests)
        end
    end
    for (cadence, value) in ((C.EveryMCSCadence, 1), (C.AtMCSCadence, 1), (C.PeriodicMCSCadence, 2))
        descriptor = receipt_descriptor(1, C.RemoveCellLifecycleEffect; domain_kind = 1, cadence, cadence_value = value)
        @test plan(descriptor, 1) isa C.LifecycleExecutionPlan
    end
end
