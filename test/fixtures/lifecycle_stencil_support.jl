isdefined(@__MODULE__, :receipt_descriptor) || include("lifecycle_descriptor_support.jl")

function test_seed_stencil_lifecycle(engine; adapt_to = identity)
    descriptor = receipt_descriptor(
        1, CorePotts.CreateCellLifecycleEffect;
        destination_kind = 3,
        placement = CorePotts.SeedStencilLifecyclePlacement,
        placement_evaluator = 2,
        placement_maximum = 2,
        stencil_count = 2,
        scalar_type = Float32,
    )
    evaluators = CorePotts.LifecycleEvaluatorStorage(
        Any[
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(8)),
        ],
        Symbol[:lifecycle_trigger, :lifecycle_placement],
    )
    lifecycle = CorePotts.LifecycleExecutionPlan(
        [descriptor], evaluators,
        CorePotts.LifecycleStateRuleStorage(Any[]),
        CorePotts.LifecycleRelationshipRule[], (),
        NTuple{2, Int16}[(0, 0), (1, 0)],
        CorePotts.LifecycleRelationStorage((), Val(2)),
        CorePotts.StablePriorityLifecycleConflicts,
        2, 1, 2, 0, falses(3),
    )
    program = test_program(
        engine; lifecycle_plan = lifecycle, scalar_type = Float32,
    )
    host = CorePotts.initialize_program(
        program, test_initial(Float32), Float32[], UInt64(0x8c4), UInt32(1),
    )
    runtime = adapt_to === identity ? host :
        CorePotts.adapt_program_runtime(adapt_to, host)
    CorePotts.advance_mcs!(runtime)
    snapshot = CorePotts.program_snapshot(runtime)
    @test !CorePotts.program_failed(runtime)
    @test snapshot.mcs == 1
    @test snapshot.cell_kinds[2] == 3
    @test snapshot.ownership[2, 2] == 2
    @test snapshot.ownership[3, 2] == 2
    return snapshot
end
