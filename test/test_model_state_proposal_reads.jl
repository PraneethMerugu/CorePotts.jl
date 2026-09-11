function model_predicate_program(engine, allowed; domain = :model, shape = (), spatial = false)
    schema = CorePotts.StateBlockSchema(
        CorePotts.QualifiedResourceIdentity((), :allowed), v"1.0.0",
        domain, Bool, shape, 1, :structure_of_arrays, :provided_or_zero,
        :shape_and_finite, :logical, :preserve, :declared, :bounded_write,
        :adapt_storage, :copy, :logical_copy, :qualified, true,
    )
    layout = CorePotts.StateLayout([schema])
    handle = only(layout.entries).handle
    expression = spatial ? CorePotts.OperationExpression(
            CorePotts.ResourceOperation{:field_value}(), CorePotts.StateExpression(handle),
            CorePotts.ContextExpression(CorePotts.ContextOperation{:target_site}()),
        ) : CorePotts.OperationExpression(
            CorePotts.operation_callable(Val(:model_bound_state_value), v"1.0.0"),
            CorePotts.StateExpression(handle),
        )
    descriptor = CorePotts.ProposalDescriptor(
        CorePotts.StaticEvaluator(expression),
        CorePotts.ResourceAccess(
            (handle,), (), CorePotts.ModelFootprint(),
            CorePotts.EmptyFootprint(), CorePotts.NoWriteAccess(),
        ),
        CorePotts.DescriptorSupport(true, true, true, true),
        (handle,), (), CorePotts.ProposalConstraintRole(), 1,
    )
    plan = CorePotts.DescriptorExecutionPlan(
        (CorePotts.ProposalDescriptorGroup([descriptor], (handle,), (), :unsplit),),
        layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]),
        (), Any[:model_predicate], 1, "model-predicate",
        CorePotts.HamiltonianDomainResources(0, 0),
    )
    program = test_program(engine; descriptor_plan = plan, scalar_type = Float32)
    base = test_initial(Float32)
    state = CorePotts.allocate_auxiliary_state(layout, [fill(allowed)])
    initial = CorePotts.ProgramInitialState(
        base.ownership, base.cell_kinds; scalar_type = Float32,
        descriptor_state = state,
    )
    return program, initial, handle
end

function model_stage_domain_program(
        engine; read_domain = :model, target_domain = :site,
        model_read = true, model_target = false, read_in_condition = false
    )
    schemas = map((:input, :output), (read_domain, target_domain)) do name, domain
        shape = domain === :model ? () : (6, 6)
        CorePotts.StateBlockSchema(
            CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", domain,
            Float32, shape, prod(shape; init = 1), :structure_of_arrays,
            :provided_or_zero, :shape_and_finite, :logical, :preserve,
            :declared, :bounded_write, :adapt_storage, :copy, :logical_copy,
            :qualified, true,
        )
    end
    layout = CorePotts.StateLayout(collect(schemas))
    input, output = map(entry -> entry.handle, layout.entries)
    operation = model_read ? :model_bound_state_value : :iteration_bound_state_value
    read = CorePotts.OperationExpression(
        CorePotts.operation_callable(Val(operation), v"1.0.0"),
        CorePotts.StateExpression(input),
    )
    condition = read_in_condition ? CorePotts.OperationExpression(
            >, read, CorePotts.LiteralExpression(0.0f0),
        ) : CorePotts.LiteralExpression(true)
    value = read_in_condition ? CorePotts.LiteralExpression(1.0f0) : read
    footprint = model_target ? CorePotts.ModelFootprint() : CorePotts.FiniteSpatialFootprint(
            CorePotts.IterationSiteFootprintAnchor(), ((0, 0),),
        )
    effect = model_target ? CorePotts.ModelAssignmentEffect(output) : CorePotts.SiteAssignmentEffect(output)
    descriptor = CorePotts.CompiledStageDescriptor(
        CorePotts.StaticEvaluator(condition), CorePotts.StaticEvaluator(value),
        effect, CorePotts.AfterMCSStage(),
        CorePotts.ResourceAccess((input,), (output,), footprint, footprint, CorePotts.ExclusiveWriteAccess()),
        CorePotts.DescriptorSupport(true, true, true, true), 1, 1,
    )
    stages = CorePotts.StageExecutionPlan(
        (), (CorePotts.StageDescriptorGroup([descriptor]),), (), 0,
        model_target ? 0 : 1, "model-stage-domains",
    )
    descriptors = CorePotts.DescriptorExecutionPlan(
        (), layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (),
        Any[:model_stage_domain], 0, "model-stage-domains",
        CorePotts.HamiltonianDomainResources(0, 0),
    )
    return test_program(engine; descriptor_plan = descriptors, stage_plan = stages, scalar_type = Float32)
end

@testset "stage read and write domains are validated before execution" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        for read_in_condition in (false, true)
            @test_throws r"declared model-owned" model_stage_domain_program(
                engine;
                read_domain = :site, read_in_condition
            )
            @test_throws r"not a spatial resource" model_stage_domain_program(
                engine;
                model_read = false, read_in_condition
            )
        end
        @test_throws r"site-owned" model_stage_domain_program(engine; target_domain = :model)
        @test_throws r"model-owned" model_stage_domain_program(engine; model_target = true)
    end
end

@testset "model reads require the declared model storage owner" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @test_throws r"declared model-owned" model_predicate_program(engine, false; domain = :site, shape = (6, 6))
        @test_throws r"declared model-owned" model_predicate_program(engine, false; shape = (2,))
        @test_throws r"not a spatial resource" model_predicate_program(engine, false; spatial = true)
    end
end

@testset "model predicates govern actionable copy attempts" begin
    @testset "$(typeof(engine))" for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        program, initial, handle = model_predicate_program(engine, false)
        runtime = CorePotts.initialize_program(program, initial, Float32[], UInt64(17), UInt32(1))
        for _ in 1:3
            CorePotts.advance_mcs!(runtime)
        end
        snapshot = CorePotts.program_snapshot(runtime)
        @test snapshot.ownership == initial.ownership
        @test runtime.constraint_rejections > 0
        @test runtime.accepted == 0
        @test only(CorePotts.state_block(snapshot.descriptor_state, handle).values) === false
        restored = CorePotts.restore_program_checkpoint(program, CorePotts.program_checkpoint(runtime))
        CorePotts.advance_mcs!(runtime)
        CorePotts.advance_mcs!(restored)
        @test CorePotts.program_snapshot(restored).ownership == CorePotts.program_snapshot(runtime).ownership
        @test restored.constraint_rejections == runtime.constraint_rejections
    end
end
