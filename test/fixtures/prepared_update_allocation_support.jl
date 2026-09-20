include("site_tracker_lifecycle_support.jl")

function prepared_owner_change_arguments()
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
    source = CorePotts.tracker_source_view(
        runtime.program, workspace.staged_ownership;
        parameters = runtime.parameters,
        descriptor_state = workspace.staged_descriptor_state,
    )
    state = CorePotts._lifecycle_owner_change_state(
        CorePotts.HostLifecycleExecution(), runtime, workspace,
    )
    recipe = CorePotts._ownership_transfer_recipe(
        runtime, runtime.program.lifecycle_plan,
    )
    linear = LinearIndices(runtime.ownership)[3, 3]
    return (
        CorePotts.HostLifecycleExecution(), recipe, state, source,
        linear, Int32(-1),
    )
end

Base.@noinline execute_prepared_owner_change!(arguments) =
    CorePotts._stage_owner_change!(arguments...)

function prepared_site_contribution_arguments()
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

Base.@noinline evaluate_prepared_site_contribution(arguments) =
    CorePotts._bound_site_tracker_contribution(arguments...)
