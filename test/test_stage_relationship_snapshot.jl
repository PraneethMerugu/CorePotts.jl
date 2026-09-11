using Test
import CorePotts

function _relationship_snapshot_runtime(engine; ordered_tail = nothing)
    state_schema(name, domain, shape) = CorePotts.StateBlockSchema(
        CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", domain,
        Float32, shape, prod(shape), :structure_of_arrays,
        :provided_or_zero, :shape_and_finite, :logical, :preserve,
        :declared, :bounded_write, :adapt_storage, :copy, :logical_copy,
        :qualified, true,
    )
    layout = CorePotts.StateLayout(
        [
            state_schema(:marker, :site, (6, 6)),
            state_schema(:marker_history, :history, (6, 6, 2)),
        ]
    )
    marker, history = map(entry -> entry.handle, layout.entries)
    site_footprint = CorePotts.FiniteSpatialFootprint(
        CorePotts.IterationSiteFootprintAnchor(), ((0, 0),),
    )
    assignment = CorePotts.CompiledStageDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(2.0f0)),
        CorePotts.SiteAssignmentEffect(marker), CorePotts.AfterMCSStage(),
        CorePotts.ResourceAccess(
            (), (marker,), site_footprint, site_footprint,
            CorePotts.ExclusiveWriteAccess(),
        ),
        CorePotts.DescriptorSupport(true, true, true, true), 1, 1,
    )
    # The fixture's relationship endpoints are slots 1 and 2. The compiled
    # relationship gather therefore includes this explicit linear site 1.
    marker_read = CorePotts.OperationExpression(
        CorePotts.ResourceOperation{:field_value}(),
        CorePotts.StateExpression(marker), CorePotts.LiteralExpression(Int32(1)),
    )
    retune = CorePotts.CompiledStageDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(0.0f0)),
        CorePotts.RelationshipRetuneEffect(1, (CorePotts.StaticEvaluator(marker_read),)),
        CorePotts.AfterMCSStage(),
        CorePotts.ResourceAccess(
            (marker,), (Int32(1),), site_footprint,
            CorePotts.EmptyFootprint(), CorePotts.DeferredRequestWriteAccess(),
        ),
        CorePotts.DescriptorSupport(true, true, true, true), 2, 1,
    )
    read_current = CorePotts.OperationExpression(
        CorePotts.operation_callable(Val(:iteration_bound_state_value), v"1.0.0"),
        CorePotts.StateExpression(marker),
    )
    iterate = CorePotts.CompiledStageDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
        CorePotts.StaticEvaluator(CorePotts.OperationExpression(+, read_current, CorePotts.LiteralExpression(1.0f0))),
        CorePotts.IteratedSiteAssignmentEffect(marker, 2), CorePotts.AfterMCSStage(),
        CorePotts.ResourceAccess((marker,), (marker,), site_footprint, site_footprint, CorePotts.ExclusiveWriteAccess()),
        CorePotts.DescriptorSupport(true, true, true, true), 3, 2,
    )
    record = CorePotts.CompiledStageDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(0.0f0)),
        CorePotts.ShiftAppendEffect(history, marker, 3), CorePotts.AfterMCSStage(),
        CorePotts.ResourceAccess((history, marker), (history,), site_footprint, site_footprint, CorePotts.ExclusiveWriteAccess()),
        CorePotts.DescriptorSupport(true, true, true, true), 4, 0,
    )
    descriptors = ordered_tail === nothing ? (assignment, retune) :
        ordered_tail === :history_then_iterations ? (assignment, retune, record, iterate) :
        (assignment, retune, iterate, record)
    groups = map(descriptor -> CorePotts.StageDescriptorGroup([descriptor]), descriptors)
    stage_plan = CorePotts.StageExecutionPlan(
        (), groups, (), 0, ordered_tail === nothing ? 1 : 2,
        "mixed-stage-relationship-snapshot",
    )
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (), layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (),
        Any[:marker_assignment, :relationship_marker, :marker_iterations, :marker_history],
        0, "mixed-stage-descriptors", CorePotts.HamiltonianDomainResources(0, 0),
    )
    relationship_schema = CorePotts.RelationshipStoreSchema(1, 1, (CorePotts.CompiledScalar(0.0f0),))
    ownership = ones(Int32, 6, 6)
    ownership[:, 4:6] .= 2
    relationships = CorePotts.ProgramRelationshipState(Float32, 1, 2, 1, 1)
    CorePotts.apply_relationship_requests!(
        relationships, Int16[2, 2], UInt32[1, 1], relationship_schema,
        [CorePotts.CreateRelationshipRequest(1, 2, (0.0f0,); generation_a = 1, generation_b = 1, identity = 1)],
    )
    checkerboard_plan = engine isa CorePotts.CheckerboardProgramEngine ?
        CorePotts.CheckerboardPlan((6, 6), (true, true), zeros(Int8, 2, 0)) : CorePotts.NoCheckerboardPlan()
    program = CorePotts.CompiledPottsProgram(
        (6, 6), (true, true), zeros(Int8, 2, 1), 2, 1,
        CorePotts.CompiledScalar(0.0f0), 1, Float32[], (relationship_schema,),
        CorePotts.TrackerExecutionPlan((CorePotts.OwnershipCountTracker(),), "mixed-stage-count"),
        descriptor_plan, stage_plan, engine, CorePotts.CPUProgramBackend(),
        "mixed-stage-program"; checkerboard_plan,
    )
    initial = CorePotts.ProgramInitialState(
        ownership, Int16[2, 2]; scalar_type = Float32, relationships = (relationships,),
        descriptor_state = CorePotts.allocate_auxiliary_state(layout, (ones(Float32, 6, 6), zeros(Float32, 6, 6, 2))),
    )
    runtime = CorePotts.initialize_program(program, initial, Float32[], UInt64(0x8111), UInt32(1))
    return runtime, marker, history
end

@testset "relationship requests and synchronous assignments share their entry state" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            for ordered_tail in (nothing, :history_then_iterations, :iterations_then_history)
                @testset "$(ordered_tail)" begin
                    runtime, marker, history = _relationship_snapshot_runtime(engine; ordered_tail)
                    CorePotts.advance_mcs!(runtime)
                    @test !CorePotts.program_failed(runtime)
                    snapshot = CorePotts.program_snapshot(runtime)
                    @test snapshot.mcs == 1
                    @test count(snapshot.relationships[1].active) == 1
                    @test snapshot.relationships[1].payload[1][1] == 1.0f0
                    expected_marker = ordered_tail === nothing ? 2.0f0 : 4.0f0
                    @test all(==(expected_marker), CorePotts.state_block(snapshot.descriptor_state, marker).values)
                    history_values = CorePotts.state_block(snapshot.descriptor_state, history).values
                    @test all(iszero, history_values[:, :, 1])
                    expected_history = ordered_tail === nothing ? 0.0f0 :
                        ordered_tail === :history_then_iterations ? 2.0f0 : 4.0f0
                    @test all(==(expected_history), history_values[:, :, 2])
                end
            end
        end
    end
end
