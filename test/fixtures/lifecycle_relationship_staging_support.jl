isdefined(@__MODULE__, :receipt_descriptor) ||
    include("lifecycle_descriptor_support.jl")

function lifecycle_relationship_staging_runtime(
        engine,
        action;
        backend = CorePotts.CPUProgramBackend(),
        requests = nothing,
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
    relationship_requests = requests === nothing ? [
        C.CreateRelationshipRequest(1, 2; identity = 1),
        C.CreateRelationshipRequest(1, 3; identity = 2),
    ] : requests
    C.apply_relationship_requests!(
        relationships,
        kinds,
        generations,
        schema,
        relationship_requests,
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

function test_lifecycle_relationship_stage_order(plan_class)
    C = CorePotts
    runtime = lifecycle_relationship_staging_runtime(
        C.SequentialProgramEngine(), C.RemoveIncidentLifecycleRelationship,
    )
    plan = runtime.program.lifecycle_plan
    workspace = runtime.lifecycle_workspace
    copyto!(workspace.staged_cell_kinds, runtime.cell_kinds)
    copyto!(workspace.staged_relationships, runtime.relationships)
    @inbounds workspace.anchor[1] = Int32(1)
    recipe = C._lifecycle_relationship_recipe(plan)
    state = C._lifecycle_relationship_state(workspace)
    descriptor = only(plan.descriptors)
    @test C._apply_lifecycle_pre_relationships!(
        C.HostLifecycleExecution(), recipe, state,
        1, descriptor, plan_class,
    )
    @test C._apply_lifecycle_post_relationships!(
        C.HostLifecycleExecution(), recipe, state,
        1, descriptor, plan_class,
    )
    relationships = only(workspace.staged_relationships)
    @test count(relationships.active) == 0
    @test all(iszero, relationships.degree)
    return nothing
end

function test_lifecycle_relationship_request_order()
    C = CorePotts
    runtime = lifecycle_relationship_staging_runtime(
        C.SequentialProgramEngine(), C.RemoveIncidentLifecycleRelationship,
        requests = [
            C.CreateRelationshipRequest(1, 2; identity = 1),
            C.CreateRelationshipRequest(2, 3; identity = 2),
        ],
    )
    plan = runtime.program.lifecycle_plan
    workspace = runtime.lifecycle_workspace
    copyto!(workspace.staged_cell_kinds, runtime.cell_kinds)
    copyto!(workspace.staged_relationships, runtime.relationships)
    @inbounds begin
        workspace.anchor[1] = Int32(1)
        workspace.anchor[2] = Int32(2)
    end
    recipe = C._lifecycle_relationship_recipe(plan)
    state = C._lifecycle_relationship_state(workspace)
    descriptor = only(plan.descriptors)
    plan_class = C._RemoveLifecyclePlan()
    @test C._apply_lifecycle_pre_relationships!(
        C.HostLifecycleExecution(), recipe, state,
        1, descriptor, plan_class,
    )
    @test count(only(workspace.staged_relationships).active) == 1
    @test C._apply_lifecycle_pre_relationships!(
        C.HostLifecycleExecution(), recipe, state,
        2, descriptor, plan_class,
    )
    @test count(only(workspace.staged_relationships).active) == 0
    @test all(iszero, only(workspace.staged_relationships).degree)
    return nothing
end

function test_lifecycle_relationship_selected_sequence()
    C = CorePotts
    runtime = lifecycle_relationship_staging_runtime(
        C.SequentialProgramEngine(), C.RemoveIncidentLifecycleRelationship,
        requests = [
            C.CreateRelationshipRequest(1, 2; identity = 1),
            C.CreateRelationshipRequest(2, 3; identity = 2),
        ],
    )
    workspace = runtime.lifecycle_workspace
    copyto!(workspace.staged_cell_kinds, runtime.cell_kinds)
    copyto!(workspace.staged_relationships, runtime.relationships)
    @inbounds begin
        workspace.descriptor[1] = Int32(1)
        workspace.descriptor[2] = Int32(1)
        workspace.anchor[1] = Int32(1)
        workspace.anchor[2] = Int32(2)
        workspace.selection.ready[1] = true
        workspace.selection.selected_requests.count[1] = Int32(2)
        workspace.selection.selected_requests.records.request[1] = Int32(1)
        workspace.selection.selected_requests.records.request[2] = Int32(2)
    end
    recipe = C._lifecycle_relationship_recipe(runtime.program.lifecycle_plan)
    state = C._lifecycle_relationship_state(workspace)
    cadence = C._LifecycleCadenceControl(Int32[1])
    kernel = C._stage_lifecycle_relationships_backend_kernel!(
        KernelAbstractions.CPU(), 1,
    )
    kernel(
        recipe, state, cadence, Val(:remove_incident); ndrange = 1,
    )
    @test count(only(workspace.staged_relationships).active) == 0
    @test all(iszero, only(workspace.staged_relationships).degree)
    return nothing
end
