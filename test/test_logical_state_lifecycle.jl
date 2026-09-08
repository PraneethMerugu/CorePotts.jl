using Test
import CorePotts
import StaticArrays: SVector

function _logical_lifecycle_runtime(last_value)
    initial_value = (active = true, count = Int32(2), polarity = SVector(1.0f0, 2.0f0))
    first_value = (active = false, count = Int32(7), polarity = SVector(3.0f0, 4.0f0))
    schemas = map((:first_signal, :second_signal)) do name
        CorePotts.StateBlockSchema(
            CorePotts.QualifiedResourceIdentity((), name), v"1.0.0", :cell,
            typeof(initial_value), (1,), 1, :structure_of_arrays,
            :provided_or_zero, :shape_and_finite, :logical, :declared,
            :declared, :bounded_write, :adapt_storage, :copy, :logical_copy,
            :qualified, true,
        )
    end
    layout = CorePotts.StateLayout(collect(schemas))
    handles = map(entry -> entry.handle, layout.entries)
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (), layout, CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]),
        (), Any[:logical_state_transition], 1, "logical-state-transition",
        CorePotts.HamiltonianDomainResources(0, 0),
    )
    descriptor = CorePotts.LifecycleDescriptor{2, Float32}(
        1, 0x61, 0x62, CorePotts.CellKindLifecycleDomain, 2,
        1, CorePotts.EveryMCSLifecycleCadence, 1, CorePotts.TransitionCellLifecycleEffect, 0,
        CorePotts.ErrorLifecycleInadmissible, 3, 1, CorePotts.NoLifecyclePlacement, 0,
        1, 0, 0, 0, CorePotts.NoLifecyclePartition,
        0, false, (0.0f0, 0.0f0), (0.0f0, 0.0f0), CorePotts.CanonicalLifecycleSide,
        0, 0, 0, 0, 1,
        2, 1, 0, 0, 0,
        0, 0, false,
    )
    evaluators = CorePotts.LifecycleEvaluatorStorage(
        Any[
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)),
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(first_value)),
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(last_value)),
        ],
        [:lifecycle_trigger, :lifecycle_state_transform, :lifecycle_state_transform],
    )
    rules = map(enumerate(handles)) do (index, handle)
        CorePotts.LifecycleStateRule(
            handle, UInt64(index), CorePotts.TransformLifecycleState,
            Int32(index + 1), Int32(0), Int32(0), Int32(0), 0.5f0,
            CorePotts.ExactLifecycleRounding, UInt8(0), UInt8(0), UInt16(0), UInt16(0),
        )
    end
    lifecycle_plan = CorePotts.LifecycleExecutionPlan(
        [descriptor], evaluators, CorePotts.LifecycleStateRuleStorage(rules),
        CorePotts.LifecycleRelationshipRule[], (), NTuple{2, Int16}[],
        CorePotts.LifecycleRelationStorage((), Val(2)),
        CorePotts.StablePriorityLifecycleConflicts, 1, 1, 1, 0, falses(3),
    )
    program = CorePotts.CompiledPottsProgram(
        (2, 2), (false, false), zeros(Int8, 2, 1), 3, 1,
        CorePotts.CompiledScalar(0.0f0), 1, Float32[], (),
        CorePotts.TrackerExecutionPlan((CorePotts.OwnershipCountTracker(),), "logical-state-count"),
        descriptor_plan, CorePotts.StageExecutionPlan(),
        CorePotts.SequentialProgramEngine(), CorePotts.CPUProgramBackend(),
        "logical-state-lifecycle"; lifecycle_plan,
    )
    initial = CorePotts.ProgramInitialState(
        ones(Int32, 2, 2), Int16[2]; scalar_type = Float32,
        descriptor_state = CorePotts.allocate_auxiliary_state(
            layout, ([initial_value], [initial_value]),
        ),
    )
    runtime = CorePotts.initialize_program(program, initial, Float32[], UInt64(0x6101), UInt32(1))
    return runtime, handles, first_value
end

@testset "structured lifecycle transforms publish together or roll back" begin
    finite_value = (active = true, count = Int32(9), polarity = SVector(5.0f0, 6.0f0))
    runtime, handles, first_value = _logical_lifecycle_runtime(finite_value)
    CorePotts.advance_mcs!(runtime)
    @test !CorePotts.program_failed(runtime)
    after = CorePotts.program_snapshot(runtime)
    @test after.mcs == 1
    @test after.cell_kinds == Int16[3]
    @test only(CorePotts.state_block(after.descriptor_state, handles[1]).values) == first_value
    @test only(CorePotts.state_block(after.descriptor_state, handles[2]).values) == finite_value
    @test length(CorePotts.program_lifecycle_receipt(runtime)) == 1

    for nonfinite in (NaN32, Inf32)
        invalid_value = (active = true, count = Int32(9), polarity = SVector(5.0f0, nonfinite))
        failed, failed_handles, _ = _logical_lifecycle_runtime(invalid_value)
        before = CorePotts.program_snapshot(failed)
        # The first transform writes a valid value into staged storage before
        # the second fails; neither that write nor the kind transition may publish.
        CorePotts.advance_mcs!(failed)
        @test CorePotts.program_failed(failed)
        failure = CorePotts.program_failure_report(failed)
        @test failure.code === CorePotts.ProgramStatusEvaluator
        @test failure.detail === CorePotts.LifecycleDetailStateValueInvalid
        @test failed.settled
        after = CorePotts.program_snapshot(failed)
        @test after.mcs == before.mcs == 0
        @test after.ownership == before.ownership
        @test after.cell_kinds == before.cell_kinds
        @test after.cell_generations == before.cell_generations
        @test after.trackers.values == before.trackers.values
        for handle in failed_handles
            @test CorePotts.state_block(after.descriptor_state, handle).values ==
                CorePotts.state_block(before.descriptor_state, handle).values
        end
        @test CorePotts.program_lifecycle_receipt(failed) === nothing
    end
end
