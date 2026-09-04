# Reachability-specialized orchestration of the ordered backend lifecycle transaction.

struct _LifecycleRelationshipTopologyBank{E, D, I, M}
    endpoint_a::E
    endpoint_b::E
    degree::D
    incident_edges::I
    edge_offsets::M
    edge_counts::M
    endpoint_offsets::M
    endpoint_counts::M
    incident_offsets::M
    maximum_degrees::M
end

Adapt.@adapt_structure _LifecycleRelationshipTopologyBank

@inline function Base.getindex(
        bank::_LifecycleRelationshipTopologyBank, slot::Int
    )
    @boundscheck checkbounds(bank.edge_offsets, slot)
    edge_offset = @inbounds bank.edge_offsets[slot]
    edge_count = @inbounds bank.edge_counts[slot]
    endpoint_offset = @inbounds bank.endpoint_offsets[slot]
    endpoint_count = @inbounds bank.endpoint_counts[slot]
    incident_offset = @inbounds bank.incident_offsets[slot]
    maximum_degree = @inbounds bank.maximum_degrees[slot]
    return (
        endpoint_a = PackedRelationshipVector(
            bank.endpoint_a, edge_offset, edge_count
        ),
        endpoint_b = PackedRelationshipVector(
            bank.endpoint_b, edge_offset, edge_count
        ),
        degree = PackedRelationshipVector(
            bank.degree, endpoint_offset, endpoint_count
        ),
        incident_edges = PackedRelationshipMatrix(
            bank.incident_edges,
            incident_offset,
            maximum_degree,
            endpoint_count,
        ),
    )
end

@inline function _lifecycle_relationship_topology(bank::PackedRelationshipBank)
    return _LifecycleRelationshipTopologyBank(
        bank.endpoint_a,
        bank.endpoint_b,
        bank.degree,
        bank.incident_edges,
        bank.edge_offsets,
        bank.edge_counts,
        bank.endpoint_offsets,
        bank.endpoint_counts,
        bank.incident_offsets,
        bank.maximum_degrees,
    )
end

@inline function _lifecycle_relationship_topology(storage::RelationshipStorage)
    return RelationshipStorage(
        map(_lifecycle_relationship_topology, storage.banks),
        storage.slots,
    )
end

@inline function _lifecycle_effect_runtime(
        state, ::_CreateLifecyclePlan
    )
    program = state.program
    lifecycle_program = (
        shape = program.shape,
        periodic = program.periodic,
        medium_kind = program.medium_kind,
        tracker_plan = program.tracker_plan,
        domain_resources = program.domain_resources,
        lifecycle_plan = program.lifecycle_plan,
    )
    return (
        program = lifecycle_program,
        ownership = state.ownership,
        cell_kinds = state.cell_kinds,
        cell_generations = state.cell_generations,
        trackers = state.trackers,
        relationships = state.relationships,
        descriptor_state = state.descriptor_state,
        parameters = state.parameters,
        seed = state.seed,
        replica = state.replica,
        repeat = state.repeat,
        mcs = state.mcs,
    )
end

@inline function _lifecycle_effect_runtime(
        state, ::Union{_RemoveLifecyclePlan, _TransitionLifecyclePlan}
    )
    return (
        cell_kinds = state.cell_kinds,
        cell_generations = state.cell_generations,
    )
end

@inline _lifecycle_relationship_validation_runtime(state) = (
    cell_kinds = state.cell_kinds,
    cell_generations = state.cell_generations,
    cell_volumes = tracker_values(
        state.program.tracker_plan, state.trackers, Val(:cell_volume)
    ),
    relationships = _lifecycle_relationship_topology(state.relationships),
)

@inline _lifecycle_relationship_validation_plan(plan) = (
    descriptors = plan.descriptors,
    relationship_rules = plan.relationship_rules,
)

@inline _lifecycle_effect_plan(plan, ::_CreateLifecyclePlan) = plan

@inline function _lifecycle_effect_plan(
        plan,
        ::Union{
            _RemoveLifecyclePlan,
            _TransitionLifecyclePlan,
        },
    )
    return (
        descriptors = plan.descriptors,
        relationship_rules = plan.relationship_rules,
    )
end


