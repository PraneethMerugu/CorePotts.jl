import StaticArrays
isdefined(@__MODULE__, :receipt_descriptor) || include("lifecycle_descriptor_support.jl")

function heterogeneous_lifecycle_runtime(
        engine; values = (2.0f0, StaticArrays.SVector(3.0f0, 4.0f0)),
        initial_values = (1.0f0, StaticArrays.SVector(1.0f0, 2.0f0)),
        rule_indices = (1, 2),
        state_evaluator_values = values,
        state_action = CorePotts.RetireToLifecycleState,
        evaluator_order = ntuple(identity, length(state_evaluator_values) + 1),
    )
    evaluator_values = (true, state_evaluator_values...)
    evaluator_roles = [:lifecycle_trigger; fill(:lifecycle_state_transform, length(state_evaluator_values))]
    sort(collect(evaluator_order)) == collect(eachindex(evaluator_values)) ||
        throw(ArgumentError("evaluator order must be a permutation of the fixture evaluators"))
    state_names = (:first_signal, :second_signal)[1:length(initial_values)]
    schemas = map(state_names, initial_values) do name, initial
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
    rules = map(collect(rule_indices)) do index
        CorePotts.LifecycleStateRule(
            handles[index], UInt64(index), state_action,
            Int32(something(findfirst(==(index + 1), evaluator_order))), Int32(0), Int32(0), Int32(0), 0.5f0, CorePotts.ExactLifecycleRounding,
            UInt8(0), UInt8(0), CorePotts.RNGOperationKey(), CorePotts.RNGOperationKey(),
        )
    end
    evaluators = CorePotts.LifecycleEvaluatorStorage(
        Any[CorePotts.StaticEvaluator(CorePotts.LiteralExpression(evaluator_values[index])) for index in evaluator_order],
        [evaluator_roles[index] for index in evaluator_order],
    )
    descriptor = receipt_descriptor(
        1, CorePotts.RemoveCellLifecycleEffect; domain_kind = 2,
        trigger_evaluator = something(findfirst(==(1), evaluator_order)),
        state_rule_count = length(rules), scalar_type = Float32,
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

function test_lifecycle_value_conversion(
        engine; adapt_to, values, invalid, initial_values, expected_values,
        expected_detail = CorePotts.LifecycleDetailStateValueInvalid,
        rule_indices = (1, 2),
        state_evaluator_values = values,
        state_action = CorePotts.RetireToLifecycleState,
        evaluator_order = ntuple(identity, length(state_evaluator_values) + 1),
    )
    host, handles = heterogeneous_lifecycle_runtime(engine; values, initial_values, rule_indices, state_evaluator_values, state_action, evaluator_order)
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
        @test failure.detail === expected_detail
        @test failure.source == 1
    else
        @test count(event -> event isa CorePotts.RemoveCellLifecycleEvent, CorePotts.program_lifecycle_receipt(runtime)) == 1
    end
    return
end

function test_lifecycle_scalar_evaluator(engine; adapt_to = identity)
    initial = (Int32(1), (false, StaticArrays.SVector(Int32(1), Int32(2))))
    numeric = (2.0f0, (1.0f0, StaticArrays.SVector(3.0f0, 4.0f0)))
    test_lifecycle_value_conversion(
        engine; adapt_to, values = (2.0f0, numeric), invalid = false,
        initial_values = (1.0f0, initial), expected_values = (2.0f0, initial),
        rule_indices = (1,), state_evaluator_values = (2.0f0,),
    )
    return
end

function test_lifecycle_scalar_state(engine; adapt_to = identity)
    test_lifecycle_value_conversion(
        engine; adapt_to, values = (2.0f0,), invalid = false,
        initial_values = (1.0f0,), expected_values = (2.0f0,),
        rule_indices = (1,), state_evaluator_values = (2.0f0,),
    )
    return
end

function test_lifecycle_preserved_scalar_state(engine; adapt_to = identity)
    test_lifecycle_value_conversion(
        engine; adapt_to, values = (2.0f0,), invalid = false,
        initial_values = (1.0f0,), expected_values = (1.0f0,),
        rule_indices = (1,), state_evaluator_values = (2.0f0,),
        state_action = CorePotts.PreserveLifecycleState,
    )
    return
end

function test_lifecycle_scalar_evaluator_order(engine; adapt_to = identity)
    test_lifecycle_value_conversion(
        engine; adapt_to, values = (2.0f0,), invalid = false,
        initial_values = (1.0f0,), expected_values = (2.0f0,),
        rule_indices = (1,), state_evaluator_values = (2.0f0,),
        evaluator_order = (2, 1),
    )
    return
end

function test_lifecycle_rule_composition(engine; adapt_to = identity)
    initial = (Int32(1), (false, StaticArrays.SVector(Int32(1), Int32(2))))
    numeric = (2.0f0, (1.0f0, StaticArrays.SVector(3.0f0, 4.0f0)))
    expected = (Int32(2), (true, StaticArrays.SVector(Int32(3), Int32(4))))
    cases = (
        ("scalar rule", (1,), (2.0f0, numeric), (2.0f0, initial)),
        ("numeric product rule", (2,), (2.0f0, numeric), (1.0f0, expected)),
        ("coexisting numeric rules", (1, 2), (2.0f0, numeric), (2.0f0, expected)),
        ("coexisting matched rules", (1, 2), (2.0f0, expected), (2.0f0, expected)),
    )
    for (name, rule_indices, values, expected_values) in cases
        @testset "$name" begin
            test_lifecycle_value_conversion(
                engine; adapt_to, values, invalid = false,
                initial_values = (1.0f0, initial), expected_values, rule_indices,
            )
        end
    end
    return
end

function test_lifecycle_small_numeric_values(engine; adapt_to = identity)
    for target_type in (Int32, UInt32, Bool), value in (0.0f0, -0.0f0, nextfloat(0.0f0), prevfloat(0.0f0), 0.5f0)
        invalid = !(value === 0.0f0 || value === -0.0f0)
        @testset "$target_type small value $(repr(value))" begin
            for vector in (false, true)
                initial = vector ? StaticArrays.SVector(one(target_type), one(target_type)) : one(target_type)
                evaluated = vector ? StaticArrays.SVector(1.0f0, value) : value
                expected = vector ? StaticArrays.SVector(one(target_type), zero(target_type)) : zero(target_type)
                test_lifecycle_value_conversion(
                    engine; adapt_to, invalid, initial_values = (initial, false),
                    values = (evaluated, 1.0f0), expected_values = (expected, true),
                )
            end
        end
    end
    return
end

function test_numeric_lifecycle_values(engine; adapt_to = identity)
    scalar_initial = (Int32(1), false)
    scalar_expected = (Int32(2), true)
    vector_initial = (StaticArrays.SVector(Int32(1), Int32(2)), StaticArrays.SVector(false, true))
    vector_expected = (StaticArrays.SVector(Int32(2), Int32(3)), StaticArrays.SVector(true, false))
    cases = (
        ("matched integer and Boolean", scalar_initial, scalar_expected, scalar_expected, false),
        ("exact floating conversions", scalar_initial, (2.0f0, 1.0f0), scalar_expected, false),
        ("exact floating Boolean false", scalar_initial, (2.0f0, 0.0f0), (Int32(2), false), false),
        ("integer lower bound", scalar_initial, (Float32(-2^31), 1.0f0), (typemin(Int32), true), false),
        (
            "last representable integer below upper bound", scalar_initial,
            (prevfloat(Float32(2^31)), 1.0f0), (Int32(2147483520), true), false,
        ),
        ("fractional integer", scalar_initial, (2.5f0, 1.0f0), scalar_expected, true),
        ("integer below lower bound", scalar_initial, (prevfloat(Float32(-2^31)), 1.0f0), scalar_expected, true),
        ("integer upper bound", scalar_initial, (Float32(2^31), 1.0f0), scalar_expected, true),
        ("integer infinity", scalar_initial, (Inf32, 1.0f0), scalar_expected, true),
        ("late Boolean range", scalar_initial, (2.0f0, 2.0f0), scalar_expected, true),
        ("late negative Boolean", scalar_initial, (2.0f0, -1.0f0), scalar_expected, true),
        ("late Boolean NaN", scalar_initial, (2.0f0, NaN32), scalar_expected, true),
        (
            "exact fixed-vector leaves", vector_initial,
            (StaticArrays.SVector(2.0f0, 3.0f0), StaticArrays.SVector(1.0f0, 0.0f0)), vector_expected, false,
        ),
        (
            "fractional fixed-vector integer leaf", vector_initial,
            (StaticArrays.SVector(2.0f0, 3.5f0), StaticArrays.SVector(1.0f0, 0.0f0)), vector_expected, true,
        ),
        (
            "fixed-vector integer upper bound", vector_initial,
            (StaticArrays.SVector(2.0f0, Float32(2^31)), StaticArrays.SVector(1.0f0, 0.0f0)), vector_expected, true,
        ),
        (
            "late fixed-vector Boolean range", vector_initial,
            (StaticArrays.SVector(2.0f0, 3.0f0), StaticArrays.SVector(1.0f0, 2.0f0)), vector_expected, true,
        ),
        (
            "late fixed-vector Boolean NaN", vector_initial,
            (StaticArrays.SVector(2.0f0, 3.0f0), StaticArrays.SVector(1.0f0, NaN32)), vector_expected, true,
        ),
    )
    for (name, initial_values, values, expected_values, invalid) in cases
        @testset "$name" begin
            # Scalar nonfinite evaluator results fail before logical conversion;
            # invalid vector components reach the declared-value conversion owner.
            expected_detail = any(value -> value isa AbstractFloat && !isfinite(value), values) ?
                CorePotts.LifecycleDetailNonfiniteResult : CorePotts.LifecycleDetailStateValueInvalid
            test_lifecycle_value_conversion(
                engine; adapt_to, values, invalid, initial_values, expected_values, expected_detail,
            )
        end
    end
    return
end
