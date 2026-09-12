using AllocCheck

include("fixtures/site_tracker_lifecycle_support.jl")

function _prepared_owner_change_arguments()
    runtime, _, _, _ = site_tracker_lifecycle_runtime(
        CorePotts.SequentialProgramEngine(),
        CorePotts.RemoveCellLifecycleEffect;
        include_minimum = false,
    )
    workspace = runtime.lifecycle_workspace
    copyto!(workspace.staged_ownership, runtime.ownership)
    copyto!(workspace.staged_cell_kinds, runtime.cell_kinds)
    copyto!(workspace.staged_cell_generations, runtime.cell_generations)
    CorePotts.copyto_tracker_state!(workspace.staged_trackers, runtime.trackers)
    CorePotts.copyto_auxiliary_state!(
        workspace.staged_descriptor_state, runtime.descriptor_state,
    )
    state = CorePotts._lifecycle_owner_change_state(
        CorePotts.HostLifecycleExecution(), workspace,
    )
    source = CorePotts.tracker_source_view(
        runtime.program, state.staged_ownership;
        parameters = runtime.parameters,
        descriptor_state = state.staged_descriptor_state,
    )
    linear = LinearIndices(runtime.ownership)[3, 3]
    return (
        CorePotts.HostLifecycleExecution(), runtime,
        runtime.program.lifecycle_plan, state, source,
        linear, Int32(-1),
    )
end

Base.@noinline _execute_prepared_owner_change!(arguments) =
    CorePotts._stage_owner_change!(arguments...)

function _prepared_site_contribution_arguments()
    runtime, _, _, _ = site_tracker_lifecycle_runtime(
        CorePotts.SequentialProgramEngine(),
        CorePotts.RemoveCellLifecycleEffect;
        include_minimum = false,
    )
    source = CorePotts.tracker_source_view(
        runtime.program, runtime.ownership;
        parameters = runtime.parameters,
        descriptor_state = runtime.descriptor_state,
    )
    group = last(runtime.program.tracker_plan.descriptors)
    descriptor = CorePotts._bind_site_sum_tracker(
        only(group.descriptors), source,
    )
    return (descriptor, CartesianIndex(3, 3))
end

Base.@noinline _evaluate_prepared_site_contribution(arguments) =
    CorePotts._bound_site_tracker_contribution(arguments...)

@testset "prepared accepted-update boundaries allocate no CPU heap" begin
    warm = _prepared_owner_change_arguments()
    @test _execute_prepared_owner_change!(warm)
    measured = _prepared_owner_change_arguments()
    @test isempty(AllocCheck.check_allocs(
        CorePotts._stage_owner_change!, typeof.(measured),
    ))
    GC.gc()
    @test @allocated(_execute_prepared_owner_change!(measured)) == 0
    @test measured[4].staged_ownership[measured[6]] == -1

    warm_contribution = _prepared_site_contribution_arguments()
    @test _evaluate_prepared_site_contribution(warm_contribution) == -4.0f0
    measured_contribution = _prepared_site_contribution_arguments()
    @test isempty(AllocCheck.check_allocs(
        CorePotts._bound_site_tracker_contribution,
        typeof.(measured_contribution),
    ))
    GC.gc()
    @test @allocated(
        _evaluate_prepared_site_contribution(measured_contribution)
    ) == 0
end
