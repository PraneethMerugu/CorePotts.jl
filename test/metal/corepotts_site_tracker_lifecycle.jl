using Test
import CorePotts
import Metal

include(joinpath(@__DIR__, "..", "fixtures", "site_tracker_lifecycle_support.jl"))

@testset "maintained site trackers through lifecycle on Metal" begin
    Metal.functional() || error("site tracker lifecycle reconstruction requires functional Metal")
    Metal.allowscalar(false)
    engine = CorePotts.CheckerboardProgramEngine()
    backend = CorePotts.AdaptedProgramBackend{:MetalBackend}()
    for settled_receipts in (false, true)
        test_site_tracker_settlement_owner(; settled_receipts, adapt_to = Metal.MtlArray, backend)
    end
    test_site_tracker_late_settlement_failure(; adapt_to = Metal.MtlArray, backend)
    for effect in (CorePotts.RemoveCellLifecycleEffect, CorePotts.CreateCellLifecycleEffect, CorePotts.DivideCellLifecycleEffect)
        test_site_tracker_lifecycle(engine, effect; adapt_to = Metal.MtlArray, backend)
    end
    test_site_tracker_lifecycle(engine, CorePotts.DivideCellLifecycleEffect; tied = true, adapt_to = Metal.MtlArray, backend)
    test_site_tracker_lifecycle(engine, CorePotts.CreateCellLifecycleEffect; clear_source = true, adapt_to = Metal.MtlArray, backend)
    for group_sum in (false, true)
        test_site_tracker_creation_ignores_cleared_entry_source(
            engine; group_sum, adapt_to = Metal.MtlArray, backend,
        )
    end
    test_site_tracker_lifecycle(engine, CorePotts.DivideCellLifecycleEffect; clear_source = true, adapt_to = Metal.MtlArray, backend)
    test_site_tracker_retirement(engine; adapt_to = Metal.MtlArray, backend)
    test_site_tracker_no_lifecycle_effect(engine; adapt_to = Metal.MtlArray, backend)
    test_site_tracker_lifecycle_failure(engine; adapt_to = Metal.MtlArray, backend)
    test_site_tracker_lifecycle_failure(engine; source_overflow = true, adapt_to = Metal.MtlArray, backend)
    test_site_tracker_lifecycle_failure(engine; source_overflow = true, group_sum = false, adapt_to = Metal.MtlArray, backend)
    test_site_tracker_lifecycle_failure(engine; source_overflow = true, include_sum = false, adapt_to = Metal.MtlArray, backend)
    for effect in (CorePotts.RemoveCellLifecycleEffect, CorePotts.CreateCellLifecycleEffect, CorePotts.DivideCellLifecycleEffect)
        test_site_tracker_lifecycle_history(engine, effect; clear_source = true, adapt_to = Metal.MtlArray, backend)
    end
    test_site_tracker_lifecycle_history(engine, CorePotts.DivideCellLifecycleEffect; adapt_to = Metal.MtlArray, backend)
    test_site_minimum_accepted_nonfinite(engine; adapt_to = Metal.MtlArray, backend)
end
