isdefined(@__MODULE__, :test_program) || include("fixtures/compiled_program_support.jl")
include("fixtures/site_sum_support.jl")
import LocalMath
import StaticArrays: SMatrix, SVector

function test_site_sum_numerical_rejection(f)
    failure = try
        f()
        nothing
    catch exception
        exception
    end
    @test failure isa LocalMath.LocalMathValidationError
    @test occursin("contract: :runtime_stage_validation", sprint(showerror, failure))
    return nothing
end

@testset "structured site sums preserve value shape across publication" begin
    C = CorePotts
    for value in (
                SVector(1.0f0, -2.0f0),
                SMatrix{2, 2}(1.0f0, -2.0f0, 3.0f0, 4.0f0),
            ), engine in (C.SequentialProgramEngine(), C.CheckerboardProgramEngine())
        signal = fill(value, 6, 6)
        runtime, handle, key = site_sum_runtime(engine; signal)
        expected = site_sum_oracle(
            runtime.ownership, signal, 2.0f0, length(runtime.cell_kinds)
        )
        @test C.program_tracker_values(runtime, key) == expected
        @test eltype(C.program_tracker_values(runtime, key)) === typeof(value)

        state = C.copy_auxiliary_state(runtime.descriptor_state)
        replacement = fill(3.0f0 .* value, 6, 6)
        C.state_block(state, handle).values .= replacement
        C.update_program_inputs!(
            runtime; parameters = Float32[-0.5], descriptor_state = state
        )
        expected = site_sum_oracle(
            runtime.ownership, replacement, -0.5f0, length(runtime.cell_kinds)
        )
        @test C.program_tracker_values(runtime, key) == expected

        descriptor = runtime.program.tracker_plan.descriptors[2]
        converted = typeof(descriptor)(
            descriptor.quantity, descriptor.expression, 0.25, 0.5
        )
        @test converted.absolute_tolerance === 0.25f0
        @test converted.relative_tolerance === 0.5f0
        descriptor_type = typeof(descriptor)
        value_type, quantity_type, expression_type, _ =
            descriptor_type.parameters
        @test_throws ArgumentError C.SiteSumTracker{
            value_type, quantity_type, expression_type, Float64,
        }(descriptor.quantity, descriptor.expression, 0.25, 0.5)

        before_failure = C.program_snapshot(runtime)
        before_parameters = copy(runtime.parameters)
        invalid_state = C.copy_auxiliary_state(runtime.descriptor_state)
        invalid_values = C.state_block(invalid_state, handle).values
        invalid_values[1] = Base.setindex(
            invalid_values[1], floatmax(Float32), 1
        )
        test_site_sum_numerical_rejection() do
            C.update_program_inputs!(
                runtime;
                parameters = Float32[2], descriptor_state = invalid_state,
            )
        end
        @test runtime.parameters == before_parameters
        @test C.program_tracker_values(runtime, key) == expected
        @test C.state_block(runtime.descriptor_state, handle).values ==
            C.state_block(before_failure.descriptor_state, handle).values
        @test runtime.mcs == before_failure.mcs

        restored = C.restore_program_checkpoint(
            runtime.program, C.program_checkpoint(runtime)
        )
        for continued in (runtime, restored)
            C.advance_mcs!(continued)
            values = C.state_block(continued.descriptor_state, handle).values
            @test C.program_tracker_values(continued, key) == site_sum_oracle(
                continued.ownership, values, -0.5f0, length(continued.cell_kinds)
            )
        end
        @test C.program_snapshot(restored).trackers.values ==
            C.program_snapshot(runtime).trackers.values
        @test restored.ownership == runtime.ownership
    end
end

