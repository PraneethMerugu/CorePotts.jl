using Test
import CorePotts
import LocalMath
include("fixtures/site_minimum_support.jl")

struct UnsupportedFullReconstructionTracker <: CorePotts.AbstractTrackerDescriptor end

CorePotts.tracker_contract(::UnsupportedFullReconstructionTracker) =
    CorePotts.TrackerContract(
        Val(:unsupported_full_reconstruction),
        CorePotts.OwnershipTrackerSource(),
        CorePotts.DenseOwnerScalarStorage{Float32}(),
        CorePotts.AcceptedCommitTrackerVisibility(),
        CorePotts.ClaimedOwnerExclusiveTrackerConcurrency(),
        CorePotts.FullLatticeReconstructionUpdateBound(1),
        CorePotts.PersistTrackerCheckpoint(),
        CorePotts.TrackerSupport(true, true, true, true),
        CorePotts.LatticeLinearTrackerCost(),
        CorePotts.LatticeLinearTrackerCost(),
    )

@testset "bounded minimum declaration and admission" begin
    C = CorePotts
    key = C.QualifiedTrackerKey(Val(:site_minimum), 1)
    expression = C.LiteralExpression(1.0f0)
    for value in (false, true)
        @test_throws ArgumentError C.SiteMinimumTracker(Float32, key, expression; maximum_sites = value, empty = 0.0f0)
        @test_throws ArgumentError C.FullLatticeReconstructionUpdateBound(value)
    end
    @test_throws ArgumentError C.SiteMinimumTracker(Float32, key, expression; maximum_sites = -1, empty = 0.0f0)
    @test_throws ArgumentError C.SiteMinimumTracker(Float32, key, expression; maximum_sites = big(typemax(Int32)) + 1, empty = 0.0f0)
    @test_throws ArgumentError C.SiteMinimumTracker(Float32, key, expression; maximum_sites = 36, empty = Inf32)
    @test_throws UndefKeywordError C.SiteMinimumTracker(Float32, key, expression; maximum_sites = 36)
    @test_throws ArgumentError site_minimum_runtime(C.SequentialProgramEngine(); maximum_sites = 35)
    descriptor = C.SiteMinimumTracker(Float32, key, expression; maximum_sites = 36, empty = -7.0f0)
    inspection = C.tracker_inspection(descriptor)
    @test inspection.maximum_sites == 36
    @test inspection.empty === -7.0f0
    @test inspection.maintenance === :bounded_lattice_reconstruction
    @test C.tracker_contract(descriptor).update_bound isa C.FullLatticeReconstructionUpdateBound
    @test_throws r"currently owned by SiteMinimumTracker" C._validate_tracker_descriptor(
        UnsupportedFullReconstructionTracker()
    )
    @test_throws ArgumentError C.FullLatticeReconstructionUpdateBound(-1)
    for engine in (C.SequentialProgramEngine(), C.CheckerboardProgramEngine())
        minimum_read = C.OperationExpression(
            C.QualifiedTrackerOperation(
                C.operation_callable(Val(:cell_site_minimum), v"1.0.0"), key.quantity, key.source_handle
            ),
            C.ContextExpression(C.operation_callable(Val(:target_cell), v"1.0.0"))
        )
        @test_throws ArgumentError site_minimum_runtime(
            engine;
            constraint = C.OperationExpression(>, minimum_read, C.LiteralExpression(0.0f0))
        )
    end
    runtime, _, _ = site_minimum_runtime(C.SequentialProgramEngine())
    source = C.tracker_source_view(
        runtime.program, runtime.ownership;
        parameters = runtime.parameters, descriptor_state = runtime.descriptor_state
    )
    minimum_descriptor = runtime.program.tracker_plan.descriptors[2]
    bounded_descriptor = C.SiteMinimumTracker(
        Float32, key, minimum_descriptor.expression; maximum_sites = 35, empty = 19.0f0
    )
    @test_throws ArgumentError C.tracker_rebuild(bounded_descriptor, source, Int16[2, 2, 0, 0])
    # This unpublished source exercises zero-area reconstruction without
    # relaxing the program's independent initialization invariant.
    @test C.tracker_rebuild(minimum_descriptor, source, Int16[2, 2, 2, 0]) == Float32[1, 1, 19, 19]
    @test C.tracker_recompute(minimum_descriptor, source, Int16[2, 2, 2, 0]) == Float32[1, 1, 19, 19]
    checkpoint = C.program_checkpoint(runtime)
    checkpoint.snapshot.trackers.values[2][1] += 1.0f0
    @test_throws r"checksum" C.restore_program_checkpoint(runtime.program, checkpoint)
    @test C.program_tracker_values(runtime, key) == Float32[1, 1, 19, 19]
    cached = C.tracker_values(runtime.program.tracker_plan, runtime.trackers, key)
    cached[1] = 2.0f0
    @test_throws r"differs from its independent recomputation oracle" C.program_checkpoint(runtime)
    cached[1] = 1.0f0
