isdefined(@__MODULE__, :receipt_descriptor) ||
    include("lifecycle_descriptor_support.jl")

function lifecycle_relationship_staging_runtime(
        engine,
        action;
        backend = CorePotts.CPUProgramBackend(),
    )
    C = CorePotts
    descriptor = receipt_descriptor(
        1,
        C.TransitionCellLifecycleEffect;
        domain_kind = 2,
        destination_kind = 4,
        relationship_rule_count = 1,
        scalar_type = Float32,
    )
    lifecycle_plan = C.LifecycleExecutionPlan(
        [descriptor],
        C.LifecycleEvaluatorStorage(
            Any[C.StaticEvaluator(C.LiteralExpression(true))],
            [:lifecycle_trigger],
        ),
        C.LifecycleStateRuleStorage(Any[]),
        C.LifecycleRelationshipRule[
            C.LifecycleRelationshipRule(Int32(1), action, Int16(4), Int16(3)),
        ],
        (),
        NTuple{2, Int16}[],
        C.LifecycleRelationStorage((), Val(2)),
        C.StablePriorityLifecycleConflicts,
        3,
        3,
        1,
        0,
        falses(5),
    )
    schema = C.RelationshipStoreSchema(2, 2)
    base = test_program(
        engine;
        lifecycle_plan,
        relationships = C.RelationshipStorage((schema,)),
        scalar_type = Float32,
        backend,
    )
    program = C.CompiledPottsProgram(
        base.shape,
        base.periodic,
        base.proposal_offsets,
        5,
        base.medium_kind,
        base.temperature,
        base.attempts_per_site,
        base.parameter_defaults,
        base.relationships,
        base.tracker_plan,
        base.descriptor_plan,
        base.stage_plan,
        base.engine,
        base.backend,
        base.fingerprint * "-lifecycle-relationships";
        medium_kinds = (true, false, false, false, false),
        lifecycle_plan = base.lifecycle_plan,
        checkerboard_plan = base.checkerboard_plan,
        ownership_change_handles = base.ownership_change_handles,
        mechanism_authority = base.mechanism_authority,
    )
    ownership = fill(Int32(-1), 6, 6)
    ownership[1] = 1
    ownership[2] = 2
    ownership[3] = 3
    kinds = Int16[2, 3, 5]
    generations = UInt32[1, 1, 1]
    relationships = C.ProgramRelationshipState(Float32, 2, 3, 2)
    C.apply_relationship_requests!(
        relationships,
        kinds,
        generations,
        schema,
        [
            C.CreateRelationshipRequest(1, 2; identity = 1),
            C.CreateRelationshipRequest(1, 3; identity = 2),
        ],
    )
    initial = C.ProgramInitialState(
        ownership,
        kinds;
        scalar_type = Float32,
        cell_generations = generations,
        relationships = (relationships,),
    )
    return C.initialize_program(
        program, initial, Float32[], UInt64(0x51a7e), UInt32(1)
    )
end

function test_lifecycle_relationship_staging(
        engine,
        action;
        adapt_to = identity,
        backend = CorePotts.CPUProgramBackend(),
    )
    C = CorePotts
    host = lifecycle_relationship_staging_runtime(engine, action; backend)
    runtime = adapt_to === identity ? host : C.adapt_program_runtime(adapt_to, host)
    before = C.program_snapshot(runtime)
    @test count(only(before.relationships).active) == 2
    C.advance_mcs!(runtime)
    @test !C.program_failed(runtime)
    after = C.program_snapshot(runtime)
    @test after.cell_kinds == Int16[4, 3, 5]
    relationships = only(after.relationships)
    expected = action === C.RemoveIncidentLifecycleRelationship ? 0 : 1
    @test count(relationships.active) == expected
    @test relationships.degree[1] == expected
    if action === C.RemoveIncompatibleLifecycleRelationship
        edge = findfirst(relationships.active)
        @test edge !== nothing
        @test Set((relationships.endpoint_a[edge], relationships.endpoint_b[edge])) ==
            Set(Int32[1, 2])
        @test relationships.degree == Int16[1, 1, 0]
    else
        @test all(iszero, relationships.degree)
    end
    return nothing
end