@testset "site sum initialization and combined input publication" begin
    runtime, handle, key = site_sum_runtime(CorePotts.SequentialProgramEngine())
    @test CorePotts.program_tracker_values(runtime, key) == Float32[4, 2, 0]
    snapshot = CorePotts.program_snapshot(runtime)
    state = CorePotts.copy_auxiliary_state(snapshot.descriptor_state)
    values = CorePotts.state_block(state, handle).values
    values .= 3.0f0
    CorePotts.update_program_inputs!(runtime; descriptor_state = state)
    @test CorePotts.program_tracker_values(runtime, key) == Float32[12, 6, 0]
    CorePotts.update_program_inputs!(runtime; parameters = Float32[4])
    @test CorePotts.program_tracker_values(runtime, key) == Float32[24, 12, 0]
    @test CorePotts.program_tracker_values(runtime, key) == site_sum_oracle(
        runtime.ownership, values, 4.0f0, length(runtime.cell_kinds)
    )

    # Each complete input pair is finite. Publishing the next gain by itself
    # would overflow against the old signal and incorrectly reject the pair.
    values .= 1.0f20
    CorePotts.update_program_inputs!(runtime; parameters = Float32[1.0f-20], descriptor_state = state)
    values .= 1.0f-20
    CorePotts.update_program_inputs!(runtime; parameters = Float32[1.0f20], descriptor_state = state)
    expected = site_sum_oracle(runtime.ownership, values, 1.0f20, length(runtime.cell_kinds))
    @test CorePotts.program_tracker_values(runtime, key) == expected
    before_failure = CorePotts.program_snapshot(runtime)
    before_parameters = copy(runtime.parameters)
    values .= 1.0f20
    test_site_sum_numerical_rejection() do
        CorePotts.update_program_inputs!(
            runtime;
            parameters = Float32[1.0f20], descriptor_state = state
        )
    end
    @test runtime.parameters == before_parameters
    @test CorePotts.program_tracker_values(runtime, key) == expected
    @test CorePotts.state_block(runtime.descriptor_state, handle).values ==
        CorePotts.state_block(before_failure.descriptor_state, handle).values
    @test runtime.mcs == 0
    @test CorePotts.state_block(snapshot.descriptor_state, handle).values == fill(1.0f0, 6, 6)

    values .= 2.0f0
    CorePotts.update_program_inputs!(runtime; parameters = Float32[3], descriptor_state = state)
    @test CorePotts.program_tracker_values(runtime, key) == Float32[12, 6, 0]
    restored = CorePotts.restore_program_checkpoint(runtime.program, CorePotts.program_checkpoint(runtime))
    for continued in (runtime, restored)
        CorePotts.update_program_inputs!(continued; parameters = Float32[5])
        @test CorePotts.program_tracker_values(continued, key) == Float32[20, 10, 0]
    end
end

@testset "grouped site sums retain independent scientific quantities" begin
    C = CorePotts
    second_key = C.QualifiedTrackerKey(Val(:site_sum), 2)
    factory = function (descriptor)
        # Value-level coefficients preserve the same descriptor type used by
        # the compiler's dense scalar grouping owner.
        first_expression = C.OperationExpression(*, C.LiteralExpression(1.0f0), descriptor.expression)
        second_expression = C.OperationExpression(*, C.LiteralExpression(2.0f0), descriptor.expression)
        first_descriptor = C.SiteSumTracker(Float32, descriptor.quantity, first_expression)
        second_descriptor = C.SiteSumTracker(Float32, second_key, second_expression)
        return (C.DenseScalarTrackerGroup([first_descriptor, second_descriptor]),)
    end
    runtime, handle, first_key = site_sum_runtime(C.SequentialProgramEngine(); tracker_descriptors = factory)
    @test C.program_tracker_values(runtime, first_key) == Float32[4, 2, 0]
    @test C.program_tracker_values(runtime, second_key) == Float32[8, 4, 0]
    state = C.copy_auxiliary_state(runtime.descriptor_state)
    values = C.state_block(state, handle).values
    values .= 3.0f0
    C.update_program_inputs!(runtime; parameters = Float32[4], descriptor_state = state)
    @test C.program_tracker_values(runtime, first_key) == Float32[24, 12, 0]
    @test C.program_tracker_values(runtime, second_key) == Float32[48, 24, 0]
    previous = C.program_snapshot(runtime)
    # The first quantity is finite; the later doubled quantity overflows.
    values .= floatmax(Float32) / 3.0f0
    test_site_sum_numerical_rejection() do
        C.update_program_inputs!(runtime; parameters = Float32[1], descriptor_state = state)
    end
    @test C.program_tracker_values(runtime, first_key) == Float32[24, 12, 0]
    @test C.program_tracker_values(runtime, second_key) == Float32[48, 24, 0]
    @test runtime.parameters == Float32[4]
    @test C.state_block(runtime.descriptor_state, handle).values == C.state_block(previous.descriptor_state, handle).values
