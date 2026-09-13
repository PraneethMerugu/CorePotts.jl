using AllocCheck

include("fixtures/prepared_update_allocation_support.jl")

@testset "prepared accepted-update boundaries allocate no CPU heap" begin
    warm = prepared_owner_change_arguments()
    @test execute_prepared_owner_change!(warm)
    measured = prepared_owner_change_arguments()
    @test isempty(AllocCheck.check_allocs(
        CorePotts._stage_owner_change!, typeof.(measured),
    ))
    GC.gc()
    @test @allocated(execute_prepared_owner_change!(measured)) == 0
    @test measured[4].staged_ownership[measured[6]] == -1

    warm_contribution = prepared_site_contribution_arguments()
    @test evaluate_prepared_site_contribution(warm_contribution) == -4.0f0
    measured_contribution = prepared_site_contribution_arguments()
    @test isempty(AllocCheck.check_allocs(
        CorePotts._bound_site_tracker_contribution,
        typeof.(measured_contribution),
    ))
    GC.gc()
    @test @allocated(
        evaluate_prepared_site_contribution(measured_contribution)
    ) == 0
end
