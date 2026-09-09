include("fixtures/scheduled_draw_support.jl")

@testset "addressed distribution transforms preserve their coordinates" begin
    namespace = CorePotts.RNGNamespace((UInt64(0x91), UInt64(0x73)))
    operation = only(CorePotts.rng_operation_keys(((; namespace, identity = "distribution transform"),)))
    trajectory = (UInt64(0x1348957100000001), UInt64(0x0000007800000009))
    contract = CorePotts.Philox4x64x10V3()
    for T in (Float32, Float64), stream in (
                CorePotts.ExplicitProposalDrawStream, CorePotts.LifecycleStateStream,
                CorePotts.ScheduledProcessDrawStream,
            )
        address = CorePotts.RNGAddress(;
            stream, operation, mcs = 17, entity_kind = CorePotts.CellEntity,
            entity = 3, generation = 9, invocation = 2,
        )
        second_address = CorePotts.RNGAddress(;
            stream, operation, mcs = 17, entity_kind = CorePotts.CellEntity,
            entity = 3, generation = 9, invocation = 2, draw = 1,
        )
        first_uniform = CorePotts.uniform_open01(T, contract, trajectory, address)
        second_uniform = CorePotts.uniform_open01(T, contract, trajectory, second_address)
        @test CorePotts._addressed_draw(T, (Val(1), zero(T), zero(T), operation), trajectory, address) === false
        @test CorePotts._addressed_draw(T, (Val(1), one(T), zero(T), operation), trajectory, address) === true
        @test CorePotts._addressed_draw(T, (Val(1), T(0.4), zero(T), operation), trajectory, address) === (first_uniform < T(0.4))
        @test CorePotts._addressed_draw(T, (Val(2), -T(2), T(3), operation), trajectory, address) === muladd(first_uniform, T(5), -T(2))
        @test CorePotts._addressed_draw(T, (Val(3), T(7), zero(T), operation), trajectory, address) === T(7)
        expected = muladd(T(0.5), sqrt(-T(2) * log(first_uniform)) * cos(T(2pi) * second_uniform), -T(2))
        @test CorePotts._addressed_draw(T, (Val(3), -T(2), T(0.5), operation), trajectory, address) === expected
        @test @inferred(CorePotts._addressed_draw(T, (Val(1), T(0.4), zero(T), operation), trajectory, address)) isa Bool
        @test @inferred(CorePotts._addressed_draw(T, (Val(3), -T(2), T(0.5), operation), trajectory, address)) isa T
    end
end

@testset "scheduled draws survive reordering and checkpoint continuation" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        runtime, handles, _ = scheduled_draw_runtime(engine)
        reordered, _, _ = scheduled_draw_runtime(engine; reverse_order = true)
        CorePotts.advance_mcs!(runtime)
        CorePotts.advance_mcs!(reordered)
        restored = CorePotts.restore_program_checkpoint(runtime.program, CorePotts.program_checkpoint(runtime))
        for current in (runtime, reordered, restored)
            CorePotts.advance_mcs!(current)
            @test !CorePotts.program_failed(current)
            @test CorePotts.program_snapshot(current).mcs == 2
        end
        expected = CorePotts.program_snapshot(runtime)
        for current in (reordered, restored), handle in handles
            @test CorePotts.state_block(CorePotts.program_snapshot(current).descriptor_state, handle).values ==
                CorePotts.state_block(expected.descriptor_state, handle).values
        end
    end
end

@testset "late scheduled draw failure rolls back and checkpoint retry reuses addresses" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        runtime, handles, _ = scheduled_draw_runtime(engine; failure = true)
        before = CorePotts.program_snapshot(runtime)
        checkpoint = CorePotts.program_checkpoint(runtime)
        if engine isa CorePotts.SequentialProgramEngine
            @test_throws DomainError CorePotts.advance_mcs!(runtime)
        else
            CorePotts.advance_mcs!(runtime)
            @test CorePotts.program_failed(runtime)
        end
        after = CorePotts.program_snapshot(runtime)
        @test runtime.settled
        @test after.mcs == before.mcs == 0
        @test after.ownership == before.ownership
        @test after.cell_kinds == before.cell_kinds
        @test after.cell_generations == before.cell_generations
        @test after.trackers.values == before.trackers.values
        for handle in handles
            @test CorePotts.state_block(after.descriptor_state, handle).values ==
                CorePotts.state_block(before.descriptor_state, handle).values
        end
        # Retry starts from the saved scientific boundary, not a repaired failed status.
        retry = CorePotts.restore_program_checkpoint(runtime.program, checkpoint)
        CorePotts.update_program_parameters!(retry, Float32[1])
        reference, _, _ = scheduled_draw_runtime(engine)
        for current in (retry, reference)
            CorePotts.advance_mcs!(current)
            @test !CorePotts.program_failed(current)
            @test CorePotts.program_snapshot(current).mcs == 1
        end
        expected = CorePotts.program_snapshot(reference)
        retried = CorePotts.program_snapshot(retry)
        @test retried.ownership == expected.ownership
        @test retried.cell_generations == expected.cell_generations
        for handle in handles
            @test CorePotts.state_block(retried.descriptor_state, handle).values ==
                CorePotts.state_block(expected.descriptor_state, handle).values
        end
    end