end

@testset "source sums consume accepted clear and assignment results" begin
    C = CorePotts
    runtime, handle, key = site_sum_runtime(
        C.SequentialProgramEngine();
        stage_builder = site_sum_accepted_increment,
        lifecycle = (declared = :ClearOnOwnershipChange,)
    )
    # This is the same selected-proposal entry called by the production MCS
    # loop; choosing endpoints makes the independent numerical oracle exact.
    @test C._attempt_selected!(runtime, CartesianIndex(3, 1), CartesianIndex(1, 1), 1, 1, Val(:scripted), 0.5f0)
    values = C.state_block(runtime.descriptor_state, handle).values
    @test values[1, 1] == 8.0f0
    @test C.program_tracker_values(runtime, key) == Float32[2, 18, 0]
    @test C.program_tracker_values(runtime, key) == site_sum_oracle(runtime.ownership, values, 2.0f0, 3)
    before = C.program_snapshot(runtime)
    # Removing owner1's last site is a genuinely rejected proposal.
    @test !C._attempt_selected!(runtime, CartesianIndex(3, 1), CartesianIndex(2, 1), 2, 1, Val(:scripted), 0.5f0)
    @test runtime.constraint_rejections == 1
    @test runtime.ownership == before.ownership
    @test values == C.state_block(before.descriptor_state, handle).values
    @test C.program_tracker_values(runtime, key) == site_sum_oracle(runtime.ownership, values, 2.0f0, 3)
end