@inline function _lifecycle_effect_workspace(
        workspace, ::_CreateLifecyclePlan
    )
    return (
        request_count = workspace.request_index.count,
        request_slots = workspace.request_index.records.slot,
        descriptor = workspace.descriptor,
        anchor = workspace.anchor,
        generation = workspace.generation,
        active = workspace.active,
        filtered = workspace.filtered,
        filtered_detail = workspace.filtered_detail,
        planned_site_count = workspace.planned_site_count,
        planned_sites = workspace.planned_sites,
        site_index = workspace.site_index,
        status_code = workspace.status.code,
    )
end

@inline function _lifecycle_effect_workspace(
        workspace,
        ::Union{
            _RemoveLifecyclePlan,
            _TransitionLifecyclePlan,
        },
    )
    return (
        request_count = workspace.request_index.count,
        request_slots = workspace.request_index.records.slot,
        descriptor = workspace.descriptor,
        anchor = workspace.anchor,
        generation = workspace.generation,
        active = workspace.active,
        filtered = workspace.filtered,
        filtered_detail = workspace.filtered_detail,
        status_code = workspace.status.code,
    )
end

@inline function _lifecycle_effect_control(control)
    status = control.candidate_status
    return (
        counters = control.counters,
        candidate_status = _LifecyclePlanningStatus(
            status.code,
            status.source,
            status.anchor,
            status.detail,
        ),
    )
end