end

isdefined(@__MODULE__, :CellStageIncrement) || include("fixtures/cell_stage_support.jl")
isdefined(@__MODULE__, :cell_stage_lifecycle_runtime) || include("fixtures/cell_stage_lifecycle_support.jl")

@testset "scheduled cell draws address reused lifecycle generations" begin
    namespace = CorePotts.RNGNamespace((UInt64(0x0719), UInt64(0x0333)))
    keys = CorePotts.rng_operation_keys(Tuple((; namespace, identity) for identity in ("before", "after")))
    function descriptor_factory(target, source, slot; increment, source_handle)
        draw = CorePotts.OperationExpression(
            CorePotts.operation_callable(Val(:draw), v"1.0.0"),
            CorePotts.LiteralExpression(2), CorePotts.LiteralExpression(0.0f0),
            CorePotts.LiteralExpression(1.0f0), CorePotts.LiteralExpression(keys[slot]),
        )
        return CorePotts.CompiledStageDescriptor(
            CorePotts.StaticEvaluator(CorePotts.LiteralExpression(true)), CorePotts.StaticEvaluator(draw),
            CorePotts.CellAssignmentEffect(target, 2), CorePotts.AfterMCSStage(),
            CorePotts.ResourceAccess((), (target,), CorePotts.EmptyFootprint(), CorePotts.OwnerFootprint(), CorePotts.ExclusiveWriteAccess()),
            CorePotts.DescriptorSupport(true, true, true, true), source_handle, slot,
        )
    end
    function expected_draw(mcs, entity, generation)
        address = CorePotts.RNGAddress(
            stream = CorePotts.ScheduledProcessDrawStream, operation = keys[2], mcs = mcs,
            subround = 1, entity_kind = CorePotts.CellEntity, entity = entity, generation = generation,
        )
        trajectory = (UInt64(0xc318), UInt64(1) | (UInt64(1) << 32))
        return CorePotts.uniform_open01(Float32, CorePotts.Philox4x64x10V3(), trajectory, address)
    end
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        runtime, handle = cell_stage_lifecycle_runtime(engine; descriptor_factory)
        CorePotts.advance_mcs!(runtime)
        removed = CorePotts.program_snapshot(runtime)
        @test !CorePotts.program_failed(runtime)
        @test removed.cell_kinds == Int16[2, 0]
        @test CorePotts.state_block(removed.descriptor_state, handle).values[1] == expected_draw(1, 1, removed.cell_generations[1])
        @test count(event -> event isa CorePotts.RemoveCellLifecycleEvent, CorePotts.program_lifecycle_receipt(runtime)) == 1
        restored = CorePotts.restore_program_checkpoint(runtime.program, CorePotts.program_checkpoint(runtime))
        for current in (runtime, restored)
            CorePotts.advance_mcs!(current)
            created = CorePotts.program_snapshot(current)
            @test !CorePotts.program_failed(current)
            @test created.mcs == 2
            @test created.cell_kinds == Int16[2, 2]
            @test created.cell_generations[2] == removed.cell_generations[2] + UInt32(1)
            values = CorePotts.state_block(created.descriptor_state, handle).values
            @test values[1:2] == Float32[expected_draw(2, cell, created.cell_generations[cell]) for cell in 1:2]
            @test values[3:6] == ones(Float32, 4)
            @test values[2] != expected_draw(2, 2, removed.cell_generations[2])
            @test count(event -> event isa CorePotts.CreateLifecycleEvent, CorePotts.program_lifecycle_receipt(current)) == 1
        end
    end
end

@testset "scheduled draws use scientific entities and fresh substeps" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        runtime, handles, keys = scheduled_draw_runtime(engine)
        initial = CorePotts.program_snapshot(runtime)
        iterated_expected = zeros(Float32, 6, 6)
        for mcs in 1:2
            CorePotts.advance_mcs!(runtime)
            snapshot = CorePotts.program_snapshot(runtime)
            @test !CorePotts.program_failed(runtime)
            @test snapshot.mcs == mcs
            @test snapshot.ownership == initial.ownership
            @test only(CorePotts.state_block(snapshot.descriptor_state, handles[1]).values) == scheduled_uniform(keys[1], mcs, CorePotts.ModelEntity, 0)
            @test CorePotts.state_block(snapshot.descriptor_state, handles[2]).values == Float32[
                scheduled_uniform(keys[2], mcs, CorePotts.CellEntity, 1; generation = 7),
                scheduled_uniform(keys[2], mcs, CorePotts.CellEntity, 2; generation = 11), -1, -1,
            ]
            expected_sites = reshape(Float32[scheduled_uniform(keys[3], mcs, CorePotts.SiteEntity, site) for site in 1:36], 6, 6)
            @test CorePotts.state_block(snapshot.descriptor_state, handles[3]).values == expected_sites
            for invocation in 0:2, site in 1:36
                iterated_expected[site] += scheduled_uniform(keys[4], mcs, CorePotts.SiteEntity, site; invocation, after_lifecycle = true)
            end
            @test CorePotts.state_block(snapshot.descriptor_state, handles[4]).values == iterated_expected
        end
    end
end