@testset "persisted source sums use declared comparison without repair" begin
    C = CorePotts
    small = 2.0f0^-25
    signal = zeros(Float32, 6, 6)
    signal[1] = 1.0f0
    signal[2] = small
    for tolerance in (0.0f0, small)
        runtime, handle, key = site_sum_runtime(
            C.SequentialProgramEngine();
            gain = 1.0f0, signal, absolute_tolerance = tolerance
        )
        @test C.program_tracker_value(runtime, key, 1) == 1.0f0
        @test C._attempt_selected!(runtime, CartesianIndex(3, 1), CartesianIndex(1, 1), 1, 1, Val(:scripted), 0.5f0)
        @test C.program_tracker_value(runtime, key, 1) == 0.0f0
        @test site_sum_oracle(runtime.ownership, signal, 1.0f0, 3)[1] == small
        if iszero(tolerance)
            @test_throws r"differs from its independent recomputation oracle" C.program_checkpoint(runtime)
        else
            checkpoint = C.program_checkpoint(runtime)
            restored = C.restore_program_checkpoint(runtime.program, checkpoint)
            @test C.program_tracker_value(restored, key, 1) == 0.0f0
            for continued in (runtime, restored)
                @test C._attempt_selected!(continued, CartesianIndex(2, 1), CartesianIndex(3, 1), 2, 1, Val(:scripted), 0.5f0)
                @test C.program_tracker_value(continued, key, 1) == 0.0f0
            end
            @test C.program_tracker_values(restored, key) == C.program_tracker_values(runtime, key)
            @test restored.ownership == runtime.ownership
        end
    end
    vector_signal = fill(zero(SVector{2, Float32}), 6, 6)
    vector_signal[1] = SVector(1.0f0, 1.0f0)
    vector_signal[2] = SVector(small, 2small)
    for tolerance in (small, 2small)
        vector_runtime, _, vector_key = site_sum_runtime(
            C.SequentialProgramEngine();
            gain = 1.0f0, signal = vector_signal,
            absolute_tolerance = tolerance
        )
        @test C._attempt_selected!(
            vector_runtime, CartesianIndex(3, 1), CartesianIndex(1, 1),
            1, 1, Val(:scripted), 0.5f0
        )
        @test C.program_tracker_value(vector_runtime, vector_key, 1) ==
            zero(SVector{2, Float32})
        expected = site_sum_oracle(
            vector_runtime.ownership, vector_signal, 1.0f0, 3
        )[1]
        @test expected == SVector(small, 2small)
        if tolerance == small
            @test_throws r"differs from its independent recomputation oracle" C.program_checkpoint(vector_runtime)
        else
            restored = C.restore_program_checkpoint(
                vector_runtime.program, C.program_checkpoint(vector_runtime)
            )
            @test C.program_tracker_value(restored, vector_key, 1) ==
                zero(SVector{2, Float32})
        end
    end
    runtime, _, _ = site_sum_runtime(C.SequentialProgramEngine())
    descriptor = runtime.program.tracker_plan.descriptors[2]
    source = C.tracker_source_view(
        runtime.program, runtime.ownership;
        parameters = runtime.parameters, descriptor_state = runtime.descriptor_state
    )
    @test C._source_dependent_tracker_ownership_delta(
        descriptor, source,
        CartesianIndex(1, 1), Int32(1), Int32(2)
    ).amount == 2.0f0
    for invalid in (-1.0f0, Inf32, NaN32)
        @test_throws ArgumentError C.SiteSumTracker(Float32, descriptor.quantity, descriptor.expression; absolute_tolerance = invalid)
        @test_throws ArgumentError C.SiteSumTracker(Float32, descriptor.quantity, descriptor.expression; relative_tolerance = invalid)
        @test_throws ArgumentError typeof(descriptor)(descriptor.quantity, descriptor.expression, invalid, 0.0f0)
        @test_throws ArgumentError typeof(descriptor)(descriptor.quantity, descriptor.expression, 0.0f0, invalid)
        @test_throws ArgumentError C.SiteSumTracker(descriptor.quantity, descriptor.expression, invalid, 0.0f0)
        @test_throws ArgumentError C.SiteSumTracker(descriptor.quantity, descriptor.expression, 0.0f0, invalid)
    end
    converted = typeof(descriptor)(descriptor.quantity, descriptor.expression, 0.25, 0.5)
    @test converted.absolute_tolerance === 0.25f0
    @test converted.relative_tolerance === 0.5f0
    inferred = C.SiteSumTracker(descriptor.quantity, descriptor.expression, 0.25f0, 0.5f0)
    @test inferred.absolute_tolerance === converted.absolute_tolerance
    @test inferred.relative_tolerance === converted.relative_tolerance
    @test_throws ArgumentError typeof(descriptor)(descriptor.quantity, descriptor.expression, floatmax(Float64), 0.0)
    relative = C.SiteSumTracker(Float32, descriptor.quantity, descriptor.expression; relative_tolerance = 1.5f0)
    @test !C._tracker_recomputation_matches(relative, Float32[3.0f38], Float32[-3.0f38])
    @test C._tracker_recomputation_matches(relative, Float32[3.0f38], Float32[1.0f38])
    wide = C.SiteSumTracker(Float32, descriptor.quantity, descriptor.expression; relative_tolerance = 2.0f0)
    @test C._tracker_recomputation_matches(wide, Float32[3.0f38], Float32[-3.0f38])
    absolute = C.SiteSumTracker(Float32, descriptor.quantity, descriptor.expression; absolute_tolerance = floatmax(Float32))
    @test !C._tracker_recomputation_matches(absolute, Float32[3.0f38], Float32[-3.0f38])
    @test !C._tracker_recomputation_matches(relative, Float32[Inf], Float32[Inf])
end