function enqueue_lifecycle_backend_index!(
        state,
        reductions;
        workgroup_size::Union{Nothing, Integer} = nothing,
    )
    control = state.lifecycle_control
    control isa NoLifecycleBackendControl && return nothing
    reductions === nothing && throw(ArgumentError(
        "lifecycle execution requires prepared LocalMath reductions"
    ))
    workspace = state.lifecycle_workspace
    tracker_source = tracker_source_view(
        state.program, workspace.staged_ownership
    )
    backend = KernelAbstractions.get_backend(state.ownership)
    workgroup_size === nothing || workgroup_size > 0 || throw(ArgumentError(
        "lifecycle workgroup size must be positive"
    ))
    launch(kernel) = workgroup_size === nothing ? kernel(backend) :
                     kernel(backend, Int(workgroup_size))
    reset = launch(_reset_lifecycle_backend_kernel!)
    validate_ownership = launch(_validate_lifecycle_ownership_kernel!)
    plan_effect = _plan_lifecycle_effect_backend_kernel!(backend, 1)
    plan_division = _plan_lifecycle_division_backend_kernel!(backend, 1)
    validate_relationships =
        _validate_lifecycle_relationships_backend_kernel!(backend, 1)
    replan_selected_division =
        _replan_selected_lifecycle_division_backend_kernel!(backend, 1)
    clear_selected_division_workspace =
        launch(_clear_selected_division_workspace_backend_kernel!)
    stage_structure = _stage_lifecycle_structure_backend_kernel!(backend, 1)
    stage_relationships =
        _stage_lifecycle_relationships_backend_kernel!(backend, 1)
    stage_state = _stage_lifecycle_state_backend_kernel!(backend, 1)
    finalize_effect = _finalize_lifecycle_effect_backend_kernel!(backend, 1)
    validate_requests = _validate_lifecycle_backend_kernel!(backend, 1)
    finalize_requests = _finalize_lifecycle_backend_kernel!(backend, 1)
    @debug "enqueue lifecycle backend stage" stage = :clear_policy_workspace
    clear_policy_workspace = launch(_clear_lifecycle_policy_workspace_kernel!)
    isempty(workspace.policy_workspace) || clear_policy_workspace(
        workspace, control; ndrange = length(workspace.policy_workspace)
    )
    @debug "enqueue lifecycle backend stage" stage = :reset
    reset(
        state.program.lifecycle_plan,
        workspace,
        control,
        Int32(state.mcs + 1);
        ndrange = length(control.candidate_status),
    )
    @debug "enqueue lifecycle backend stage" stage = :validate_ownership
    validate_ownership(
        state.ownership,
        workspace,
        control,
        Int32(length(state.cell_kinds));
        ndrange = length(state.ownership),
    )
    @debug "enqueue lifecycle backend stage" stage = :materialize_site_index
    site_index_event = LocalMath.execute!(reductions.site_index)
    @debug "enqueue lifecycle backend stage" stage = :reduce_site_status
    last_direct_event = _run_lifecycle_status!(
        reductions.direct, length(state.ownership))
    _enqueue_lifecycle_failure_stamp!(state, ProgramStageIndex)
    @debug "enqueue lifecycle backend stage" stage = :emit_requests
    emission_event = _run_lifecycle_emission!(reductions.emission, state.mcs)
    @debug "enqueue lifecycle backend stage" stage = :materialize_requests
    request_index_event = LocalMath.execute!(reductions.request_index)
    effect_mask = state.program.lifecycle_plan.effect_mask
    for plan_class in (
            _CreateLifecyclePlan(),
            _RemoveLifecyclePlan(),
            _TransitionLifecyclePlan(),
        )
        iszero(
            effect_mask & _lifecycle_effect_bit(
                _lifecycle_plan_effect(plan_class)
            )
        ) && continue
        @debug "enqueue lifecycle effect planner" plan_class
        effect_runtime = _lifecycle_effect_runtime(state, plan_class)
        effect_plan = _lifecycle_effect_plan(
            state.program.lifecycle_plan, plan_class
        )
        effect_workspace = _lifecycle_effect_workspace(workspace, plan_class)
        effect_control = _lifecycle_effect_control(control)
        plan_effect(
            effect_runtime,
            effect_plan,
            effect_workspace,
            effect_control,
            plan_class;
            ndrange = 1,
        )
    end
    division_variant_mask = state.program.lifecycle_plan.division_variant_mask
    division_variants = (
            _DivideLifecycleVariantPlan(
                _RandomPlanePartitionPlan(), _CanonicalSidePlan()
            ),
            _DivideLifecycleVariantPlan(
                _RandomPlanePartitionPlan(), _StableRandomSidePlan()
            ),
            _DivideLifecycleVariantPlan(
                _PrincipalMajorPartitionPlan(), _CanonicalSidePlan()
            ),
            _DivideLifecycleVariantPlan(
                _PrincipalMajorPartitionPlan(), _StableRandomSidePlan()
            ),
            _DivideLifecycleVariantPlan(
                _PrincipalMinorPartitionPlan(), _CanonicalSidePlan()
            ),
            _DivideLifecycleVariantPlan(
                _PrincipalMinorPartitionPlan(), _StableRandomSidePlan()
            ),
            _DivideLifecycleVariantPlan(
                _SpecifiedNormalPartitionPlan(), _CanonicalSidePlan()
            ),
            _DivideLifecycleVariantPlan(
                _SpecifiedNormalPartitionPlan(), _StableRandomSidePlan()
            ),
            _DivideLifecycleVariantPlan(
                _ExternalPartitionPlan(), _CanonicalSidePlan()
            ),
            _DivideLifecycleVariantPlan(
                _ExternalPartitionPlan(), _StableRandomSidePlan()
            ),
        )
    for plan_class in division_variants
        iszero(
            division_variant_mask & _lifecycle_division_variant_bit(
                _lifecycle_partition_code(plan_class.partition),
                _lifecycle_side_code(plan_class.side),
            )
        ) && continue
        @debug "enqueue lifecycle division planner" plan_class
        plan_division(
            state, workspace, control, plan_class; ndrange = 1
        )
    end
    @debug "enqueue lifecycle backend stage" stage = :validate_relationships
    validate_relationships(
        _lifecycle_relationship_validation_runtime(state),
        _lifecycle_relationship_validation_plan(state.program.lifecycle_plan),
        workspace,
        control;
        ndrange = 1,
    )
    @debug "enqueue lifecycle backend stage" stage = :reduce_planning_status
    last_planning_event = _run_lifecycle_status!(
        reductions.planning, length(control.candidate_status))
    _enqueue_lifecycle_failure_stamp!(state, ProgramStagePlanning)
    @debug "enqueue lifecycle backend stage" stage = :select_requests
    selection_event = _execute_lifecycle_selection!(
        reductions.selection; parameters = (current_mcs = Int64(state.mcs),)
    )
    policy_workspace_length = length(workspace.policy_workspace)
    if policy_workspace_length > 0
        @debug "enqueue lifecycle backend stage" stage = :clear_selected_division_workspace
        clear_selected_division_workspace(
            state.program.lifecycle_plan,
            workspace,
            control;
            ndrange = policy_workspace_length,
        )
    end
    for plan_class in division_variants
        iszero(
            division_variant_mask & _lifecycle_division_variant_bit(
                _lifecycle_partition_code(plan_class.partition),
                _lifecycle_side_code(plan_class.side),
            )
        ) && continue
        @debug "enqueue selected lifecycle division planner" plan_class
        replan_selected_division(
            state, workspace, control, plan_class; ndrange = 1
        )
    end
    @debug "enqueue lifecycle backend stage" stage = :reduce_selected_planning_status
    last_planning_event = _run_lifecycle_status!(
        reductions.planning, length(control.candidate_status))
    _enqueue_lifecycle_failure_stamp!(state, ProgramStagePlanning)
    effect_classes = (
            _CreateLifecyclePlan(),
            _RetireLifecyclePlan(),
            _RemoveLifecyclePlan(),
            _TransitionLifecyclePlan(),
            _DivideLifecyclePlan(),
        )
    for plan_class in effect_classes
        iszero(
            effect_mask & _lifecycle_effect_bit(
                _lifecycle_plan_effect(plan_class)
            )
        ) && continue
        @debug "enqueue lifecycle structural staging" plan_class
        stage_structure(
            state, tracker_source, workspace, control, plan_class; ndrange = 1
        )
    end
    _enqueue_lifecycle_failure_stamp!(state, ProgramStageStructure)
    relationship_action_mask =
        state.program.lifecycle_plan.relationship_action_mask
    for action_value in (
            Val(:remove_incident), Val(:remove_incompatible),
        )
        action = _lifecycle_relationship_action_value(action_value)
        iszero(
            relationship_action_mask &
            _lifecycle_relationship_action_bit(action)
        ) && continue
        @debug "enqueue lifecycle relationship staging" action
        stage_relationships(
            state, workspace, control, action_value; ndrange = 1
        )
    end
    _enqueue_lifecycle_failure_stamp!(state, ProgramStageRelationships)
    state_actions = (
        Val(:initialize),
        Val(:retire_to),
        Val(:preserve),
        Val(:reset),
        Val(:transform),
        Val(:copy_daughters),
        Val(:preserve_parent_reset_daughter),
        Val(:reset_both),
        Val(:split_conservatively),
        Val(:transform_daughters),
        Val(:redraw_daughters),
    )
    state_runtime, state_descriptors, state_plan =
        _lifecycle_state_launch_payload(state, workspace)
    for action_value in state_actions
        action = _lifecycle_state_action_value(action_value)
        for plan_class in effect_classes
            iszero(
                effect_mask & _lifecycle_effect_bit(
                    _lifecycle_plan_effect(plan_class)
                )
            ) && continue
            effect_action_mask = state.program.lifecycle_plan.state_action_masks[
                Int(_lifecycle_plan_effect(plan_class))
            ]
            iszero(
                effect_action_mask & _lifecycle_state_action_bit(action)
            ) && continue
            @debug "enqueue lifecycle state staging" plan_class action
            stage_state(
                state_runtime,
                state_descriptors,
                state_plan,
                workspace,
                control,
                plan_class,
                action_value;
                ndrange = length(workspace.active),
            )
        end
    end
    last_planning_event = _run_lifecycle_status!(
        reductions.planning, length(control.candidate_status))
    _enqueue_lifecycle_failure_stamp!(state, ProgramStageState)
    for plan_class in effect_classes
        iszero(
            effect_mask & _lifecycle_effect_bit(
                _lifecycle_plan_effect(plan_class)
            )
        ) && continue
        @debug "enqueue lifecycle effect finalization" plan_class
        finalize_effect(
            state, workspace, control, plan_class; ndrange = 1
        )
    end
    @debug "enqueue lifecycle backend stage" stage = :validate_staged_state
    validate_requests(state, workspace, control; ndrange = 1)
    _enqueue_lifecycle_failure_stamp!(state, ProgramStageValidation)
    @debug "enqueue lifecycle backend stage" stage = :finalize
    finalize_requests(workspace, control; ndrange = 1)
    return (
        direct = last_direct_event,
        planning = last_planning_event,
        site_index = site_index_event,
        request_index = request_index_event,
        emission = emission_event,
        selection = selection_event,
    )
end
