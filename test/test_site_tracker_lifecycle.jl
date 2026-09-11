using Test
import CorePotts
include("fixtures/site_tracker_lifecycle_support.jl")

@testset "checkerboard lifecycle prefix recovery" begin
    for settled_receipts in (false, true)
        test_site_tracker_settlement_owner(; settled_receipts)
    end
    test_site_tracker_late_settlement_failure()
    for entrypoint in (:enqueue, :through, :staged, :advance)
        test_site_tracker_lifecycle_recovery(entrypoint)
    end
end

@testset "site tracker lifecycle reconstruction: $(nameof(typeof(engine)))" for engine in (
        CorePotts.SequentialProgramEngine(), CorePotts.CheckerboardProgramEngine(),
    )
    for effect in (CorePotts.RemoveCellLifecycleEffect, CorePotts.CreateCellLifecycleEffect, CorePotts.DivideCellLifecycleEffect)
        test_site_tracker_lifecycle(engine, effect)
    end
    test_site_tracker_lifecycle(engine, CorePotts.DivideCellLifecycleEffect; tied = true)
    test_site_tracker_lifecycle(engine, CorePotts.CreateCellLifecycleEffect; clear_source = true)
    for group_sum in (false, true)
        test_site_tracker_creation_ignores_cleared_entry_source(engine; group_sum)
    end
    test_site_tracker_lifecycle(engine, CorePotts.DivideCellLifecycleEffect; clear_source = true)
    test_site_tracker_retirement(engine)
    test_site_tracker_no_lifecycle_effect(engine)
    test_site_tracker_lifecycle_failure(engine)
    test_site_tracker_lifecycle_failure(engine; source_overflow = true)
    test_site_tracker_lifecycle_failure(engine; source_overflow = true, group_sum = false)
    test_site_tracker_lifecycle_failure(engine; source_overflow = true, include_sum = false)
    for effect in (CorePotts.RemoveCellLifecycleEffect, CorePotts.CreateCellLifecycleEffect, CorePotts.DivideCellLifecycleEffect)
        test_site_tracker_lifecycle_history(engine, effect; clear_source = true)
    end
    test_site_tracker_lifecycle_history(engine, CorePotts.DivideCellLifecycleEffect)
    test_site_minimum_accepted_nonfinite(engine)
end

@testset "lifecycle reconstruction submission accounting" begin
    for include_minimum in (false, true)
        runtime, _, _, _ = site_tracker_lifecycle_runtime(
            CorePotts.CheckerboardProgramEngine(), CorePotts.RemoveCellLifecycleEffect; include_minimum
        )
        report = CorePotts._inspect_checkerboard_execution(runtime.engine_workspace)
        policy = report.identity.queue_policy
        @test policy.lifecycle_site_snapshot_submissions_per_mcs == Int(include_minimum)
        @test policy.lifecycle_site_reconstruction_submissions_per_mcs == Int(include_minimum)
        @test all(bank -> length(bank.site_trackers) == Int(include_minimum), report.lifecycle_reductions)
        @test all(bank -> all(tracker -> hasproperty(tracker, :snapshot) && hasproperty(tracker, :reconstruction), bank.site_trackers), report.lifecycle_reductions)
        CorePotts.advance_mcs!(runtime)
        CorePotts.advance_mcs!(runtime)
        @test CorePotts.program_snapshot(runtime).mcs == 2
        @test !CorePotts.program_failed(runtime)
        completed = CorePotts._inspect_checkerboard_execution(runtime.engine_workspace)
        @test all(bank -> bank.pending == 0, completed.completion_receipts.lifecycle.site_trackers)
    end
end