@testset "late nonfinite source sum rolls back the whole MCS" begin
    C = CorePotts
    runtime, handle, key = site_sum_runtime(
        C.SequentialProgramEngine(); gain = 1.0f0, attempts_per_site = 20,
        stage_builder = handle -> site_sum_accepted_increment(handle; increment = floatmax(Float32) / 2.0f0)
    )
    before = C.program_snapshot(runtime)
    # Any first accepted assignment and owner sum are finite. Further accepted
    # copies accumulate large signals until the derived sum becomes invalid.
    @test_throws r"tracker ownership update produced a nonfinite value" C.advance_mcs!(runtime)
    after = C.program_snapshot(runtime)
    @test after.mcs == before.mcs == 0
    @test after.ownership == before.ownership
    @test after.cell_kinds == before.cell_kinds
    @test after.trackers.values == before.trackers.values
    @test C.state_block(after.descriptor_state, handle).values == C.state_block(before.descriptor_state, handle).values
    @test runtime.accepted == 0
    @test C.program_tracker_values(runtime, key) == site_sum_oracle(
        after.ownership,
        C.state_block(after.descriptor_state, handle).values, 1.0f0, 3
    )
end

@testset "checkerboard source sums read completed accepted shadows" begin
    C = CorePotts
    runtime, handle, key = site_sum_runtime(
        C.CheckerboardProgramEngine();
        stage_builder = site_sum_accepted_increment,
        lifecycle = (declared = :ClearOnOwnershipChange,),
        tracker_descriptors = descriptor -> (C.DenseScalarTrackerGroup([descriptor]),)
    )
    C.advance_mcs!(runtime)
    @test !C.program_failed(runtime)
    @test runtime.accepted > 0
    first = C.program_snapshot(runtime)
    values = C.state_block(first.descriptor_state, handle).values
    @test any(>(1.0f0), values)
    @test all(value -> iszero(mod(value - 1.0f0, 7.0f0)), values)
    @test C.program_tracker_values(runtime, key) == site_sum_oracle(first.ownership, values, 2.0f0, 3)
    restored = C.restore_program_checkpoint(runtime.program, C.program_checkpoint(runtime))
    for continued in (runtime, restored)
        C.advance_mcs!(continued)
        @test !C.program_failed(continued)
        snapshot = C.program_snapshot(continued)
        @test snapshot.mcs == 2
        @test C.program_tracker_values(continued, key) == site_sum_oracle(
            snapshot.ownership,
            C.state_block(snapshot.descriptor_state, handle).values, 2.0f0, 3
        )
    end
    @test restored.ownership == runtime.ownership
    @test C.state_block(restored.descriptor_state, handle).values == C.state_block(runtime.descriptor_state, handle).values
    @test C.program_tracker_values(restored, key) == C.program_tracker_values(runtime, key)
end
@testset "shared source sums and exact site counts feed cell stages" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        @testset "$(nameof(typeof(engine)))" begin
            runtime, handles, key = site_sum_cell_read_runtime(engine)
            labels = copy(runtime.ownership)
            CorePotts.advance_mcs!(runtime)
            @test CorePotts.state_block(runtime.descriptor_state, handles[2]).values == Float32[4, 2, 0]
            @test CorePotts.state_block(runtime.descriptor_state, handles[3]).values == Float32[4, 2, 0]
            @test CorePotts.state_block(runtime.descriptor_state, handles[4]).values == Int32[2, 1, 0]
            source = CorePotts.program_snapshot(runtime).descriptor_state
            fill!(CorePotts.state_block(source, handles[1]).values, 3.0f0)
            CorePotts.update_program_inputs!(runtime; parameters = Float32[4], descriptor_state = source)
            @test CorePotts.program_tracker_values(runtime, key) == Float32[24, 12, 0]
            CorePotts.advance_mcs!(runtime)
            @test CorePotts.state_block(runtime.descriptor_state, handles[2]).values == Float32[24, 12, 0]
            @test CorePotts.state_block(runtime.descriptor_state, handles[3]).values == Float32[24, 12, 0]
            @test CorePotts.state_block(runtime.descriptor_state, handles[4]).values == Int32[2, 1, 0]
            @test runtime.ownership == labels
            @test_throws ArgumentError site_sum_cell_read_runtime(engine; owner_expression = CorePotts.LiteralExpression(Int32(1)))
        end
    end
end
