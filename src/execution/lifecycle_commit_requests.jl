@inline function _apply_lifecycle_effect_state!(
        mode, runtime, plan, workspace, request, descriptor, plan_class
    )
    source, destination = _lifecycle_state_endpoints(
        workspace, request, plan_class
    )
    return _apply_lifecycle_state_rules!(
        mode,
        runtime,
        plan,
        workspace,
        descriptor,
        request,
        source,
        destination,
    )
end

@inline function _apply_lifecycle_effect_state!(
        mode::BackendLifecycleExecution,
        runtime,
        plan,
        workspace,
        request,
        descriptor,
        plan_class,
        action::Val,
        candidate_status,
        failure_rank,
    )
    source, destination = _lifecycle_state_endpoints(
        workspace, request, plan_class
    )
    return _apply_lifecycle_state_rules!(
        mode,
        runtime,
        plan,
        workspace,
        descriptor,
        request,
        source,
        destination,
        action,
        candidate_status,
        failure_rank,
    )
end

@inline function _apply_lifecycle_effect_state!(
        mode, runtime, plan, workspace, request, descriptor, plan_class,
        action::Val,
    )
    source, destination = _lifecycle_state_endpoints(
        workspace, request, plan_class
    )
    return _apply_lifecycle_state_rules!(
        mode,
        runtime,
        plan,
        workspace,
        descriptor,
        request,
        source,
        destination,
        action,
    )
end

@inline _finalize_lifecycle_effect!(
    workspace,
    request,
    descriptor,
    ::Union{_CreateLifecyclePlan, _TransitionLifecyclePlan, _DivideLifecyclePlan},
) = 0
@inline function _finalize_lifecycle_effect!(
        workspace,
        request,
        descriptor,
        ::Union{_RemoveLifecyclePlan, _RetireLifecyclePlan},
    )
    @inbounds workspace.staged_cell_kinds[workspace.anchor[request]] = 0
    return 1
end

function _apply_lifecycle_request_effect!(
    mode, runtime, plan, workspace, request, descriptor, plan_class
)
    relationship_recipe = _lifecycle_relationship_recipe(plan)
    relationship_state = _lifecycle_relationship_state(workspace)
    _apply_lifecycle_pre_relationships!(
        mode, relationship_recipe, relationship_state,
        request, descriptor, plan_class,
    ) || return -1
    tracker_source = tracker_source_view(
        runtime.program, workspace.staged_ownership
    )
    structure_recipe = _lifecycle_structure_recipe(runtime, plan)
    structure_state = _lifecycle_structure_state(mode, runtime, workspace)
    _stage_lifecycle_effect_base!(
        mode, structure_recipe, structure_state, request, descriptor,
        tracker_source, plan_class,
    ) || return -1
    _apply_lifecycle_post_relationships!(
        mode, relationship_recipe, relationship_state,
        request, descriptor, plan_class,
    ) || return -1
    state_recipe = _lifecycle_state_recipe(plan)
    state_view = _lifecycle_state_view(workspace)
    _apply_lifecycle_effect_state!(
        mode, runtime, state_recipe, state_view, request, descriptor, plan_class
    ) || return -1
    return _finalize_lifecycle_effect!(
        workspace, request, descriptor, plan_class
    )
end

@inline function _lifecycle_request_plan_class(descriptor)
    descriptor.effect === CreateCellLifecycleEffect &&
        return _CreateLifecyclePlan()
    descriptor.effect === RemoveCellLifecycleEffect &&
        return _RemoveLifecyclePlan()
    descriptor.effect === RetireCellLifecycleEffect &&
        return _RetireLifecyclePlan()
    descriptor.effect === TransitionCellLifecycleEffect &&
        return _TransitionLifecyclePlan()
    descriptor.effect === DivideCellLifecycleEffect &&
        return _DivideLifecyclePlan()
    return nothing
end

function _apply_lifecycle_request!(
        mode::AbstractLifecycleExecutionMode,
        runtime,
        plan,
        workspace,
        request,
    )
    descriptor = @inbounds plan.descriptors[Int(workspace.descriptor[request])]
    plan_class = _lifecycle_request_plan_class(descriptor)
    plan_class === nothing && return -1
    return _apply_lifecycle_request_effect!(
        mode, runtime, plan, workspace, request, descriptor, plan_class
    )
end

@inline function _stage_lifecycle_request_structure!(
        mode, runtime, plan, workspace, tracker_source, request
    )
    descriptor = @inbounds plan.descriptors[Int(workspace.descriptor[request])]
    plan_class = _lifecycle_request_plan_class(descriptor)
    plan_class === nothing && return false
    structure_recipe = _lifecycle_structure_recipe(runtime, plan)
    structure_state = _lifecycle_structure_state(mode, runtime, workspace)
    return _stage_lifecycle_effect_base!(
        mode, structure_recipe, structure_state, request, descriptor,
        tracker_source, plan_class,
    )
end

@inline function _stage_lifecycle_request_relationships!(
        mode, plan, workspace, request
    )
    descriptor = @inbounds plan.descriptors[Int(workspace.descriptor[request])]
    plan_class = _lifecycle_request_plan_class(descriptor)
    plan_class === nothing && return false
    recipe = _lifecycle_relationship_recipe(plan)
    state = _lifecycle_relationship_state(workspace)
    _apply_lifecycle_pre_relationships!(
        mode, recipe, state, request, descriptor, plan_class
    ) || return false
    return _apply_lifecycle_post_relationships!(
        mode, recipe, state, request, descriptor, plan_class
    )
end

@inline function _stage_lifecycle_request_state!(
        mode, runtime, plan, workspace, request
    )
    descriptor = @inbounds plan.descriptors[Int(workspace.descriptor[request])]
    plan_class = _lifecycle_request_plan_class(descriptor)
    plan_class === nothing && return false
    state_recipe = _lifecycle_state_recipe(plan)
    state_view = _lifecycle_state_view(workspace)
    return _apply_lifecycle_effect_state!(
        mode, runtime, state_recipe, state_view, request, descriptor, plan_class
    )
end

@inline function _finalize_lifecycle_request!(plan, workspace, request)
    descriptor = @inbounds plan.descriptors[Int(workspace.descriptor[request])]
    plan_class = _lifecycle_request_plan_class(descriptor)
    plan_class === nothing && return -1
    return _finalize_lifecycle_effect!(
        workspace, request, descriptor, plan_class
    )
end

_apply_lifecycle_request!(runtime, plan, workspace, request) =
    _apply_lifecycle_request!(
        HostLifecycleExecution(), runtime, plan, workspace, request
    )
