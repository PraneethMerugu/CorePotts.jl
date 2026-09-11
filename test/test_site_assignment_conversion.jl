function _site_conversion_runtime(engine, rhs; parameterized = false)
    schema = CorePotts.StateBlockSchema(
        CorePotts.QualifiedResourceIdentity((), :converted_signal), v"1.0.0", :site,
        Float32, (6, 6), 36, :structure_of_arrays,
        :provided_or_zero, :shape_and_finite, :logical, :preserve,
        :declared, :bounded_write, :adapt_storage, :copy, :logical_copy,
        :qualified, true,
    )
    layout = CorePotts.StateLayout([schema])
    handle = only(layout.entries).handle
    footprint = CorePotts.FiniteSpatialFootprint(
        CorePotts.IterationSiteFootprintAnchor(), ((0, 0),),
    )
    value = parameterized ? CorePotts.OperationExpression(
            *, CorePotts.LiteralExpression(rhs), CorePotts.ParameterExpression(1.0f0, 1),
        ) : CorePotts.LiteralExpression(rhs)
    descriptor = CorePotts.CompiledStageDescriptor(
        CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
        CorePotts.StaticEvaluator(value),
        CorePotts.SiteAssignmentEffect(handle), CorePotts.AfterMCSStage(),
        CorePotts.ResourceAccess(
            (), (handle,), footprint, footprint, CorePotts.ExclusiveWriteAccess(),
        ),
        CorePotts.DescriptorSupport(true, true, true, true), 1, 1,
    )
    stage_plan = CorePotts.StageExecutionPlan(
        (), (CorePotts.StageDescriptorGroup([descriptor]),), (), 0, 1,
        "site-target-conversion",
    )
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (), layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (),
        Any[:converted_signal], 0, "site-target-conversion-descriptors",
        CorePotts.HamiltonianDomainResources(0, 0),
    )
    parameters = parameterized ? Float32[1] : Float32[]
    program = test_program(
        engine; descriptor_plan, stage_plan, scalar_type = Float32,
        parameter_defaults = parameters,
    )
    initial = test_initial(Float32)
    initial = CorePotts.ProgramInitialState(
        initial.ownership, initial.cell_kinds; scalar_type = Float32,
        descriptor_state = CorePotts.allocate_auxiliary_state(layout, (ones(Float32, 6, 6),)),
    )
    return CorePotts.initialize_program(program, initial, parameters, UInt64(0xc017), UInt32(1)), handle
end

@testset "site assignments validate converted target values" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine))) rhs=$rhs parameterized=$parameterized" for
            rhs in (2.5, 1.0e300), parameterized in (false, true)
            @test isfinite(rhs)
            overflowing = !isfinite(convert(Float32, rhs))
            runtime, handle = _site_conversion_runtime(engine, rhs; parameterized)
            before = CorePotts.program_snapshot(runtime)
            if overflowing && engine isa CorePotts.SequentialProgramEngine
                @test_throws DomainError CorePotts.advance_mcs!(runtime)
            else
                CorePotts.advance_mcs!(runtime)
                @test CorePotts.program_failed(runtime) == overflowing
            end
            after = CorePotts.program_snapshot(runtime)
            @test runtime.settled
            @test after.mcs == (overflowing ? 0 : 1)
            @test all(
                ==(overflowing ? 1.0f0 : Float32(rhs)),
                CorePotts.state_block(after.descriptor_state, handle).values,
            )
            @test all(==(1.0f0), CorePotts.state_block(before.descriptor_state, handle).values)
            if overflowing
                @test after.ownership == before.ownership
                @test after.cell_kinds == before.cell_kinds
                @test after.cell_generations == before.cell_generations
                @test after.trackers.values == before.trackers.values
                @test CorePotts.program_lifecycle_receipt(runtime) === nothing
            end
        end
    end
end

@testset "parameter views preserve their execution domain without expanding storage" begin
    parameters = Float32[2, 3]
    view = CorePotts._checkerboard_parameter_view(parameters, Val(2), (2, 3))
    @test size(view) == (2, 3)
    @test length(view) == 6
    @test strides(view) == (1, 2)
    @test view[1] == view[2, 3] == (2.0f0, 3.0f0)
    parameters[1] = 5
    @test view[1, 2] == (5.0f0, 3.0f0)
    adapted = CorePotts.Adapt.adapt(Array, view)
    @test size(adapted) == size(view)
    @test adapted[2, 1] == (5.0f0, 3.0f0)
    @test CorePotts._checkerboard_parameter_view(parameters, Val(2), ())[] == (5.0f0, 3.0f0)
    @test isempty(CorePotts._checkerboard_parameter_view(parameters, Val(2), (0, 2)))
    @test_throws ArgumentError CorePotts._checkerboard_parameter_view(parameters, Val(3), (2, 3))
    @test_throws ArgumentError CorePotts._checkerboard_parameter_view(parameters, Val(2), (-1, 3))
end
