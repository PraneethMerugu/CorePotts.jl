using StaticArrays
using Test
import CorePotts
import Metal

isdefined(@__MODULE__, :test_program) ||
    include(joinpath(@__DIR__, "..", "fixtures", "compiled_program_support.jl"))
isdefined(@__MODULE__, :site_sum_runtime) ||
    include(joinpath(@__DIR__, "..", "fixtures", "site_sum_support.jl"))

function structured_sum_snapshot_matches(runtime, handle, key, gain)
    C = CorePotts
    snapshot = C.program_snapshot(runtime)
    signal = C.state_block(snapshot.descriptor_state, handle).values
    @test C.program_tracker_values(runtime.program, snapshot, key) ==
        site_sum_oracle(snapshot.ownership, signal, gain, length(snapshot.cell_kinds))
    return snapshot
end

@testset "generation-qualified relation pairs on Metal" begin
    Metal.functional() || error("relation pairs require functional Metal")
    Metal.allowscalar(false)
    offsets = Int8[1 -1 0 0; 0 0 1 -1]
    resources = CorePotts.HamiltonianDomainResources(
        offsets, Float32[0.5, 0.5, 1.5, 1.5],
        Int32[1], Int32[4], Int32[0])
    descriptor_plan = CorePotts.DescriptorExecutionPlan(
        (), CorePotts.StateLayout(CorePotts.StateBlockSchema[]),
        CorePotts.WorkspaceLayout(CorePotts.WorkspaceSchema[]), (), Any[],
        Int32(0), "metal-relation-pair-descriptor-plan-v1", resources)
    key = CorePotts.QualifiedTrackerKey(Val(:spatial_relation_query), 1)
    pair = CorePotts.CompilerSPI.SpatialRelationQueryTracker(
        key, 1; maximum_pairs = 8, maximum_contacts = 144,
        maximum_sites = 36)
    tracker_plan = CorePotts.TrackerExecutionPlan(
        (CorePotts.OwnershipCountTracker(), pair),
        "metal-relation-pair-tracker-plan-v1")
    program = test_program(
        CorePotts.CheckerboardProgramEngine(); descriptor_plan, tracker_plan,
        scalar_type = Float32,
        backend = CorePotts.AdaptedProgramBackend{:MetalBackend}())
    ownership = zeros(Int32, 6, 6)
    ownership[3:4, 3] .= 1
    ownership[3:4, 4] .= 2
    host = CorePotts.initialize_program(
        program,
        CorePotts.ProgramInitialState(
            ownership, Int16[2, 2]; scalar_type = Float32,
            cell_generations = UInt32[5, 7]),
        Float32[], UInt64(0x10ca), UInt32(1))
    filter = CorePotts.CompilerSPI.SpatialOwnerFilterRecipe(
        CorePotts.CompilerSPI.StableOwnerIdentityFilter;
        identity_owner = 2, identity_generation = 7)
    read = CorePotts.CompilerSPI.SpatialQueryRead(
        1, filter; metric_handle = 1)
    context = CorePotts._CellStageEvaluationContext(host, Int32(1), nothing)
    @test CorePotts.CompilerSPI.qualified_tracker_operation_call(
        CorePotts.ResourceOperation{:contact_measure}(), (1,), context,
        Val(:spatial_relation_query), Int32(1), read) == 3.0f0
    runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
    for _ in 1:2
        CorePotts.advance_mcs!(runtime)
        @test !CorePotts.program_failed(runtime)
        CorePotts.program_checkpoint(runtime)
    end
end

@testset "structured owner sums on Metal" begin
    Metal.functional() || error("structured owner sums require functional Metal")
    Metal.allowscalar(false)
    for value in (
            SVector(1.0f0, -2.0f0),
            SMatrix{2, 2}(1.0f0, -2.0f0, 3.0f0, 4.0f0),
        )
        signal = fill(value, 6, 6)
        host, handle, key = site_sum_runtime(
            CorePotts.CheckerboardProgramEngine(); signal,
            backend = CorePotts.AdaptedProgramBackend{:MetalBackend}(),
        )
        runtime = CorePotts.adapt_program_runtime(Metal.MtlArray, host)
        structured_sum_snapshot_matches(runtime, handle, key, 2.0f0)

        state = CorePotts.copy_auxiliary_state(
            CorePotts.program_snapshot(runtime).descriptor_state
        )
        replacement = fill(3.0f0 .* value, 6, 6)
        CorePotts.state_block(state, handle).values .= replacement
        CorePotts.update_program_inputs!(
            runtime; parameters = Float32[-0.5], descriptor_state = state
        )
        structured_sum_snapshot_matches(runtime, handle, key, -0.5f0)

        checkpoint = CorePotts.program_checkpoint(runtime)
        before_mcs = runtime.mcs
        before_accepted = runtime.accepted
        before_ownership = CorePotts.program_snapshot(runtime).ownership
        restored = CorePotts.adapt_program_runtime(
            Metal.MtlArray,
            CorePotts.restore_program_checkpoint(runtime.program, checkpoint),
        )
        for continued in (runtime, restored)
            CorePotts.advance_mcs!(continued)
            @test !CorePotts.program_failed(continued)
            structured_sum_snapshot_matches(continued, handle, key, -0.5f0)
        end
        runtime_snapshot = CorePotts.program_snapshot(runtime)
        restored_snapshot = CorePotts.program_snapshot(restored)
        @test runtime.mcs == restored.mcs == before_mcs + 1
        @test runtime.accepted == restored.accepted > before_accepted
        @test runtime_snapshot.ownership == restored_snapshot.ownership
        @test runtime_snapshot.ownership != before_ownership
        @test CorePotts.state_block(
            runtime_snapshot.descriptor_state, handle
        ).values == CorePotts.state_block(
            restored_snapshot.descriptor_state, handle
        ).values
        @test runtime_snapshot.trackers.values == restored_snapshot.trackers.values
    end
end
