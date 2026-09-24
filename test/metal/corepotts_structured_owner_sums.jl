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