end

@testset "minimum physical history invalidation" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        test_site_minimum_history(engine)
    end
end

@testset "scheduled minimum rebuild is shared by two cell consumers" begin
    C = CorePotts
    for engine in (C.SequentialProgramEngine(), C.CheckerboardProgramEngine())
        test_site_minimum_scheduled(engine)
    end
end

@testset "late invalid minimum rebuild rolls back source publication" begin
    C = CorePotts
    for engine in (C.SequentialProgramEngine(), C.CheckerboardProgramEngine())
        stages = handle -> begin
            groups = map(enumerate((2.0f0, floatmax(Float32)))) do (slot, value)
                descriptor = scheduled_site_sum_assignment(handle; value = _ -> C.LiteralExpression(value))
                C.StageDescriptorGroup(
                    [
                        C.CompiledStageDescriptor(
                            descriptor.condition, descriptor.value,
                            descriptor.effect, descriptor.stage, descriptor.access, descriptor.support, descriptor.source_handle, slot
                        ),
                    ]
                )
            end
            C.StageExecutionPlan((), Tuple(groups), (), 0, 2, "minimum-source-rollback")
        end
        runtime, handle, key = site_minimum_runtime(
            engine; gain = 2.0f0, stage_builder = stages,
            constraint = C.LiteralExpression(false)
        )
        before = C.program_snapshot(runtime)
        failure = try
            C.advance_mcs!(runtime)
            nothing
        catch error
            error
        end
        @test failure isa Union{LocalMath.LocalMathValidationError, C.LifecycleBackendFailure}
        @test occursin("runtime_stage_validation", sprint(showerror, failure))
        @test runtime.mcs == before.mcs
        @test runtime.ownership == before.ownership
        @test runtime.trackers.values == before.trackers.values
        @test C.state_block(runtime.descriptor_state, handle).values == C.state_block(before.descriptor_state, handle).values
    end
end

@testset "minimum removal and continuation on both CPU engines" begin
    for engine in (CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine())
        test_site_minimum_empty_value(engine)
        test_site_minimum_removal(engine)
        test_site_minimum_inputs(engine)
    end
end

@testset "minimum source stages publish rebuilt values" begin
    C = CorePotts
    for engine in (C.SequentialProgramEngine(), C.CheckerboardProgramEngine())
        test_site_minimum_accepted_sources(engine)
        runtime, _, key = site_minimum_runtime(engine)
        source = C.tracker_source_view(
            runtime.program, runtime.ownership;
            parameters = runtime.parameters, descriptor_state = runtime.descriptor_state
        )
        @test_throws ArgumentError C.tracker_value_after(
            runtime.program.tracker_plan, runtime.trackers,
            source, key, Int32(1), CartesianIndex(1, 1), Int32(1), Int32(2)
        )
    end
end
