import StaticArrays
isdefined(@__MODULE__, :receipt_descriptor) || include("lifecycle_descriptor_support.jl")

function heterogeneous_lifecycle_runtime(
        engine; values = (2.0f0, StaticArrays.SVector(3.0f0, 4.0f0)),
        initial_values = (1.0f0, StaticArrays.SVector(1.0f0, 2.0f0)),
    )
    schemas = map((:first_signal, :second_signal), initial_values) do name, initial
        CorePotts.StateBlockSchema(
            CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", :cell,
            typeof(initial), (1,), 1, :structure_of_arrays, :provided_or_zero,
            :shape_and_finite, :logical, :declared, :declared, :bounded_write,
            :adapt_storage, :copy, :logical_copy, :qualified, true,
        )
    end
    layout = CorePotts.StateLayout(collect(schemas))
    handles = map(schemas) do schema
        only(entry for entry in layout.entries if entry.schema.identity == schema.identity).handle
    end
    rules = map(eachindex(handles)) do index
        CorePotts.LifecycleStateRule(
            handles[index], UInt64(index), CorePotts.RetireToLifecycleState,
            Int32(index + 1), Int32(0), Int32(0), Int32(0), 0.5f0, CorePotts.ExactLifecycleRounding,
            UInt8(0), UInt8(0), CorePotts.RNGOperationKey(), CorePotts.RNGOperationKey(),
        )
    end
    evaluators = CorePotts.LifecycleEvaluatorStorage(
        Any[CorePotts.StaticEvaluator(CorePotts.LiteralExpression(value)) for value in (true, values...)],
        [:lifecycle_trigger, :lifecycle_state_transform, :lifecycle_state_transform],
    )
    descriptor = receipt_descriptor(
        1, CorePotts.RemoveCellLifecycleEffect; domain_kind = 2,
        state_rule_count = 2, scalar_type = Float32,
    )
    lifecycle = CorePotts.LifecycleExecutionPlan(
        [descriptor], evaluators, CorePotts.LifecycleStateRuleStorage(rules),
        CorePotts.LifecycleRelationshipRule[], (), NTuple{2, Int16}[],
        CorePotts.LifecycleRelationStorage((), Val(2)), CorePotts.StablePriorityLifecycleConflicts,
        1, 1, 1, 0, falses(2),
    )
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (), layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (),
        Any[:remove_cell], 0, "heterogeneous-lifecycle-values", CorePotts.HamiltonianDomainResources(0, 0),
    )
    program = test_program(engine; descriptor_plan, lifecycle_plan = lifecycle, scalar_type = Float32)
    initial_by_identity = Dict(schema.identity => [value] for (schema, value) in zip(schemas, initial_values))
    initial = CorePotts.ProgramInitialState(
        ones(Int32, 6, 6), Int16[2]; scalar_type = Float32,
        descriptor_state = CorePotts.allocate_auxiliary_state(
            layout, map(entry -> initial_by_identity[entry.schema.identity], layout.entries),
        ),
    )
    return CorePotts.initialize_program(program, initial, Float32[], UInt64(0xc330), UInt32(1)), handles
end

function test_heterogeneous_lifecycle_values(engine; adapt_to = identity)
    cases = (
        ((2.0f0, StaticArrays.SVector(3.0f0, 4.0f0)), false),
        ((Int32(2), StaticArrays.SVector(Int32(3), Int32(4))), false),
        ((StaticArrays.SVector(2.0f0, 3.0f0), StaticArrays.SVector(3.0f0, 4.0f0)), true),
        ((2.0f0, 3.0f0), true),
    )
    for (values, invalid) in cases
        test_lifecycle_value_conversion(
            engine; adapt_to, values, invalid,
            initial_values = (1.0f0, StaticArrays.SVector(1.0f0, 2.0f0)),
            expected_values = (2.0f0, StaticArrays.SVector(3.0f0, 4.0f0)),
        )
    end
    return
end

function test_different_length_lifecycle_values(engine; adapt_to = identity)
    initial_values = (StaticArrays.SVector(1.0f0, 2.0f0), StaticArrays.SVector(1.0f0, 2.0f0, 3.0f0))
    expected_values = (StaticArrays.SVector(3.0f0, 4.0f0), StaticArrays.SVector(4.0f0, 5.0f0, 6.0f0))
    cases = (
        ("matched vector lengths", expected_values, false),
        ("invalid vector length", (expected_values[1], StaticArrays.SVector(4.0f0, 5.0f0)), true),
        ("equal-length reshape", (StaticArrays.SMatrix{1, 2}(3.0f0, 4.0f0), expected_values[2]), false),
    )
    for (name, values, invalid) in cases
        @testset "$name" begin
            test_lifecycle_value_conversion(engine; adapt_to, values, invalid, initial_values, expected_values)
        end
    end
    return
end

function test_lifecycle_value_conversion(engine; adapt_to, values, invalid, initial_values, expected_values)
    host, handles = heterogeneous_lifecycle_runtime(engine; values, initial_values)
    runtime = adapt_to === identity ? host : CorePotts.adapt_program_runtime(adapt_to, host)
    before = CorePotts.program_snapshot(runtime)
    CorePotts.advance_mcs!(runtime)
    after = CorePotts.program_snapshot(runtime)
    @test CorePotts.program_failed(runtime) == invalid
    @test runtime.settled
    @test after.mcs == (invalid ? 0 : 1)
    @test after.ownership == (invalid ? before.ownership : fill(Int32(-1), 6, 6))
    @test after.cell_kinds == (invalid ? before.cell_kinds : Int16[0])
    for (index, handle) in enumerate(handles)
        expected = invalid ? CorePotts.state_block(before.descriptor_state, handle).values :
            [expected_values[index]]
        @test CorePotts.state_block(after.descriptor_state, handle).values == expected
        @test eltype(CorePotts.state_block(after.descriptor_state, handle).values) ===
            eltype(CorePotts.state_block(before.descriptor_state, handle).values)
    end
    if invalid
        @test after.cell_generations == before.cell_generations
        @test after.trackers.values == before.trackers.values
        @test CorePotts.program_lifecycle_receipt(runtime) === nothing
        failure = CorePotts.program_failure_report(runtime)
        @test failure.code === CorePotts.ProgramStatusEvaluator
        @test failure.detail === CorePotts.LifecycleDetailStateValueInvalid
        @test failure.source == 1
    else
        @test count(event -> event isa CorePotts.RemoveCellLifecycleEvent, CorePotts.program_lifecycle_receipt(runtime)) == 1
    end
    return
end
