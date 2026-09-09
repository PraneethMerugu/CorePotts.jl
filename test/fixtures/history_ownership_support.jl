using Test
import CorePotts

function history_ownership_program(engine; allow = true, fail_assignment = false)
    C = CorePotts
    shape = (5, 5)
    schemas = map(
        (
            (:source, :site, shape, :PreserveOnOwnershipChange),
            (:cleared, :history, (shape..., 3), :ClearOnOwnershipChange),
            (:preserved, :history, (shape..., 3), :PreserveOnOwnershipChange),
        )
    ) do (name, domain, extent, policy)
        C.StateBlockSchema(
            C.QualifiedResourceIdentity((), name), v"1.0.0", domain,
            Float32, extent, prod(extent), :structure_of_arrays, :provided_or_zero,
            :shape_and_finite, :logical, (declared = policy,), :declared,
            :bounded_write, :adapt_storage, :copy, :logical_copy, :qualified, true
        )
    end
    layout = C.StateLayout(collect(schemas))
    handle(name) = only(entry.handle for entry in layout.entries if entry.schema.identity.name === name)
    source, cleared, preserved = handle(:source), handle(:cleared), handle(:preserved)
    histories = map((cleared, preserved)) do target
        C.CompiledStageDescriptor(
            C.StaticEvaluator(C.LiteralExpression(true)),
            C.StaticEvaluator(C.LiteralExpression(0.0f0)),
            C.ShiftAppendEffect(target, source, 3; cadence = C.PeriodicMCSCadence, cadence_value = 100),
            C.AfterMCSStage(), C.ResourceAccess(
                (source, target), (target,),
                C.FiniteSpatialFootprint(C.IterationSiteFootprintAnchor(), ((0, 0),)),
                C.FiniteSpatialFootprint(C.IterationSiteFootprintAnchor(), ((0, 0),)), C.ExclusiveWriteAccess()
            ),
            C.DescriptorSupport(true, true, true, true), 1, 0
        )
    end
    accepted = if fail_assignment
        descriptor = C.CompiledStageDescriptor(
            C.StaticEvaluator(C.LiteralExpression(true)),
            C.StaticEvaluator(C.OperationExpression(/, C.LiteralExpression(1.0f0), C.LiteralExpression(0.0f0))),
            C.SiteAssignmentEffect(source), C.AcceptedCopyStage(),
            C.ResourceAccess(
                (), (source,), C.EmptyFootprint(),
                C.FiniteSpatialFootprint(C.ProposalTargetFootprintAnchor(), ((0, 0),)), C.ExclusiveWriteAccess()
            ),
            C.DescriptorSupport(true, true, true, true), 1, 1,
        )
        (C.StageDescriptorGroup([descriptor]),)
    else
        ()
    end
    stages = C.StageExecutionPlan(
        accepted, (), (C.StageDescriptorGroup(collect(histories)),),
        fail_assignment ? 1 : 0, 0, "history-ownership"
    )
    guard = C.ProposalDescriptor(
        C.StaticEvaluator(C.LiteralExpression(allow)),
        C.ResourceAccess((), (), C.EmptyFootprint(), C.EmptyFootprint(), C.NoWriteAccess()),
        C.DescriptorSupport(true, true, true, true), (), (), C.ProposalConstraintRole(), 1
    )
    descriptors = C.DescriptorExecutionPlan(
        (C.ProposalDescriptorGroup([guard], (), (), :unsplit),),
        layout, C.WorkspaceLayout(C.WorkspaceSchema[]), (), Any[:history_ownership], 0,
        "history-ownership", C.HamiltonianDomainResources(0, 0)
    )
    offsets = Int8[1 -1 0 0; 0 0 1 -1]
    checkerboard = engine isa C.CheckerboardProgramEngine ? C.CheckerboardPlan(shape, (true, true), offsets) : C.NoCheckerboardPlan()
    program = C.CompiledPottsProgram(
        shape, (true, true), offsets, 2, 1,
        C.CompiledScalar(0.0f0), 1, Float32[], (),
        C.TrackerExecutionPlan((C.OwnershipCountTracker(),), "history-ownership"),
        descriptors, stages, engine, C.CPUProgramBackend(), "history-ownership";
        checkerboard_plan = checkerboard, ownership_change_handles = (cleared,)
    )
    owners = zeros(Int32, shape)
    owners[2:3, 2:3] .= 1
    samples = cat((fill(Float32(sample), shape) for sample in 1:3)...; dims = 3)
    state = C.allocate_auxiliary_state(
        layout, map(layout.entries) do entry
            entry.schema.identity.name === :source ? fill(7.0f0, shape) : copy(samples)
        end
    )
    initial = C.ProgramInitialState(owners, Int16[2]; scalar_type = Float32, descriptor_state = state)
    return (; program, initial, cleared, preserved, source, samples)
end

function test_history_ownership_failure(engines; adapt_runtime = identity)
    return @testset "failed accepted-copy validation preserves history and ownership" begin
        C = CorePotts
        for engine in engines
            (; program, initial, cleared, preserved, source) = history_ownership_program(engine; fail_assignment = true)
            runtime = adapt_runtime(C.initialize_program(program, initial, Float32[], UInt64(1), UInt32(1)))
            before = C.program_snapshot(runtime)
            if engine isa C.SequentialProgramEngine
                @test_throws DomainError C.advance_mcs!(runtime)
            else
                C.advance_mcs!(runtime)
                @test C.program_failed(runtime)
            end
            after = C.program_snapshot(runtime)
            @test runtime.accepted == 0
            @test after.ownership == before.ownership
            for handle in (source, cleared, preserved)
                @test C.state_block(after.descriptor_state, handle).values ==
                    C.state_block(before.descriptor_state, handle).values
            end
        end
    end
end

function test_history_ownership_change(engines; adapt_runtime = identity)
    return @testset "ownership changes clear every retained site sample" begin
        C = CorePotts
        for engine in engines, allow in (false, true)
            (; program, initial, cleared, preserved, source, samples) = history_ownership_program(engine; allow)
            runtime = adapt_runtime(C.initialize_program(program, initial, Float32[], UInt64(1), UInt32(1)))
            before = C.program_snapshot(runtime)
            C.advance_mcs!(runtime)
            after = C.program_snapshot(runtime)
            values = C.state_block(after.descriptor_state, cleared).values
            @test !C.program_failed(runtime)
            @test C.state_block(after.descriptor_state, preserved).values == samples
            @test all(==(7.0f0), C.state_block(after.descriptor_state, source).values)
            if allow
                @test runtime.accepted > 0
                changed = before.ownership .!= after.ownership
                @test any(changed)
                mask = values[:, :, 1] .== 0
                @test all(mask[changed])
                @test any(.!mask)
                for sample in 1:3
                    @test values[:, :, sample] == ifelse.(mask, 0.0f0, Float32(sample))
                end
            else
                @test runtime.accepted == 0
                @test after.ownership == before.ownership
                @test values == samples
            end
            if engine isa C.CheckerboardProgramEngine
                @test length(unique(diff(program.checkerboard_plan.color_offsets))) > 1
            end
        end
    end
end
