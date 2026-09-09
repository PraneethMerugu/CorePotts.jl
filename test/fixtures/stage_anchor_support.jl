function stage_anchor_runtime(engine)
    schemas = map(((:cell_identity, :cell, (4,)), (:site_identity, :site, (6, 6)))) do (name, domain, shape)
        CorePotts.StateBlockSchema(
            CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", domain,
            Float32, shape, prod(shape), :structure_of_arrays, :provided_or_zero,
            :shape_and_finite, :logical, :preserve, :declared, :bounded_write,
            :adapt_storage, :copy, :logical_copy, :qualified, true,
        )
    end
    layout = CorePotts.StateLayout(collect(schemas))
    handles = map(entry -> entry.handle, layout.entries)
    reject = CorePotts.ProposalDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(false)),
        CorePotts.ResourceAccess((), (), CorePotts.EmptyFootprint(), CorePotts.EmptyFootprint(), CorePotts.NoWriteAccess()),
        CorePotts.DescriptorSupport(true, true, true, true), (), (), CorePotts.ProposalConstraintRole(), 1,
    )
    descriptors = map(enumerate(handles)) do (slot, handle)
        cell = slot == 1
        operation = cell ? CorePotts.ContextOperation{:energy_anchor_cell}() : CorePotts.ContextOperation{:energy_anchor_site}()
        effect = cell ? CorePotts.CellAssignmentEffect(handle, 2) : CorePotts.SiteAssignmentEffect(handle)
        footprint = cell ? CorePotts.OwnerFootprint() : CorePotts.FiniteSpatialFootprint(CorePotts.IterationSiteFootprintAnchor(), ((0, 0),))
        CorePotts.CompiledStageDescriptor(
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
            CorePotts.StaticEvaluator(CorePotts.ContextExpression(operation)), effect,
            CorePotts.AfterMCSStage(),
            CorePotts.ResourceAccess((), (handle,), cell ? CorePotts.EmptyFootprint() : footprint, footprint, CorePotts.ExclusiveWriteAccess()),
            CorePotts.DescriptorSupport(true, true, true, true), slot, 1,
        )
    end
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (CorePotts.ProposalDescriptorGroup([reject], (), (), :unsplit),), layout,
        CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (), Any[:cell_identity, :site_identity],
        1, "stage-anchor-descriptors", CorePotts.HamiltonianDomainResources(0, 0),
    )
    stage_plan = CorePotts.StageExecutionPlan(
        (), (CorePotts.StageDescriptorGroup(collect(descriptors)),), (), 0, 1, "stage-anchor-boundary",
    )
    program = test_program(engine; descriptor_plan, stage_plan, scalar_type = Float32)
    ownership = ones(Int32, 6, 6)
    ownership[1] = 2
    initial = CorePotts.ProgramInitialState(
        ownership, Int16[2, 2, 0]; scalar_type = Float32,
        descriptor_state = CorePotts.allocate_auxiliary_state(layout, (zeros(Float32, 4), zeros(Float32, 6, 6))),
    )
    return CorePotts.initialize_program(program, initial, Float32[], UInt64(31), UInt32(1)), handles
end

function stage_anchor_contract(runtime, handles)
    before = CorePotts.program_snapshot(runtime)
    CorePotts.advance_mcs!(runtime)
    after = CorePotts.program_snapshot(runtime)
    @test !CorePotts.program_failed(runtime)
    @test after.ownership == before.ownership
    @test CorePotts.state_block(after.descriptor_state, handles[1]).values == Float32[1, 2, 0, 0]
    return @test CorePotts.state_block(after.descriptor_state, handles[2]).values == reshape(Float32.(1:36), 6, 6)
end
